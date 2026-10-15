/* WiniosWindowed.m — ml1300 windowed mode: every top-level Wine window in a
 * frame of its own, plus a taskbar. See WiniosWindowed.h and docs/WINDOWED.md.
 *
 * How it sits on the desktop compositor (Winios.m). A desktop session already
 * keeps one CALayer per top-level window: the window's GDI surface as its
 * contents and, for a window a D3D swapchain presents into, a CAMetalLayer
 * sublayer over its client area. Winios.m places those layers in "desktop-fit"
 * coordinates (the guest desktop scaled into the compositor view). Windowed
 * mode leaves all of that alone and only re-parents each window's layer into a
 * host layer inside a frame view. The host's bounds origin is the window
 * layer's own origin and its transform scales by the frame's zoom, so the
 * window always fills its frame's content area wherever the frame is, and
 * Winios.m's frame, contents and Metal-sublayer updates keep working
 * unchanged. Owned popups (menus, tooltips, drop-down lists) go into their
 * owner's host and so appear beside it at the guest's relative offset.
 *
 * Guest windows are never moved or resized by the user's frame moves: a frame
 * is an app-side view of the window. Input therefore cannot be a desktop hit
 * test (two windows apart on screen can overlap on the guest desktop): a touch
 * is mapped through the frame it landed on into that window's own desktop
 * pixels, and the mouse event names that top-level window, which the server
 * routes it to (driver_ios.c winios_drv_post_mouse). A press latches its
 * window until the last button is up, so a drag that leaves the frame still
 * goes to it.
 *
 * Threads. Frames, the taskbar and the window table live on the main thread.
 * Wine threads read window text / styles / icons (driver_ios.c helpers) and
 * post the title-bar commands from their event pump. The event-target state
 * is behind g_target_lock: winios_pointer can be called off the main thread.
 *
 * Game controllers. The frames and the taskbar are UIKit controls, and iOS
 * lets a game controller drive focusable UIKit controls (the focus engine):
 * a pad's A on the taskbar's search field opened the software keyboard and
 * its Return activated another program's window. None of the chrome can take
 * focus (WWButton, WWSearchField, WWAppStrip), the search field becomes first
 * responder only from a touch, the buttons ignore presses, and the root claims
 * gamepad events for the Game Controller framework (GCEventInteraction), which
 * is where GamepadInput.swift reads the pads for the guest. Info.plist also
 * sets GCSupportsControllerUserInteraction = false.
 *
 * Look (round 4). Title bars, the taskbar and the restore pill share one
 * material (ww_material: a dark translucent blur, a hairline edge and a faint
 * top highlight); the title-bar buttons are monochrome glyph circles, brighter
 * on the active frame, and a state (fit to screen) shows as a glyph and a
 * light ring, never a colour.
 *
 * Steam on the taskbar (round 4). A pinned Steam button sits left of the
 * program buttons. With a Steam window open in the session it brings that
 * window to the front; otherwise WindowedMode.swift (MadeiraWindowedBridge
 * steamTapped) handles it: a running session cannot start another program
 * from the app, so it prepares Steam (or Valve's installer) as a library
 * entry for the next start and says so. env.MADEIRA_WINDOWED_STEAM = 0 hides it.
 *
 * Log lines: "[windowed] ml1300 ..." for on/off, add, refit, remove, activate,
 * move, scale, minimize, restore, fullscreen, close, steam and the ignored presses. */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>
#include "WiniosWindowed.h"
#include "../../../build/madeira_cfg.h"

/* ------------------------------------------------------------------ *
 * driver_ios.c helpers. Weak fallbacks keep the app linking against a
 * libwin32u_unix.a built before ml1300 (the strong definitions there win);
 * with them, windows are framed without titles or icons and commands are
 * not posted.
 * ------------------------------------------------------------------ */
__attribute__((weak)) int winios_drv_window_info(void *hwnd, struct winios_windowed_info *out)
{ (void)hwnd; (void)out; return 0; }
__attribute__((weak)) int winios_drv_window_icon(void *hwnd, unsigned int *out, int max_side, int *w, int *h)
{ (void)hwnd; (void)out; (void)max_side; (void)w; (void)h; return 0; }
__attribute__((weak)) int winios_drv_post_syscommand(void *hwnd, unsigned int cmd)
{ (void)hwnd; (void)cmd; return 0; }
__attribute__((weak)) void *winios_drv_foreground_window(void) { return NULL; }
extern int winios_drv_process_image(unsigned int pid, char *out, unsigned int size);
extern int winios_drv_census_owner(void *hwnd, unsigned int *pid, unsigned int *style);
extern int winios_drv_foreground_if_owner(void *hwnd);

#define WW_WS_VISIBLE      0x10000000u
#define WW_WS_MINIMIZE     0x20000000u
#define WW_WS_CHILD        0x40000000u
#define WW_WS_CAPTION      0x00C00000u
#define WW_WS_EX_TOOLWINDOW 0x00000080u
#define WW_WS_EX_APPWINDOW  0x00040000u
#define WW_SC_MINIMIZE     0xF020u
#define WW_SC_CLOSE        0xF060u
#define WW_SC_RESTORE      0xF120u
#define WW_MOUSE_ABSOLUTE  0x8000u
#define WW_MOUSE_DOWNS     (0x0002u | 0x0008u | 0x0020u | 0x0080u)   /* left/right/middle/X down */
#define WW_MOUSE_UPS       (0x0004u | 0x0010u | 0x0040u | 0x0100u)

static const CGFloat WW_BAR_H = 36;       /* title bar height, points */
static const CGFloat WW_BTN = 28;         /* title-bar button circles, points (touch target a little larger) */
static const CGFloat WW_BTN_GAP = 7;
static const CGFloat WW_MIN_BAR_W = 220;  /* a tiny window still gets a usable title bar (four buttons) */
static const CGFloat WW_DOCK_H = 56;
static const CGFloat WW_DOCK_ITEM = 36;   /* taskbar icons and round buttons */
static const CGFloat WW_DOCK_PAD = 10;    /* taskbar: pill edge to the first and last item */
static const CGFloat WW_DOCK_GAP = 10;    /* taskbar: between any two items */
static const CGFloat WW_SEARCH_W = 112;
static const CGFloat WW_GRAB = 120;       /* title bar that always stays on screen, points */

static void ww_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void ww_log(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[windowed] ml1300 %s\n", buf);
    fflush(stderr);
}

/* ================================================================== *
 * The switch
 * ================================================================== */

static _Atomic int g_ww_state = -1;   /* -1 unresolved, 0 off, 1 on */

int winios_windowed_active(void)
{
    int v = atomic_load_explicit(&g_ww_state, memory_order_acquire);
    if (v >= 0) return v;
    const char *d = getenv("MADEIRA_DESKTOP");
    int desktop = d && d[0] == '1';
    const char *e = getenv("MADEIRA_WINDOWED");   /* 1: windowed mode in desktop sessions (every top-level window in its own movable frame, with a taskbar); 0: off even when madeira.cfg sets windowed = 1 */
    int on;
    const char *source;
    if (e && *e) { on = e[0] == '1'; source = "env.MADEIRA_WINDOWED"; }
    else {
        on = madeira_cfg_bool("windowed", 0) ? 1 : 0;   /* windowed = 1: desktop sessions (Desktop, Wine desktop starts, Madeira Dock) draw each top-level window in its own frame with a title bar and a taskbar; off by default */
        source = "madeira.cfg windowed";
    }
    v = desktop && on;
    int expected = -1;
    if (atomic_compare_exchange_strong(&g_ww_state, &expected, v) && on)
        ww_log("%s (%s = 1%s)", v ? "on" : "off", source, v ? "" : "; only desktop sessions are windowed");
    return atomic_load(&g_ww_state);
}

/* ================================================================== *
 * Wine-side shared state
 * ================================================================== */

static pthread_mutex_t g_ww_lock = PTHREAD_MUTEX_INITIALIZER;

#define WW_KNOWN_MAX 128
static struct { uintptr_t hwnd; unsigned sig; unsigned char icon_tried; } g_known[WW_KNOWN_MAX];
static int g_nknown;

#define WW_CMDS_MAX 32
static struct { uintptr_t hwnd; unsigned cmd; } g_cmds[WW_CMDS_MAX];
static int g_ncmds;

#define WW_EXES_MAX 32
static struct { unsigned pid; char name[64]; } g_exes[WW_EXES_MAX];
static int g_nexes;

static _Atomic(uintptr_t) g_fg_request;      /* activate on the window's own thread */
static _Atomic long long g_fg_request_ns;
static _Atomic long long g_next_fg_poll_ns, g_next_info_ns;
static _Atomic(uintptr_t) g_guest_fg;

/* Event targets (any thread) */
static pthread_mutex_t g_target_lock = PTHREAD_MUTEX_INITIALIZER;
static uintptr_t g_t_latched, g_t_last, g_t_mapped;
static unsigned g_t_pressed;
static int g_t_mapped_valid, g_t_mx, g_t_my;
#define WW_Z_MAX 96
static struct { uintptr_t hwnd; CGRect desk; } g_z[WW_Z_MAX];   /* topmost first */
static int g_nz;

static long long ww_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void ww_enqueue(uintptr_t hwnd, unsigned cmd)
{
    pthread_mutex_lock(&g_ww_lock);
    if (g_ncmds < WW_CMDS_MAX) { g_cmds[g_ncmds].hwnd = hwnd; g_cmds[g_ncmds].cmd = cmd; g_ncmds++; }
    pthread_mutex_unlock(&g_ww_lock);
}

static void ww_request_foreground(uintptr_t hwnd)
{
    atomic_store(&g_fg_request_ns, ww_now_ns());
    atomic_store(&g_fg_request, hwnd);
}

/* "c:\program files\x\steam.exe" -> "steam" */
static void ww_exe_name(const char *image, char out[64])
{
    const char *base = image;
    for (const char *p = image; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
    snprintf(out, 64, "%s", base);
    size_t n = strlen(out);
    if (n > 4 && !strcasecmp(out + n - 4, ".exe")) out[n - 4] = 0;
}

static void ww_exe_for_pid(unsigned pid, char out[64])
{
    out[0] = 0;
    if (!pid) return;
    pthread_mutex_lock(&g_ww_lock);
    for (int i = 0; i < g_nexes; i++)
        if (g_exes[i].pid == pid) { memcpy(out, g_exes[i].name, 64); pthread_mutex_unlock(&g_ww_lock); return; }
    pthread_mutex_unlock(&g_ww_lock);
    char image[264];
    if (winios_drv_process_image(pid, image, sizeof(image))) ww_exe_name(image, out);
    pthread_mutex_lock(&g_ww_lock);
    if (g_nexes < WW_EXES_MAX) { g_exes[g_nexes].pid = pid; memcpy(g_exes[g_nexes].name, out, 64); g_nexes++; }
    pthread_mutex_unlock(&g_ww_lock);
}

static unsigned ww_info_sig(const struct winios_windowed_info *i)
{
    unsigned h = 2166136261u;
    const unsigned char *p = (const unsigned char *)i;
    for (size_t k = 0; k < sizeof(*i); k++) { h ^= p[k]; h *= 16777619u; }
    return h;
}

static void ww_apply_info(uintptr_t hwnd, struct winios_windowed_info info, NSString *exe, UIImage *icon);

/* Wine thread. `own_thread`: the call comes from the window's own thread,
 * which may read its class icon. */
static void ww_read_window(uintptr_t hwnd, int own_thread, int force)
{
    struct winios_windowed_info info;
    if (!winios_drv_window_info((void *)hwnd, &info)) {
        /* a libwin32u_unix.a from before ml1300: the census helper still tells
         * top-level from child and gives the style (no text, owner or class) */
        unsigned pid = 0, style = 0;
        memset(&info, 0, sizeof(info));
        if (winios_drv_census_owner((void *)hwnd, &pid, &style)) { info.kind = 2; info.pid = pid; info.style = style; }
    }
    if (info.kind != 2 && info.kind != 1) {
        /* a child window paints into its top-level's surface: never framed */
        if (own_thread) dispatch_async(dispatch_get_main_queue(), ^{ ww_apply_info(hwnd, info, nil, nil); });
        return;
    }
    unsigned sig = ww_info_sig(&info);
    int want_icon = 0, changed = force;
    pthread_mutex_lock(&g_ww_lock);
    int i;
    for (i = 0; i < g_nknown; i++) if (g_known[i].hwnd == hwnd) break;
    if (i == g_nknown && g_nknown < WW_KNOWN_MAX) {
        g_known[g_nknown].hwnd = hwnd; g_known[g_nknown].sig = 0; g_known[g_nknown].icon_tried = 0;
        g_nknown++;
    }
    if (i < g_nknown) {
        if (g_known[i].sig != sig) { g_known[i].sig = sig; changed = 1; }
        if (own_thread && !g_known[i].icon_tried && info.kind == 2) { g_known[i].icon_tried = 1; want_icon = 1; changed = 1; }
    }
    pthread_mutex_unlock(&g_ww_lock);
    if (!changed) return;

    char exe[64];
    ww_exe_for_pid(info.pid, exe);
    UIImage *icon = nil;
    if (want_icon) {
        static const int max_side = 64;
        unsigned int *bgra = malloc(max_side * max_side * 4);
        int w = 0, h = 0;
        if (bgra && winios_drv_window_icon((void *)hwnd, bgra, max_side, &w, &h) && w > 0 && h > 0) {
            NSData *data = [NSData dataWithBytes:bgra length:(size_t)w * h * 4];
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
            CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaFirst,
                                           dp, NULL, false, kCGRenderingIntentDefault);
            if (img) { icon = [UIImage imageWithCGImage:img]; CGImageRelease(img); }
            CGDataProviderRelease(dp);
            CGColorSpaceRelease(cs);
        }
        free(bgra);
    }
    NSString *exeName = [NSString stringWithUTF8String:exe] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{ ww_apply_info(hwnd, info, exeName, icon); });
}

void winios_windowed_note_window_wine(void *hwnd)
{
    if (!winios_windowed_active() || !hwnd) return;
    ww_read_window((uintptr_t)hwnd, 1, 0);
}

static void ww_guest_foreground(uintptr_t hwnd);

void winios_windowed_pump_wine(void)
{
    /* title bar commands, posted from whichever Wine thread pumps first */
    struct { uintptr_t hwnd; unsigned cmd; } cmds[WW_CMDS_MAX];
    int n = 0;
    pthread_mutex_lock(&g_ww_lock);
    if (g_ncmds) { n = g_ncmds; memcpy(cmds, g_cmds, sizeof(cmds[0]) * n); g_ncmds = 0; }
    pthread_mutex_unlock(&g_ww_lock);
    for (int i = 0; i < n; i++) {
        int ok = winios_drv_post_syscommand((void *)cmds[i].hwnd, cmds[i].cmd);
        ww_log("posted WM_SYSCOMMAND 0x%x to hwnd=%p ok=%d", cmds[i].cmd, (void *)cmds[i].hwnd, ok);
    }

    long long now = ww_now_ns();
    /* a tapped window becomes foreground on its own thread */
    uintptr_t fg = atomic_load_explicit(&g_fg_request, memory_order_relaxed);
    if (fg) {
        if (now - atomic_load(&g_fg_request_ns) > 3000000000LL) {
            atomic_compare_exchange_strong(&g_fg_request, &fg, 0);   /* its thread never pumped */
        } else {
            int r = winios_drv_foreground_if_owner((void *)fg);
            if (r && atomic_compare_exchange_strong(&g_fg_request, &fg, 0))
                ww_log("activate hwnd=%p foreground=%d (tap)", (void *)fg, r);
        }
    }

    /* the guest's own activations bring their frame forward (4 Hz) */
    long long next = atomic_load(&g_next_fg_poll_ns);
    if (now >= next && atomic_compare_exchange_strong(&g_next_fg_poll_ns, &next, now + 250000000LL)) {
        uintptr_t gfg = (uintptr_t)winios_drv_foreground_window();
        uintptr_t prev = atomic_exchange(&g_guest_fg, gfg);
        if (gfg && gfg != prev) dispatch_async(dispatch_get_main_queue(), ^{ ww_guest_foreground(gfg); });
    }

    /* window text and styles change without a move (1 Hz) */
    next = atomic_load(&g_next_info_ns);
    if (now >= next && atomic_compare_exchange_strong(&g_next_info_ns, &next, now + 1000000000LL)) {
        uintptr_t list[WW_KNOWN_MAX];
        int k = 0;
        pthread_mutex_lock(&g_ww_lock);
        for (int i = 0; i < g_nknown; i++) list[k++] = g_known[i].hwnd;
        pthread_mutex_unlock(&g_ww_lock);
        for (int i = 0; i < k; i++) ww_read_window(list[i], 0, 0);
    }
}

/* ================================================================== *
 * Main thread: windows, frames, taskbar
 * ================================================================== */

typedef enum { WW_HIDDEN = 0, WW_FRAMED, WW_ATTACHED, WW_LOOSE } ww_kind;
static const char *ww_kind_name(ww_kind k)
{
    switch (k) { case WW_FRAMED: return "framed"; case WW_ATTACHED: return "attached"; case WW_LOOSE: return "loose"; default: return "hidden"; }
}

@class WWFrameView;

@interface WWWin : NSObject {
@public
    uintptr_t hwnd;
    ww_kind kind;
    BOOL infoKnown;
    struct winios_windowed_info info;
    NSString *title, *exe;
    UIImage *icon;
    CALayer *layer;
    CGRect desk;           /* visible rect, desktop px */
    BOOL visible;          /* from the WindowPosChanged hook */
    BOOL placed;           /* the frame has a position */
    BOOL appMinimized;     /* minimized to the taskbar (app side) */
    BOOL fullscreen;
    BOOL maximized;        /* the whole screen, no title bar, taskbar hidden (g_max) */
    BOOL wasShown;
    BOOL everShown;        /* logged as added */
    CGFloat k;             /* frame zoom, points per desktop pixel */
    BOOL userScaled;       /* zoomed with the grip: a size change keeps that zoom */
    BOOL provisional;      /* placed at a placeholder rect (parked off screen, minimized
                              size); placed again at its first real size */
    CGSize fitSize;        /* the desktop size `k` was last fitted to */
    int cascadeStep;       /* its step in the first-placement cascade */
    CGPoint origin;        /* content top-left in the root view */
    uintptr_t group;       /* WW_ATTACHED: the framed window whose host holds it */
    WWFrameView *frame;
}
@end
@implementation WWWin
@end

static UIView *g_root;
static NSMutableDictionary<NSNumber *, WWWin *> *g_wins;
static NSMutableArray<NSNumber *> *g_order;     /* first-seen order, for the taskbar */
static uintptr_t g_top;                          /* frontmost frame's window */
static int g_cascade;

static void ww_update(WWWin *w);
static void ww_apply_frame(WWWin *w);
static void ww_raise(WWWin *w, BOOL activate, const char *why);
static void ww_dock_refresh(void);
static void ww_z_rebuild(void);
static void ww_layout_dock(void);
static CGRect ww_area(void);
static void ww_clamp(WWWin *w);

static BOOL ww_iconic(WWWin *w) { return w->infoKnown && (w->info.style & WW_WS_MINIMIZE); }

/* A rect a window has before its real one: parked off screen (the -32000
 * position of a minimized or still-starting window) or the minimized size
 * (160x31 by default). Never fitted to. */
static BOOL ww_placeholder(CGRect r)
{
    if (r.origin.x <= -10000 || r.origin.y <= -10000) return YES;
    return r.size.width <= 200 && r.size.height <= 40;
}

static BOOL ww_shown(WWWin *w)
{
    if (!w->visible || w->appMinimized || ww_iconic(w)) return NO;
    if (w->infoKnown && !(w->info.style & WW_WS_VISIBLE)) return NO;
    return w->desk.size.width > 0 && w->desk.size.height > 0;
}

/* Gets a taskbar button: an unowned (or WS_EX_APPWINDOW) window, as on Windows. */
static BOOL ww_in_taskbar(WWWin *w)
{
    if (w->kind != WW_FRAMED) return NO;
    if (!w->infoKnown) return YES;
    if (w->info.exstyle & WW_WS_EX_APPWINDOW) return YES;
    return w->info.owner == 0 && !(w->info.exstyle & WW_WS_EX_TOOLWINDOW);
}

static WWWin *ww_get(uintptr_t hwnd, BOOL create)
{
    if (!g_wins) { g_wins = [NSMutableDictionary new]; g_order = [NSMutableArray new]; }
    NSNumber *key = @(hwnd);
    WWWin *w = g_wins[key];
    if (!w && create) {
        w = [WWWin new];
        w->hwnd = hwnd;
        w->k = 1;
        g_wins[key] = w;
        [g_order addObject:key];
    }
    return w;
}

/* The framed window an owned popup rides with: its owner's group, else the
 * owner itself, else the root owner. 0 when none of them is framed. */
static uintptr_t ww_group_for(WWWin *w)
{
    uintptr_t cands[2] = { (uintptr_t)w->info.owner, (uintptr_t)w->info.root_owner };
    for (int i = 0; i < 2; i++) {
        WWWin *o = cands[i] && cands[i] != w->hwnd ? ww_get(cands[i], NO) : nil;
        if (!o) continue;
        if (o->kind == WW_FRAMED && o->frame) return o->hwnd;
        if (o->kind == WW_ATTACHED && o->group && o->group != w->hwnd) return o->group;
    }
    return 0;
}

static ww_kind ww_classify(WWWin *w)
{
    if (!w->infoKnown) return WW_HIDDEN;      /* not read yet: shown once its info arrives */
    if (w->info.kind != 2) return WW_HIDDEN;                       /* the desktop window: black background */
    if (w->info.style & WW_WS_CHILD) return WW_HIDDEN;
    /* explorer's own taskbar (the Start menu of a Desktop session): a frame of
     * its own the user can move out of the way; not in our taskbar (tool window) */
    if (!strcmp(w->info.cls, "Shell_TrayWnd")) return WW_FRAMED;
    BOOL owned = w->info.owner != 0 && !(w->info.exstyle & WW_WS_EX_APPWINDOW);
    if (owned) {
        if ((w->info.style & WW_WS_CAPTION) == WW_WS_CAPTION) return WW_FRAMED;   /* a dialog */
        return ww_group_for(w) ? WW_ATTACHED : WW_LOOSE;               /* menus, tooltips, drop-downs */
    }
    if ((w->info.exstyle & WW_WS_EX_TOOLWINDOW) && !(w->info.exstyle & WW_WS_EX_APPWINDOW)) return WW_LOOSE;
    return WW_FRAMED;
}

static NSString *ww_display_title(WWWin *w)
{
    if (w->title.length) return w->title;
    if (w->exe.length) return w->exe;
    return [NSString stringWithFormat:@"Window %lx", (unsigned long)w->hwnd];
}

/* A window with a taskbar button: shown, minimized to the taskbar, or
 * minimized by the program itself (also one first shown minimized); not a
 * hidden window. */
static BOOL ww_present(WWWin *w)
{
    if (!ww_in_taskbar(w)) return NO;
    BOOL alive = w->visible && (w->info.style & WW_WS_VISIBLE);
    return ww_shown(w) || (alive && (w->appMinimized || ww_iconic(w)));
}

/* Round 4: the first Steam window of the session (the client's program,
 * steam.exe, or its web helper, which owns the client's UI windows). */
static WWWin *ww_steam_window(void)
{
    for (NSNumber *key in g_order) {
        WWWin *w = g_wins[key];
        if (!w || !w->exe.length || !ww_present(w)) continue;
        if ([w->exe caseInsensitiveCompare:@"steam"] == NSOrderedSame ||
            [w->exe caseInsensitiveCompare:@"steamwebhelper"] == NSOrderedSame) return w;
    }
    return nil;
}

/* ------------------------------------------------------------------ *
 * Views
 * ------------------------------------------------------------------ */

@interface WWRootView : UIView
@end

/* Chrome that a game controller's focus engine (or keyboard focus navigation)
 * can never reach: the pad's input belongs to the program in the frame. */
@interface WWButton : UIButton
@end
@implementation WWButton
- (BOOL)canBecomeFocused { return NO; }
@end

@interface WWAppStrip : UIScrollView
@end
@implementation WWAppStrip
- (BOOL)canBecomeFocused { return NO; }
@end

/* The taskbar's search field: never focusable, and first responder only from
 * a touch on it (a controller's A on a focused field opened the keyboard). */
@interface WWSearchField : UITextField
@property (nonatomic) CFTimeInterval touchedAt;
@end
@implementation WWSearchField
- (BOOL)canBecomeFocused { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit && event.type == UIEventTypeTouches) _touchedAt = CACurrentMediaTime();
    return hit;
}
- (BOOL)becomeFirstResponder {
    if (self.isFirstResponder) return YES;
    if (_touchedAt <= 0 || CACurrentMediaTime() - _touchedAt > 2.0) {
        static int logged;
        if (logged < 16 && ++logged)
            ww_log("search field: first responder refused (not a touch on it; the keyboard stays with the program)");
        return NO;
    }
    return [super becomeFirstResponder];
}
/* Round 4: the magnifier sits 11 points in from the field's rounded edge and
 * 7 points before the text, which keeps 10 points from the right edge (the
 * clear button, while editing, takes its own room). */
static const CGFloat WW_GLASS_X = 11, WW_GLASS_SIDE = 15, WW_GLASS_GAP = 7, WW_SEARCH_RIGHT = 10;
- (CGRect)leftViewRectForBounds:(CGRect)bounds {
    return CGRectMake(WW_GLASS_X, floor((bounds.size.height - WW_GLASS_SIDE) / 2), WW_GLASS_SIDE, WW_GLASS_SIDE);
}
- (CGRect)ww_textRect:(CGRect)r bounds:(CGRect)bounds {
    CGFloat x = WW_GLASS_X + WW_GLASS_SIDE + WW_GLASS_GAP;
    CGFloat maxX = MIN(CGRectGetMaxX(r), bounds.size.width - WW_SEARCH_RIGHT);
    r.origin.x = x;
    r.size.width = MAX(maxX - x, 0);
    return r;
}
- (CGRect)textRectForBounds:(CGRect)bounds { return [self ww_textRect:[super textRectForBounds:bounds] bounds:bounds]; }
- (CGRect)editingRectForBounds:(CGRect)bounds { return [self ww_textRect:[super editingRectForBounds:bounds] bounds:bounds]; }
- (CGRect)placeholderRectForBounds:(CGRect)bounds { return [self ww_textRect:[super placeholderRectForBounds:bounds] bounds:bounds]; }
@end

/* A control's action came from a touch (or an accessibility activation), not
 * a press: the focus engine's select (a pad's A, a keyboard's space) sends
 * presses. */
static BOOL ww_by_touch(UIEvent *event, const char *what)
{
    if (!event || event.type == UIEventTypeTouches) return YES;
    static int logged;
    if (logged < 32 && ++logged) ww_log("%s ignored: not a touch (event type %ld; controller or keyboard focus press)", what, (long)event.type);
    return NO;
}

@interface WWFrameView : UIView
@property (nonatomic) uintptr_t hwnd;
@property (nonatomic) BOOL chromeless;
@property (nonatomic) BOOL active;          /* the frontmost frame: brighter title and buttons */
@property (nonatomic, strong) UIVisualEffectView *bar;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIButton *minButton, *fullButton, *maxButton, *closeButton;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) CALayer *host;
@property (nonatomic, strong) UIView *grip;
@property (nonatomic) CGFloat scaleStartK;
@end

@interface WWDock : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UIVisualEffectView *pill;
@property (nonatomic, strong) WWSearchField *search;
@property (nonatomic, strong) WWAppStrip *apps;
@property (nonatomic, strong) UIButton *keyboardButton, *menuButton;
@property (nonatomic, strong) UIButton *steamButton;   /* pinned, left of the program buttons */
@property (nonatomic, strong) UIView *steamDot;
@property (nonatomic, strong) NSMutableArray<UIButton *> *appButtons;
@end

static WWDock *g_dock;

/* Maximize: one framed window fills the whole screen like a game session's
 * picture (no title bar, taskbar hidden, black letterbox); a small floating
 * pill brings the windows back. */
@interface WWPill : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIButton *restoreButton, *menuButton;
@property (nonatomic) unsigned wakeGen;
- (void)wake;
@end
static WWPill *g_pill;
static uintptr_t g_max;   /* the maximized window, 0 when none */
static void ww_set_maximized(WWWin *w, BOOL on, const char *why);

/* A frame was touched or activated: the search field (if a touch opened it)
 * gives the keyboard back to the program. */
static void ww_search_release(const char *why)
{
    if (!g_dock || !g_dock.search.isFirstResponder) return;
    [g_dock.search resignFirstResponder];
    ww_log("search field released (%s): the keyboard goes back to the program", why);
}

/* The Swift side (WindowedMode.swift) for the taskbar's tools. */
static Class ww_bridge(void) { return NSClassFromString(@"MadeiraWindowedBridge"); }
static void ww_bridge_call(NSString *sel)
{
    Class c = ww_bridge();
    SEL s = NSSelectorFromString(sel);
    if (c && [c respondsToSelector:s]) {
        void (*fn)(id, SEL) = (void (*)(id, SEL))[c methodForSelector:s];
        fn(c, s);
    }
}

/* A monochrome glyph in a neutral translucent circle: every button of the
 * chrome (title bars, taskbar, restore pill) looks like this; no colours. */
static UIImage *ww_glyph(NSString *symbol, CGFloat side)
{
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:round(side * 0.42)
                                                                                      weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:symbol withConfiguration:cfg];
}

static UIButton *ww_round_button(NSString *symbol, CGFloat side)
{
    UIButton *b = [WWButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, side, side);
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    b.layer.cornerRadius = side / 2;
    [b setImage:ww_glyph(symbol, side) forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:1 alpha:0.92];
    return b;
}

/* Title-bar buttons: a little brighter on the active (frontmost) frame. */
static void ww_style_glyph_button(UIButton *b, BOOL active)
{
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:active ? 0.17 : 0.09];
    b.tintColor = [UIColor colorWithWhite:1 alpha:active ? 0.95 : 0.55];
}

/* The chrome's one material (title bars, taskbar pill, restore pill): a dark
 * translucent blur with a hairline edge and a faint highlight along the top.
 * ww_material_fit lays the highlight out after a size change. */
static UIVisualEffectView *ww_material(CGFloat radius, CACornerMask corners)
{
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:
                             [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    v.layer.cornerRadius = radius;
    v.layer.maskedCorners = corners;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    v.layer.borderWidth = 0.5;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.name = @"ww_sheen";
    sheen.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.09].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
    [v.contentView.layer insertSublayer:sheen atIndex:0];
    CALayer *line = [CALayer layer];
    line.name = @"ww_highlight";
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    [v.contentView.layer insertSublayer:line above:sheen];
    return v;
}

static void ww_material_fit(UIVisualEffectView *v)
{
    CGRect b = v.bounds;
    CGFloat hair = 1.0 / MAX(UIScreen.mainScreen.scale, 1);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in v.contentView.layer.sublayers) {
        if ([l.name isEqualToString:@"ww_sheen"]) l.frame = CGRectMake(0, 0, b.size.width, MIN(b.size.height * 0.55, 20));
        else if ([l.name isEqualToString:@"ww_highlight"]) l.frame = CGRectMake(0, 0, b.size.width, hair);
    }
    [CATransaction commit];
}

/* The Swift bridge's BOOL class methods (nil bridge: NO). */
static BOOL ww_bridge_bool(NSString *sel)
{
    Class c = NSClassFromString(@"MadeiraWindowedBridge");
    SEL s = NSSelectorFromString(sel);
    if (!c || ![c respondsToSelector:s]) return NO;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))[c methodForSelector:s];
    return fn(c, s);
}

@implementation WWRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    /* window content and the background belong to the game view underneath,
     * which maps the touch through winios_windowed_map_point */
    if (!hit || hit == self || [hit isKindOfClass:[WWFrameView class]]) return nil;
    return hit;
}
- (BOOL)canBecomeFocused { return NO; }
- (void)layoutSubviews {
    [super layoutSubviews];
    ww_layout_dock();
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    winios_windowed_relayout();
}
@end

@implementation WWFrameView
- (instancetype)initWithHwnd:(uintptr_t)hwnd chromeless:(BOOL)chromeless {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _hwnd = hwnd;
    _chromeless = chromeless;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    if (!chromeless) {
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 4);
    }
    _content = [[UIView alloc] initWithFrame:CGRectZero];
    _content.userInteractionEnabled = NO;   /* touches go to the game view's mapping */
    _content.clipsToBounds = NO;            /* owned popups may hang outside */
    _content.backgroundColor = chromeless ? UIColor.clearColor : UIColor.blackColor;
    [self addSubview:_content];
    _host = [CALayer layer];
    _host.anchorPoint = CGPointZero;
    _host.position = CGPointZero;
    [_content.layer addSublayer:_host];
    if (chromeless) return self;

    /* round 4: a translucent blurred bar (the chrome's material), the title
     * centred in white, monochrome glyph circles; no coloured buttons */
    _bar = ww_material(10, kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
    [self addSubview:_bar];
    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [_bar.contentView addSubview:_label];
    _minButton = ww_round_button(@"minus", WW_BTN);
    _fullButton = ww_round_button(@"arrow.up.left.and.arrow.down.right", WW_BTN);
    /* maximize: "+", the whole screen, no title bar */
    _maxButton = ww_round_button(@"plus", WW_BTN);
    _closeButton = ww_round_button(@"xmark", WW_BTN);
    for (UIButton *b in @[_minButton, _fullButton, _maxButton, _closeButton]) [_bar.contentView addSubview:b];
    _fullButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;   /* the ring while fitted */
    [_minButton addTarget:self action:@selector(minimizePressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [_fullButton addTarget:self action:@selector(fullscreenPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [_maxButton addTarget:self action:@selector(maximizePressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [_closeButton addTarget:self action:@selector(closePressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _minButton.accessibilityLabel = @"Minimize";
    _fullButton.accessibilityLabel = @"Fit to screen";
    _maxButton.accessibilityLabel = @"Maximize";
    _closeButton.accessibilityLabel = @"Close";
    /* holding the fit button maximizes too */
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(fullHeld:)];
    hold.allowedPressTypes = @[];
    [_fullButton addGestureRecognizer:hold];

    /* The title bar drags the frame. Its recognizers take touches only (no
     * presses), so a controller or keyboard focus press never reaches them. */
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    drag.maximumNumberOfTouches = 1;
    [_bar addGestureRecognizer:drag];
    UITapGestureRecognizer *twice = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(fullscreenTapped)];
    twice.numberOfTapsRequired = 2;
    twice.allowedPressTypes = @[];
    [_bar addGestureRecognizer:twice];
    UITapGestureRecognizer *once = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(barTapped)];
    once.allowedPressTypes = @[];
    [once requireGestureRecognizerToFail:twice];
    [_bar addGestureRecognizer:once];

    /* bottom-right grip: drag to zoom the window (the guest window keeps its size) */
    _grip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    _grip.backgroundColor = UIColor.clearColor;
    CAShapeLayer *lines = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(22, 10)]; [p addLineToPoint:CGPointMake(10, 22)];
    [p moveToPoint:CGPointMake(22, 16)]; [p addLineToPoint:CGPointMake(16, 22)];
    lines.path = p.CGPath;
    lines.strokeColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
    lines.lineWidth = 2;
    lines.lineCap = kCALineCapRound;
    lines.shadowColor = UIColor.blackColor.CGColor;
    lines.shadowOpacity = 0.8;
    lines.shadowRadius = 1;
    lines.shadowOffset = CGSizeZero;
    [_grip.layer addSublayer:lines];
    [_grip addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(gripDragged:)]];
    [self addSubview:_grip];
    return self;
}

- (BOOL)canBecomeFocused { return NO; }

- (WWWin *)win { return ww_get(_hwnd, NO); }

- (void)barTapped { WWWin *w = [self win]; if (w) ww_raise(w, YES, "tap"); }

- (void)minimizePressed:(UIButton *)b forEvent:(UIEvent *)e { if (ww_by_touch(e, "minimize button")) [self minimizeTapped]; }
- (void)fullscreenPressed:(UIButton *)b forEvent:(UIEvent *)e { if (ww_by_touch(e, "fullscreen button")) [self fullscreenTapped]; }
- (void)closePressed:(UIButton *)b forEvent:(UIEvent *)e { if (ww_by_touch(e, "close button")) [self closeTapped]; }
- (void)maximizePressed:(UIButton *)b forEvent:(UIEvent *)e {
    WWWin *w = [self win];
    if (w && ww_by_touch(e, "maximize button")) ww_set_maximized(w, YES, "button");
}
- (void)fullHeld:(UILongPressGestureRecognizer *)g {
    WWWin *w = [self win];
    if (w && g.state == UIGestureRecognizerStateBegan) ww_set_maximized(w, YES, "fit button held");
}

- (void)minimizeTapped {
    WWWin *w = [self win];
    if (!w) return;
    w->appMinimized = YES;
    ww_log("minimize hwnd=%p (to the taskbar; app side, the program is not told)", (void *)w->hwnd);
    ww_update(w);
}

- (void)fullscreenTapped {
    WWWin *w = [self win];
    if (!w) return;
    w->fullscreen = !w->fullscreen;
    if (!w->fullscreen && w->placed) ww_clamp(w);
    ww_log("fullscreen hwnd=%p %s", (void *)w->hwnd,
           w->fullscreen ? "on (fit to the screen; the frame stays put, its button shows the shrink arrows in a ring: tap it or double-tap the title bar to leave)"
                         : "off (back to its movable frame)");
    ww_apply_frame(w);
    ww_raise(w, YES, "fullscreen");
}

/* A fitted (fullscreen) frame does not move: show where the way out is. */
- (void)pulseFullButton {
    [UIView animateWithDuration:0.12 animations:^{ self.fullButton.transform = CGAffineTransformMakeScale(1.3, 1.3); }
                     completion:^(BOOL done) {
        [UIView animateWithDuration:0.18 animations:^{ self.fullButton.transform = CGAffineTransformIdentity; }];
    }];
}

- (void)closeTapped {
    WWWin *w = [self win];
    if (!w) return;
    ww_log("close hwnd=%p \"%s\" (WM_SYSCOMMAND SC_CLOSE -> WM_CLOSE)", (void *)w->hwnd, ww_display_title(w).UTF8String);
    ww_enqueue(w->hwnd, WW_SC_CLOSE);
}

- (void)dragged:(UIPanGestureRecognizer *)g {
    WWWin *w = [self win];
    if (!w) return;
    if (w->fullscreen) {
        if (g.state == UIGestureRecognizerStateBegan) {
            ww_raise(w, YES, "drag");
            ww_log("move hwnd=%p ignored: fullscreen (fitted) frames stay put; the ringed fit button or a double tap on the title bar leaves fullscreen",
                   (void *)w->hwnd);
            [self pulseFullButton];
        }
        return;
    }
    if (g.state == UIGestureRecognizerStateBegan) ww_raise(w, YES, "drag");
    CGPoint t = [g translationInView:self.superview];
    [g setTranslation:CGPointZero inView:self.superview];
    w->origin.x += t.x;
    w->origin.y += t.y;
    ww_clamp(w);   /* the title bar never leaves the screen, so it can always be grabbed again */
    ww_apply_frame(w);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
        ww_log("move hwnd=%p to (%.0f,%.0f) pt (app side; the guest window stays at %.0f,%.0f)",
               (void *)w->hwnd, w->origin.x, w->origin.y, w->desk.origin.x, w->desk.origin.y);
}

- (void)gripDragged:(UIPanGestureRecognizer *)g {
    WWWin *w = [self win];
    if (!w || w->fullscreen || w->desk.size.width <= 0) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _scaleStartK = w->k;
        w->userScaled = YES;   /* from now on a size change keeps this zoom */
        ww_raise(w, NO, "zoom");
    }
    CGPoint t = [g translationInView:self.superview];
    CGFloat width = _scaleStartK * w->desk.size.width + MAX(t.x, t.y * w->desk.size.width / MAX(w->desk.size.height, 1));
    w->k = MIN(MAX(width / w->desk.size.width, 0.15), 3.0);
    ww_clamp(w);
    ww_apply_frame(w);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
        ww_log("scale hwnd=%p zoom=%.2f pt/px (the guest window keeps its size; kept when it resizes)", (void *)w->hwnd, w->k);
}

- (void)layoutChrome:(CGFloat)width {
    if (_chromeless) return;
    _bar.frame = CGRectMake(0, 0, width, WW_BAR_H);
    ww_material_fit(_bar);
    CGFloat side = WW_BTN, gap = WW_BTN_GAP, x = width - (WW_BAR_H - side) / 2 - 2 - side;
    for (UIButton *b in @[_closeButton, _maxButton, _fullButton, _minButton]) {
        b.frame = CGRectMake(x, (WW_BAR_H - side) / 2, side, side);
        x -= side + gap;
    }
    CGFloat buttons = 4 * side + 3 * gap + 14;
    if (width >= 2 * buttons + 80) _label.frame = CGRectMake(buttons, 0, width - 2 * buttons, WW_BAR_H);   /* centred */
    else _label.frame = CGRectMake(12, 0, MAX(width - buttons - 16, 0), WW_BAR_H);   /* narrow: left of the buttons */
    WWWin *w = [self win];
    BOOL full = w && w->fullscreen;
    /* fullscreen (fit) is a state the frame is in (it cannot be dragged): the
     * button says so with the shrink arrows and a light ring, not a colour */
    [_fullButton setImage:ww_glyph(full ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right", side)
                 forState:UIControlStateNormal];
    _fullButton.layer.borderWidth = full ? 1.5 : 0;
    _fullButton.accessibilityLabel = full ? @"Leave fit to screen" : @"Fit to screen";
    [self applyActive];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [self applyActive];
}

- (void)applyActive {
    if (_chromeless) return;
    for (UIButton *b in @[_minButton, _fullButton, _maxButton, _closeButton]) ww_style_glyph_button(b, _active);
    _label.textColor = [UIColor colorWithWhite:1 alpha:_active ? 1 : 0.62];
}

/* Touches a little outside the round buttons still hit them (a 35x36 point
 * target around each 28-point circle; the gaps are split between neighbours). */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_chromeless && !self.hidden && !_bar.hidden) {
        for (UIButton *b in @[_closeButton, _maxButton, _fullButton, _minButton]) {
            CGRect r = CGRectInset([self convertRect:b.frame fromView:b.superview], -WW_BTN_GAP / 2, -(WW_BAR_H - WW_BTN) / 2);
            if (CGRectContainsPoint(r, point)) return b;
        }
    }
    return [super hitTest:point withEvent:event];
}
@end

@implementation WWDock
- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _appButtons = [NSMutableArray new];
    _pill = ww_material(WW_DOCK_H / 2, kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                       kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
    [self addSubview:_pill];

    _search = [[WWSearchField alloc] initWithFrame:CGRectZero];
    _search.placeholder = @"Search";
    _search.textColor = UIColor.whiteColor;
    _search.font = [UIFont systemFontOfSize:14];
    _search.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _search.layer.cornerRadius = WW_DOCK_ITEM / 2 - 1;
    _search.returnKeyType = UIReturnKeyGo;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    _search.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.5]}];
    /* placed by WWSearchField's rects: 11 points in from the edge, 7 before the text */
    UIImageView *glass = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium]]];
    glass.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    glass.contentMode = UIViewContentModeScaleAspectFit;
    glass.frame = CGRectMake(0, 0, WW_GLASS_SIDE, WW_GLASS_SIDE);
    _search.leftView = glass;
    _search.leftViewMode = UITextFieldViewModeAlways;
    _search.delegate = self;
    [_search addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];
    [_pill.contentView addSubview:_search];

    _apps = [[WWAppStrip alloc] initWithFrame:CGRectZero];
    _apps.showsHorizontalScrollIndicator = NO;
    [_pill.contentView addSubview:_apps];

    _keyboardButton = ww_round_button(@"keyboard", WW_DOCK_ITEM);
    [_keyboardButton addTarget:self action:@selector(keyboardPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _keyboardButton.accessibilityLabel = @"Keyboard";
    _menuButton = ww_round_button(@"line.3.horizontal", WW_DOCK_ITEM);
    [_menuButton addTarget:self action:@selector(menuPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _menuButton.accessibilityLabel = @"Menu";
    BOOL bridge = ww_bridge() != nil;
    _keyboardButton.hidden = _menuButton.hidden = !bridge;
    [_pill.contentView addSubview:_keyboardButton];
    [_pill.contentView addSubview:_menuButton];

    /* Steam, pinned left of the program buttons: a monochrome placeholder
     * glyph (no Valve artwork in the repository) on a rounded tile, a dot
     * under it while a Steam window is open. env.MADEIRA_WINDOWED_STEAM = 0
     * (WindowedMode.swift) hides it. */
    _steamButton = [WWButton buttonWithType:UIButtonTypeCustom];
    _steamButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    _steamButton.layer.cornerRadius = 9;
    _steamButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_steamButton setImage:ww_glyph(@"gamecontroller", WW_DOCK_ITEM) forState:UIControlStateNormal];
    _steamButton.tintColor = [UIColor colorWithWhite:1 alpha:0.92];
    _steamButton.accessibilityLabel = @"Steam";
    [_steamButton addTarget:self action:@selector(steamPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _steamButton.hidden = !bridge || !ww_bridge_bool(@"steamButtonEnabled");
    [_pill.contentView addSubview:_steamButton];
    _steamDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, 5)];
    _steamDot.layer.cornerRadius = 2.5;
    _steamDot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    _steamDot.userInteractionEnabled = NO;
    _steamDot.hidden = YES;
    [_pill.contentView addSubview:_steamDot];
    return self;
}

- (BOOL)canBecomeFocused { return NO; }

/* The keyboard and menu buttons answer a touch only: a controller's A on a
 * focused button opened the keyboard over the game. */
- (void)keyboardPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar keyboard button")) return;
    [_search resignFirstResponder];
    ww_bridge_call(@"toggleKeyboard");
}
- (void)menuPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar menu button")) return;
    [_search resignFirstResponder];
    ww_bridge_call(@"openMenu");
}
/* The pinned Steam button. A Steam window already open in this session comes
 * to the front (restored first when minimized). Otherwise the Swift side
 * decides: memory warning, then Steam (installed) or Valve's installer (not
 * installed) as a library entry for the next start; a running session cannot
 * start another program from the app. */
- (void)steamPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar Steam button")) return;
    [_search resignFirstResponder];
    WWWin *w = ww_steam_window();
    if (w) {
        if (w->appMinimized || ww_iconic(w)) {
            if (ww_iconic(w)) ww_enqueue(w->hwnd, WW_SC_RESTORE);
            w->appMinimized = NO;
            ww_update(w);
        }
        ww_raise(w, YES, "taskbar Steam button");
        ww_log("steam: launch (already running in this session: hwnd=%p \"%s\" exe=%s brought to the front)",
               (void *)w->hwnd, ww_display_title(w).UTF8String, w->exe.UTF8String);
        return;
    }
    ww_log("steam: button (no Steam window in this session; the app checks the install)");
    ww_bridge_call(@"steamTapped");
}

- (void)searchChanged { ww_dock_refresh(); }

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    /* Go: bring the first matching window to the front. Nothing typed: just
     * close the keyboard (Go on an empty field activated another program). */
    NSString *typed = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    UIButton *first = nil;
    if (typed.length) for (UIButton *b in _appButtons) if (!b.hidden) { first = b; break; }
    [field resignFirstResponder];
    if (first) {
        WWWin *w = ww_get((uintptr_t)first.tag, NO);
        if (w) {
            if (w->appMinimized || ww_iconic(w)) {
                if (ww_iconic(w)) ww_enqueue(w->hwnd, WW_SC_RESTORE);
                w->appMinimized = NO;
                ww_log("restore hwnd=%p (search)", (void *)w->hwnd);
                ww_update(w);
            }
            ww_raise(w, YES, "search");
        }
    }
    field.text = @"";
    ww_dock_refresh();
    return NO;
}

- (void)appTapped:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar button")) return;
    [_search resignFirstResponder];
    WWWin *w = ww_get((uintptr_t)b.tag, NO);
    if (!w) return;
    if (w->appMinimized || ww_iconic(w)) {
        if (ww_iconic(w)) ww_enqueue(w->hwnd, WW_SC_RESTORE);   /* the program minimized itself */
        w->appMinimized = NO;
        ww_log("restore hwnd=%p \"%s\"%s", (void *)w->hwnd, ww_display_title(w).UTF8String,
               ww_iconic(w) ? " (SC_RESTORE posted)" : "");
        ww_update(w);
        ww_raise(w, YES, "taskbar");
    } else if (g_top == w->hwnd) {
        w->appMinimized = YES;
        ww_log("minimize hwnd=%p (taskbar; app side, the program is not told)", (void *)w->hwnd);
        ww_update(w);
    } else {
        ww_raise(w, YES, "taskbar");
    }
}
@end

/* The floating pill shown while a window is maximized: back to the windows,
 * and the in-game menu. Dims to 30 % after a few seconds; a touch on it wakes
 * it. Not focusable, touch only, as the rest of the chrome. */
@implementation WWPill
- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 92, 46)])) return nil;
    /* the chrome's material, as the title bars and the taskbar */
    _blur = ww_material(23, kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
    _blur.frame = self.bounds;
    _blur.userInteractionEnabled = NO;
    [self addSubview:_blur];
    NSString *icon = [UIImage systemImageNamed:@"macwindow.on.rectangle"] ? @"macwindow.on.rectangle" : @"rectangle.on.rectangle";
    _restoreButton = ww_round_button(icon, 36);
    _restoreButton.accessibilityLabel = @"Show all windows";
    [_restoreButton addTarget:self action:@selector(restorePressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _menuButton = ww_round_button(@"line.3.horizontal", 36);
    _menuButton.accessibilityLabel = @"Menu";
    [_menuButton addTarget:self action:@selector(menuPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _menuButton.hidden = ww_bridge() == nil;
    [self addSubview:_restoreButton];
    [self addSubview:_menuButton];
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.35;
    self.layer.shadowRadius = 6;
    self.layer.shadowOffset = CGSizeMake(0, 2);
    self.hidden = YES;
    return self;
}
- (BOOL)canBecomeFocused { return NO; }
- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;
    ww_material_fit(_blur);
    _restoreButton.frame = CGRectMake(5, 5, 36, 36);
    _menuButton.frame = CGRectMake(51, 5, 36, 36);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit && event.type == UIEventTypeTouches) [self wake];
    return hit;
}
- (void)wake {
    unsigned gen = ++_wakeGen;
    [UIView animateWithDuration:0.15 animations:^{ self.alpha = 1; }];
    __weak WWPill *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WWPill *s = weakSelf;
        if (!s || s.wakeGen != gen) return;
        [UIView animateWithDuration:0.6 animations:^{ s.alpha = 0.3; }];
    });
}
- (void)restorePressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "restore pill")) return;
    WWWin *w = g_max ? ww_get(g_max, NO) : nil;
    if (w) ww_set_maximized(w, NO, "restore pill");
}
- (void)menuPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "restore pill menu button")) return;
    ww_bridge_call(@"openMenu");
}
@end

static void ww_layout_pill(void)
{
    if (!g_pill || !g_root) return;
    UIEdgeInsets s = g_root.safeAreaInsets;
    CGRect b = g_root.bounds;
    CGFloat w = g_pill.menuButton.hidden ? 46 : 92, h = 46;
    g_pill.frame = CGRectMake(CGRectGetMidX(b) - w / 2, CGRectGetMaxY(b) - MAX(s.bottom, 6) - h - 4, w, h);
}

/* Maximize on / off. On: the window fills the screen (ww_apply_frame), the
 * taskbar hides and the pill shows; one window at a time. App-side, like the
 * other buttons: the guest window keeps its size and position. */
static void ww_set_maximized(WWWin *w, BOOL on, const char *why)
{
    if (!g_root || !w) return;
    if (on) {
        if (w->kind != WW_FRAMED || !w->frame) return;
        if (w->maximized) return;
        WWWin *old = g_max && g_max != w->hwnd ? ww_get(g_max, NO) : nil;
        if (old && old->maximized) ww_set_maximized(old, NO, "another window maximized");
        w->maximized = YES;
        g_max = w->hwnd;
        if (!g_pill) { g_pill = [WWPill new]; [g_root addSubview:g_pill]; }
        g_pill.hidden = NO;
        ww_layout_pill();
        [g_pill wake];
        if (g_dock) g_dock.hidden = YES;
        ww_apply_frame(w);
        ww_raise(w, YES, "maximize");
        ww_log("maximize hwnd=%p on (%s): the whole screen, no title bar, taskbar hidden; the pill at the bottom "
               "or the menu's Show all windows brings the windows back", (void *)w->hwnd, why);
    } else {
        if (!w->maximized) return;
        w->maximized = NO;
        if (g_max == w->hwnd) g_max = 0;
        if (!g_max) {
            if (g_pill) g_pill.hidden = YES;
            if (g_dock) g_dock.hidden = NO;
        }
        if (w->frame) {
            if (w->placed) ww_clamp(w);
            ww_apply_frame(w);
        }
        ww_log("maximize hwnd=%p off (%s): back to its frame", (void *)w->hwnd, why);
        ww_dock_refresh();
        ww_z_rebuild();
    }
}

int winios_windowed_maximized(void)
{
    return g_max != 0;
}

void winios_windowed_unmaximize(void)
{
    void (^run)(void) = ^{
        WWWin *w = g_max ? ww_get(g_max, NO) : nil;
        if (w) ww_set_maximized(w, NO, "menu");
    };
    if (NSThread.isMainThread) run(); else dispatch_async(dispatch_get_main_queue(), run);
}

/* ------------------------------------------------------------------ *
 * Geometry
 * ------------------------------------------------------------------ */

/* Where frames may go: the root view minus the safe area and the taskbar. */
static CGRect ww_area(void)
{
    if (!g_root) return CGRectZero;
    UIEdgeInsets s = g_root.safeAreaInsets;
    CGRect b = g_root.bounds;
    CGFloat top = MAX(s.top, 8), bottom = MAX(s.bottom, 6) + WW_DOCK_H + 8;
    return CGRectMake(b.origin.x + MAX(s.left, 4), b.origin.y + top,
                      MAX(b.size.width - MAX(s.left, 4) - MAX(s.right, 4), 1),
                      MAX(b.size.height - top - bottom, 1));
}

static CGFloat ww_default_k(WWWin *w)
{
    CGRect a = ww_area();
    if (w->desk.size.width <= 0 || w->desk.size.height <= 0) return 1;
    CGFloat k = MIN(1.0, MIN((a.size.width - 16) / w->desk.size.width,
                             (a.size.height - WW_BAR_H - 16) / w->desk.size.height));
    return MAX(k, 0.1);
}

/* Keeps the title bar grabbable: all of its height and at least WW_GRAB
 * points of its width inside the frame area (a drag or a resize may leave
 * the rest of the window off screen). */
static void ww_clamp(WWWin *w)
{
    CGRect a = ww_area();
    CGFloat width = MAX(w->desk.size.width * w->k, WW_MIN_BAR_W);
    CGFloat keep = MIN(WW_GRAB, width);
    CGFloat minX = a.origin.x + keep - width, maxX = CGRectGetMaxX(a) - keep;
    CGFloat minY = a.origin.y + WW_BAR_H, maxY = CGRectGetMaxY(a);
    w->origin.x = MIN(MAX(w->origin.x, minX), MAX(maxX, minX));
    w->origin.y = MIN(MAX(w->origin.y, minY), MAX(maxY, minY));
}

/* Moves a frame that fits the area entirely inside it (only after the
 * program or the screen changed its size, never after a drag). */
static void ww_shift_inside(WWWin *w)
{
    CGRect a = ww_area();
    CGFloat width = MAX(w->desk.size.width * w->k, WW_MIN_BAR_W), height = w->desk.size.height * w->k;
    CGFloat minX = a.origin.x + 8, maxX = CGRectGetMaxX(a) - 8 - width;
    CGFloat minY = a.origin.y + WW_BAR_H + 8, maxY = CGRectGetMaxY(a) - 8 - height;
    w->origin.x = maxX >= minX ? MIN(MAX(w->origin.x, minX), maxX) : minX;
    w->origin.y = maxY >= minY ? MIN(MAX(w->origin.y, minY), maxY) : minY;
}

/* First position of a frame: a dialog over its owner, a program window
 * cascaded from the top-left of the screen. `again`: the window had only a
 * placeholder rect when first placed; this is its first real size, placed in
 * the same cascade step. */
static void ww_place_new(WWWin *w, BOOL again)
{
    w->k = ww_default_k(w);
    w->fitSize = w->desk.size;
    w->provisional = ww_placeholder(w->desk);
    if (!again) w->cascadeStep = g_cascade++ % 6;
    CGRect a = ww_area();
    WWWin *owner = w->infoKnown && w->info.owner ? ww_get((uintptr_t)w->info.owner, NO) : nil;
    if (owner && owner->kind == WW_ATTACHED) owner = ww_get(owner->group, NO);
    if (owner && owner->frame && !owner->frame.hidden && owner->desk.size.width > 0) {
        CGFloat ok = owner->fullscreen || owner->maximized ? owner->frame.content.bounds.size.width / owner->desk.size.width : owner->k;
        CGPoint oc = [g_root convertPoint:CGPointZero fromView:owner->frame.content];
        CGPoint centre = CGPointMake(oc.x + (CGRectGetMidX(w->desk) - owner->desk.origin.x) * ok,
                                     oc.y + (CGRectGetMidY(w->desk) - owner->desk.origin.y) * ok);
        w->origin = CGPointMake(centre.x - w->desk.size.width * w->k / 2, centre.y - w->desk.size.height * w->k / 2);
    } else {
        CGFloat step = 26 * w->cascadeStep;
        CGFloat width = MAX(w->desk.size.width * w->k, WW_MIN_BAR_W), height = w->desk.size.height * w->k;
        CGFloat x = a.size.width > width + 16 ? a.origin.x + (a.size.width - width) / 2 - 40 + step : a.origin.x + 8 + step;
        CGFloat y = a.origin.y + WW_BAR_H + 8 + step;
        /* the cascade step never pushes a fitted window past the area */
        x = MIN(x, CGRectGetMaxX(a) - 8 - width);
        y = MIN(y, CGRectGetMaxY(a) - 8 - height);
        w->origin = CGPointMake(MAX(x, a.origin.x + 8), MAX(y, a.origin.y + WW_BAR_H + 8));
    }
    ww_clamp(w);
    w->placed = YES;
}

static void ww_first_place(WWWin *w) { ww_place_new(w, NO); }

/* The window's desktop size (or the screen) changed after it was placed. A
 * zoom the user did not choose with the grip follows it, so a window that
 * grows past the screen (a program window that starts at a placeholder size
 * and then becomes full-size) comes up fitted, title bar on screen. A
 * placeholder rect (minimized, parked off screen) changes nothing. Returns
 * YES when the frame changed. */
static BOOL ww_refit(WWWin *w, const char *why)
{
    if (w->kind != WW_FRAMED || !w->placed || ww_placeholder(w->desk)) return NO;
    if (w->desk.size.width <= 0 || w->desk.size.height <= 0) return NO;
    if (w->provisional) {
        ww_place_new(w, YES);
        ww_log("refit hwnd=%p rect={%.0f,%.0f %.0fx%.0f} zoom=%.2f (first real size; placed again)",
               (void *)w->hwnd, w->desk.origin.x, w->desk.origin.y, w->desk.size.width, w->desk.size.height, w->k);
        return YES;
    }
    BOOL resized = !CGSizeEqualToSize(w->fitSize, w->desk.size);
    if (w->userScaled) {
        if (!resized) return NO;
        w->fitSize = w->desk.size;
        ww_clamp(w);
        ww_log("refit hwnd=%p rect={%.0f,%.0f %.0fx%.0f} zoom=%.2f (%s; the zoom set with the grip is kept)",
               (void *)w->hwnd, w->desk.origin.x, w->desk.origin.y, w->desk.size.width, w->desk.size.height, w->k, why);
        return YES;
    }
    CGFloat k = ww_default_k(w);
    if (!resized && fabs(k - w->k) < 0.005) return NO;
    w->k = k;
    w->fitSize = w->desk.size;
    ww_shift_inside(w);
    ww_clamp(w);
    ww_log("refit hwnd=%p rect={%.0f,%.0f %.0fx%.0f} zoom=%.2f (%s)",
           (void *)w->hwnd, w->desk.origin.x, w->desk.origin.y, w->desk.size.width, w->desk.size.height, w->k, why);
    return YES;
}

static void ww_apply_frame(WWWin *w)
{
    WWFrameView *f = w->frame;
    CALayer *l = w->layer;
    if (!f || !l || w->desk.size.width <= 0 || w->desk.size.height <= 0) return;
    CGRect lr = l.frame;
    CGFloat sx = lr.size.width > 0 ? lr.size.width / w->desk.size.width : 1;
    CGFloat sy = lr.size.height > 0 ? lr.size.height / w->desk.size.height : sx;
    CGFloat k = w->k;
    BOOL max = w->maximized && w->kind == WW_FRAMED && g_root;
    CGFloat barH = f.chromeless || max ? 0 : WW_BAR_H;
    CGPoint o = w->origin;
    CGRect screen = g_root ? g_root.bounds : CGRectZero;
    if (w->kind == WW_LOOSE) {           /* where the desktop fit puts it */
        k = sx;
        o = lr.origin;
    } else if (max) {                    /* the whole screen, letterboxed, as a game session shows it */
        k = MIN(screen.size.width / w->desk.size.width, screen.size.height / w->desk.size.height);
        o = CGPointMake(CGRectGetMidX(screen) - w->desk.size.width * k / 2,
                        CGRectGetMidY(screen) - w->desk.size.height * k / 2);
    } else if (w->fullscreen) {
        CGRect a = ww_area();
        k = MIN(a.size.width / w->desk.size.width, (a.size.height - barH) / w->desk.size.height);
        o = CGPointMake(CGRectGetMidX(a) - w->desk.size.width * k / 2,
                        a.origin.y + barH + (a.size.height - barH - w->desk.size.height * k) / 2);
    }
    CGSize cs = CGSizeMake(w->desk.size.width * k, w->desk.size.height * k);
    CGFloat width = f.chromeless ? cs.width : MAX(cs.width, WW_MIN_BAR_W);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (max) {
        /* the frame covers the screen in black; the window sits centred in it */
        f.frame = screen;
        f.content.frame = CGRectMake(o.x - screen.origin.x, o.y - screen.origin.y, cs.width, cs.height);
    } else {
        f.frame = CGRectMake(o.x, o.y - barH, width, cs.height + barH);
        f.content.frame = CGRectMake(0, barH, cs.width, cs.height);
    }
    f.host.bounds = lr;
    f.host.position = CGPointZero;
    f.host.transform = CATransform3DMakeScale(k / sx, k / sy, 1);
    [f layoutChrome:width];
    f.grip.frame = CGRectMake(cs.width - 26, barH + cs.height - 26, 26, 26);
    f.grip.hidden = w->fullscreen || max;
    if (!f.chromeless) {
        f.bar.hidden = max;
        f.backgroundColor = max ? UIColor.blackColor : UIColor.clearColor;
        f.layer.shadowOpacity = max ? 0 : 0.45;
        f.layer.shadowPath = max ? NULL : [UIBezierPath bezierPathWithRoundedRect:f.bounds cornerRadius:10].CGPath;
    }
    [CATransaction commit];
}

/* ------------------------------------------------------------------ *
 * Table maintenance
 * ------------------------------------------------------------------ */

static void ww_drop_frame(WWWin *w)
{
    if (!w->frame) return;
    /* keep the window's layer (and any popups) alive in the root until re-placed */
    for (CALayer *sub in [w->frame.host.sublayers copy]) { sub.hidden = YES; [g_root.layer insertSublayer:sub atIndex:0]; }
    [w->frame removeFromSuperview];
    w->frame = nil;
    if (g_top == w->hwnd) g_top = 0;
}

static void ww_put_layer(CALayer *l, CALayer *host, BOOL bottom)
{
    if (!l || l.superlayer == host) {
        if (l && bottom && host.sublayers.firstObject != l) [host insertSublayer:l atIndex:0];
        return;
    }
    if (bottom) [host insertSublayer:l atIndex:0];
    else [host addSublayer:l];
}

static void ww_update(WWWin *w)
{
    if (!g_root || !w->layer) return;
    ww_kind kind = ww_classify(w);
    uintptr_t group = kind == WW_ATTACHED ? ww_group_for(w) : 0;
    if (kind == WW_ATTACHED && !group) kind = WW_LOOSE;
    if (kind != w->kind || (kind == WW_ATTACHED && group != w->group)) {
        if (w->kind == WW_FRAMED || w->kind == WW_LOOSE) {
            if (kind != WW_FRAMED && kind != WW_LOOSE) ww_drop_frame(w);
            else if ((kind == WW_LOOSE) != w->frame.chromeless) ww_drop_frame(w);
        }
        w->kind = kind;
        w->group = group;
    }
    BOOL shown = ww_shown(w);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    switch (w->kind) {
    case WW_HIDDEN:
        if (w->layer.superlayer != g_root.layer) [g_root.layer insertSublayer:w->layer atIndex:0];
        w->layer.hidden = YES;
        break;
    case WW_ATTACHED: {
        WWWin *g = ww_get(w->group, NO);
        if (g && g->frame) {
            ww_put_layer(w->layer, g->frame.host, NO);
            w->layer.hidden = !shown;
        } else {
            w->layer.hidden = YES;   /* its group went away; reclassified on its next update */
        }
        break;
    }
    case WW_FRAMED:
    case WW_LOOSE: {
        if (!w->frame && !shown) {
            /* never shown yet (most top-level windows are hidden helpers): no frame */
            if (w->layer.superlayer != g_root.layer) [g_root.layer insertSublayer:w->layer atIndex:0];
            w->layer.hidden = YES;
            break;
        }
        if (!w->frame) {
            w->frame = [[WWFrameView alloc] initWithHwnd:w->hwnd chromeless:w->kind == WW_LOOSE];
            if (g_dock) [g_root insertSubview:w->frame belowSubview:g_dock];
            else [g_root addSubview:w->frame];
        }
        ww_put_layer(w->layer, w->frame.host, YES);
        if (w->kind == WW_FRAMED && !w->placed && shown) ww_first_place(w);
        else if (w->kind == WW_FRAMED && shown) ww_refit(w, "size changed");   /* no-op unless it did */
        w->frame.label.text = ww_display_title(w);
        w->frame.hidden = !shown || (w->kind == WW_FRAMED && !w->placed);
        if (shown && !w->everShown && (w->everShown = YES))
            ww_log("add hwnd=%p kind=%s title=\"%s\" exe=%s class=%s rect={%.0f,%.0f %.0fx%.0f} zoom=%.2f",
                   (void *)w->hwnd, ww_kind_name(w->kind), ww_display_title(w).UTF8String,
                   w->exe.length ? w->exe.UTF8String : "?", w->info.cls[0] ? w->info.cls : "?",
                   w->desk.origin.x, w->desk.origin.y, w->desk.size.width, w->desk.size.height, w->k);
        break;
    }
    }
    [CATransaction commit];
    BOOL newlyShown = shown && !w->wasShown;
    w->wasShown = shown;
    /* a maximized window that goes away (hidden, minimized) gives the screen back */
    if (w->maximized && (!shown || w->kind != WW_FRAMED))
        ww_set_maximized(w, NO, shown ? "no longer a framed window" : "hidden or minimized");
    if (w->frame) ww_apply_frame(w);
    /* popups riding in this window's host follow its zoom */
    if (newlyShown && w->kind == WW_FRAMED) ww_raise(w, NO, "shown");
    else if (!shown && g_top == w->hwnd) g_top = 0;
    ww_dock_refresh();
    ww_z_rebuild();
}

void winios_windowed_place(void *hwnd, CALayer *layer, int x, int y, int w, int h, int visible)
{
    if (!g_root || !layer) return;
    WWWin *win = ww_get((uintptr_t)hwnd, YES);
    [layer setValue:@((uintptr_t)hwnd) forKey:@"ww_hwnd"];
    CGRect old = win->desk;
    win->layer = layer;
    win->desk = CGRectMake(x, y, w, h);
    win->visible = visible != 0;
    /* the program moved its own window (its title bar dragged inside the
     * frame, or SetWindowPos): the frame follows, so the finger stays on the
     * spot it grabbed and the mapping stays stable */
    if (win->placed && win->kind == WW_FRAMED && !win->fullscreen && !win->provisional && !ww_iconic(win) && visible &&
        old.size.width > 0 && (old.origin.x != x || old.origin.y != y) &&
        fabs(old.origin.x - x) < 16000 && fabs(old.origin.y - y) < 16000) {
        win->origin.x += (x - old.origin.x) * win->k;
        win->origin.y += (y - old.origin.y) * win->k;
        ww_clamp(win);
    }
    ww_update(win);
}

static void ww_apply_info(uintptr_t hwnd, struct winios_windowed_info info, NSString *exe, UIImage *icon)
{
    if (!winios_windowed_active()) return;
    WWWin *w = ww_get(hwnd, YES);   /* kept even before the compositor exists */
    NSString *title = [NSString stringWithUTF8String:info.title] ?: @"";
    BOOL titleChanged = ![title isEqualToString:w->title ?: @""];
    w->info = info;
    w->infoKnown = YES;
    w->title = title;
    if (exe.length) w->exe = exe;
    if (icon) w->icon = icon;
    if (titleChanged && w->wasShown && w->kind == WW_FRAMED)
        ww_log("title hwnd=%p \"%s\"", (void *)hwnd, ww_display_title(w).UTF8String);
    if (!g_root) return;
    if (w->layer) ww_update(w);
    else ww_dock_refresh();
}

void winios_windowed_forget(void *hwnd)
{
    WWWin *w = ww_get((uintptr_t)hwnd, NO);
    pthread_mutex_lock(&g_ww_lock);
    for (int i = 0; i < g_nknown; i++)
        if (g_known[i].hwnd == (uintptr_t)hwnd) { g_known[i] = g_known[--g_nknown]; break; }
    pthread_mutex_unlock(&g_ww_lock);
    pthread_mutex_lock(&g_target_lock);
    if (g_t_latched == (uintptr_t)hwnd) { g_t_latched = 0; g_t_pressed = 0; }
    if (g_t_last == (uintptr_t)hwnd) g_t_last = 0;
    if (g_t_mapped == (uintptr_t)hwnd) g_t_mapped_valid = 0;
    pthread_mutex_unlock(&g_target_lock);
    if (!w) return;
    if (w->everShown)
        ww_log("remove hwnd=%p kind=%s title=\"%s\"", (void *)w->hwnd, ww_kind_name(w->kind), ww_display_title(w).UTF8String);
    if (w->maximized) ww_set_maximized(w, NO, "window destroyed");
    ww_drop_frame(w);
    [w->layer setValue:nil forKey:@"ww_hwnd"];
    [g_wins removeObjectForKey:@((uintptr_t)hwnd)];
    [g_order removeObject:@((uintptr_t)hwnd)];
    /* popups that rode with it look for another home */
    for (WWWin *o in g_wins.allValues) if (o->kind == WW_ATTACHED && o->group == (uintptr_t)hwnd) { o->kind = WW_HIDDEN; ww_update(o); }
    ww_dock_refresh();
    ww_z_rebuild();
}

/* ------------------------------------------------------------------ *
 * Z order, activation
 * ------------------------------------------------------------------ */

static void ww_raise(WWWin *w, BOOL activate, const char *why)
{
    if (w->kind == WW_ATTACHED) { WWWin *g = ww_get(w->group, NO); if (g) w = g; }
    if (!w->frame) return;
    /* the user touched or picked a window (not the program showing or
     * activating one itself): the keyboard is the program's again */
    if (strcmp(why, "shown") && strcmp(why, "guest")) ww_search_release(why);
    [g_root bringSubviewToFront:w->frame];
    if (g_dock) [g_root bringSubviewToFront:g_dock];
    if (g_pill) [g_root bringSubviewToFront:g_pill];   /* the way back from maximize stays on top */
    BOOL changed = g_top != w->hwnd;
    g_top = w->hwnd;
    if (activate) {
        ww_request_foreground(w->hwnd);
        if (changed) ww_log("activate hwnd=%p \"%s\" (%s)", (void *)w->hwnd, ww_display_title(w).UTF8String, why);
    }
    ww_dock_refresh();
    ww_z_rebuild();
}

static void ww_guest_foreground(uintptr_t hwnd)
{
    WWWin *w = ww_get(hwnd, NO);
    if (!w || !g_root) return;
    if (w->kind == WW_ATTACHED) w = ww_get(w->group, NO);
    if (!w || !w->frame || w->frame.hidden || g_top == w->hwnd) return;
    ww_log("activate hwnd=%p \"%s\" (guest)", (void *)w->hwnd, ww_display_title(w).UTF8String);
    ww_raise(w, NO, "guest");
}

/* Rebuilds the topmost-first list of (window, desktop rect) that the event
 * target falls back to for absolute pointer events not mapped from a touch. */
static void ww_z_rebuild(void)
{
    if (!g_root) return;
    int n = 0;
    struct { uintptr_t hwnd; CGRect desk; } z[WW_Z_MAX];
    for (UIView *v in g_root.subviews.reverseObjectEnumerator) {
        if (![v isKindOfClass:[WWFrameView class]] || v.hidden) continue;
        WWFrameView *f = (WWFrameView *)v;
        for (CALayer *l in f.host.sublayers.reverseObjectEnumerator) {
            NSNumber *h = [l valueForKey:@"ww_hwnd"];
            WWWin *w = h ? ww_get(h.unsignedLongValue, NO) : nil;
            if (!w || l.hidden || n >= WW_Z_MAX) continue;
            z[n].hwnd = w->hwnd; z[n].desk = w->desk; n++;
        }
    }
    pthread_mutex_lock(&g_target_lock);
    memcpy(g_z, z, sizeof(z[0]) * n);
    g_nz = n;
    pthread_mutex_unlock(&g_target_lock);
}

/* ------------------------------------------------------------------ *
 * Taskbar
 * ------------------------------------------------------------------ */

static UIImage *ww_letter_icon(NSString *name)
{
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    UIImage *cached = cache[name];
    if (cached) return cached;
    NSString *letter = @"?";
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) {
            letter = [[name substringWithRange:NSMakeRange(i, 1)] uppercaseString];
            break;
        }
    }
    unsigned h = 5381;
    for (NSUInteger i = 0; i < name.length; i++) h = h * 33 + [name characterAtIndex:i];
    UIColor *bg = [UIColor colorWithHue:(h % 360) / 360.0 saturation:0.55 brightness:0.7 alpha:1];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(34, 34)];
    if (cache.count > 64) [cache removeAllObjects];
    UIImage *image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [bg setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 34, 34) cornerRadius:8] fill];
        NSDictionary *a = @{NSFontAttributeName: [UIFont systemFontOfSize:18 weight:UIFontWeightBold],
                            NSForegroundColorAttributeName: UIColor.whiteColor};
        CGSize s = [letter sizeWithAttributes:a];
        [letter drawAtPoint:CGPointMake((34 - s.width) / 2, (34 - s.height) / 2) withAttributes:a];
    }];
    cache[name] = image;
    return image;
}

static void ww_layout_dock(void)
{
    ww_layout_pill();
    WWDock *d = g_dock;
    if (!d || !g_root) return;
    UIEdgeInsets s = g_root.safeAreaInsets;
    CGRect b = g_root.bounds;
    /* Round 4: search, Steam, the program buttons, keyboard, menu, with one
     * even gap (WW_DOCK_GAP) between every two items and the same inset
     * (WW_DOCK_PAD) at both ends; icons and round buttons share one size. When
     * the screen is too narrow only the program strip shrinks (it scrolls). */
    const CGFloat item = WW_DOCK_ITEM, gap = WW_DOCK_GAP, pad = WW_DOCK_PAD;
    NSUInteger shownApps = 0;
    for (UIButton *btn in d.appButtons) if (!btn.hidden) shownApps++;
    BOOL tools = !d.keyboardButton.hidden, steam = !d.steamButton.hidden;
    CGFloat appsW = shownApps ? shownApps * item + (shownApps - 1) * gap : 0;
    CGFloat fixed = pad + WW_SEARCH_W + (steam ? gap + item : 0) + (tools ? 2 * (gap + item) : 0) + pad;
    CGFloat want = fixed + (shownApps ? gap + appsW : 0);
    CGFloat maxW = b.size.width - MAX(s.left, 8) - MAX(s.right, 8);
    CGFloat width = MIN(want, maxW);
    CGFloat y = b.size.height - MAX(s.bottom, 6) - WW_DOCK_H;
    d.frame = CGRectMake(round((b.size.width - width) / 2), y, width, WW_DOCK_H);
    d.pill.frame = d.bounds;
    ww_material_fit(d.pill);
    CGFloat mid = WW_DOCK_H / 2, x = pad;
    d.search.frame = CGRectMake(x, mid - (item - 2) / 2, WW_SEARCH_W, item - 2);
    x += WW_SEARCH_W;
    if (steam) {
        x += gap;
        d.steamButton.frame = CGRectMake(x, mid - item / 2, item, item);
        d.steamDot.frame = CGRectMake(x + (item - 5) / 2, WW_DOCK_H - 7.5, 5, 5);
        x += item;
    }
    CGFloat stripW = shownApps ? MIN(MAX(width - fixed - gap, 0), appsW) : 0;
    d.apps.frame = CGRectMake(shownApps ? x + gap : x, 0, stripW, WW_DOCK_H);
    CGFloat ax = 0;
    for (UIButton *btn in d.appButtons) {
        if (btn.hidden) continue;
        btn.frame = CGRectMake(ax, 0, item, WW_DOCK_H);
        ax += item + gap;
    }
    d.apps.contentSize = CGSizeMake(appsW, WW_DOCK_H);
    CGFloat tx = width - pad - (2 * item + gap);
    d.keyboardButton.frame = CGRectMake(tx, mid - item / 2, item, item);
    d.menuButton.frame = CGRectMake(tx + item + gap, mid - item / 2, item, item);
}

/* The frontmost frame's title bar is the bright one. */
static void ww_mark_active(void)
{
    for (WWWin *w in g_wins.allValues)
        if (w->frame && !w->frame.chromeless) w->frame.active = w->hwnd == g_top;
}

static void ww_dock_refresh(void)
{
    WWDock *d = g_dock;
    if (!d) return;
    NSString *filter = [d.search.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<WWWin *> *list = [NSMutableArray new];
    for (NSNumber *key in g_order) {
        WWWin *w = g_wins[key];
        if (!w || !ww_present(w)) continue;
        [list addObject:w];
    }
    while (d.appButtons.count < list.count) {
        UIButton *b = [WWButton buttonWithType:UIButtonTypeCustom];
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, (WW_DOCK_H - WW_DOCK_ITEM) / 2, WW_DOCK_ITEM, WW_DOCK_ITEM)];
        iv.tag = 1;
        iv.layer.cornerRadius = 9;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.clipsToBounds = YES;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake((WW_DOCK_ITEM - 5) / 2, WW_DOCK_H - 7.5, 5, 5)];
        dot.tag = 2;
        dot.layer.cornerRadius = 2.5;
        dot.userInteractionEnabled = NO;
        [b addSubview:dot];
        [b addTarget:d action:@selector(appTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [d.apps addSubview:b];
        [d.appButtons addObject:b];
    }
    for (NSUInteger i = 0; i < d.appButtons.count; i++) {
        UIButton *b = d.appButtons[i];
        if (i >= list.count) { b.hidden = YES; b.tag = 0; continue; }
        WWWin *w = list[i];
        NSString *name = ww_display_title(w);
        BOOL match = !filter.length || [name localizedCaseInsensitiveContainsString:filter] ||
                     (w->exe.length && [w->exe localizedCaseInsensitiveContainsString:filter]);
        b.hidden = !match;
        b.tag = (NSInteger)w->hwnd;
        b.accessibilityLabel = name;
        UIImageView *iv = [b viewWithTag:1];
        iv.image = w->icon ?: ww_letter_icon(w->exe.length ? w->exe : name);
        BOOL minimized = w->appMinimized || ww_iconic(w);
        iv.alpha = minimized ? 0.45 : 1;
        UIView *dot = [b viewWithTag:2];
        dot.backgroundColor = g_top == w->hwnd && !minimized ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.45];
    }
    WWWin *steam = d.steamButton.hidden ? nil : ww_steam_window();
    d.steamDot.hidden = steam == nil;
    if (steam) d.steamDot.backgroundColor = g_top == steam->hwnd ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.45];
    ww_mark_active();
    ww_layout_dock();
}

/* ------------------------------------------------------------------ *
 * Root lifecycle
 * ------------------------------------------------------------------ */

UIView *winios_windowed_make_root(CGRect frame)
{
    WWRootView *root = [[WWRootView alloc] initWithFrame:frame];
    root.userInteractionEnabled = YES;
    root.clipsToBounds = YES;
    root.backgroundColor = UIColor.blackColor;   /* the desktop: black */
    g_root = root;
    if (!g_wins) { g_wins = [NSMutableDictionary new]; g_order = [NSMutableArray new]; }
    g_dock = [WWDock new];
    [root addSubview:g_dock];
    /* Gamepad events under the frames and the taskbar go to the Game
     * Controller framework (GamepadInput.swift, which feeds the guest), not to
     * UIKit focus navigation: the root sits beside the game view, outside the
     * views that already claim them. env.MADEIRA_XINPUT = 0 (no physical pads
     * for the guest) leaves UIKit's default. */
    char cfg[16];
    const char *xinput = madeira_cfg_get("env.MADEIRA_XINPUT", cfg, sizeof(cfg)) ? cfg : getenv("MADEIRA_XINPUT");
    BOOL claim = !(xinput && xinput[0] == '0' && !xinput[1]);   /* as GamepadInput.enabled reads it */
    if (claim) {
        if (@available(iOS 18.0, *)) {
            GCEventInteraction *gi = [GCEventInteraction new];
            gi.handledEventTypes = GCUIEventTypeGamepad;
            [root addInteraction:gi];
        }
    }
    ww_layout_dock();
    ww_log("compositor root attached: frames + taskbar (madeira.cfg windowed = 0 or env.MADEIRA_WINDOWED = 0 turns it off); "
           "chrome not focusable, gamepad events %s",
           claim ? "claimed for the Game Controller framework" : "left to UIKit (env.MADEIRA_XINPUT = 0)");
    ww_log("steam: taskbar button %s", g_dock.steamButton.hidden
           ? "hidden (env.MADEIRA_WINDOWED_STEAM = 0, or no Swift bridge)" : "pinned (env.MADEIRA_WINDOWED_STEAM = 0 hides it)");
    return root;
}

static void ww_clear_all(void)
{
    for (WWWin *w in g_wins.allValues) [w->frame removeFromSuperview];
    [g_wins removeAllObjects];
    [g_order removeAllObjects];
    g_top = 0;
    g_cascade = 0;
    g_max = 0;
    g_pill.hidden = YES;
    g_dock.hidden = NO;
    pthread_mutex_lock(&g_target_lock);
    g_t_latched = g_t_last = g_t_mapped = 0;
    g_t_pressed = 0;
    g_t_mapped_valid = 0;
    g_nz = 0;
    pthread_mutex_unlock(&g_target_lock);
}

void winios_windowed_teardown(void)
{
    if (!g_root) return;
    ww_clear_all();
    [g_dock removeFromSuperview];
    g_dock = nil;
    [g_pill removeFromSuperview];
    g_pill = nil;
    g_root = nil;
    ww_log("compositor root removed");
}

void winios_windowed_reset(void)
{
    atomic_store(&g_ww_state, -1);
    atomic_store(&g_fg_request, 0);
    atomic_store(&g_guest_fg, 0);
    pthread_mutex_lock(&g_ww_lock);
    g_nknown = 0;
    g_ncmds = 0;
    g_nexes = 0;
    pthread_mutex_unlock(&g_ww_lock);
    dispatch_async(dispatch_get_main_queue(), ^{ ww_clear_all(); });
}

void winios_windowed_relayout(void)
{
    if (!g_root) return;
    for (WWWin *w in g_wins.allValues) {
        if (!w->frame) continue;
        /* a new screen size refits a zoom the user did not set (rotation) */
        if (w->kind == WW_FRAMED && w->placed && !(ww_shown(w) && ww_refit(w, "screen changed"))) ww_clamp(w);
        ww_apply_frame(w);
    }
    ww_layout_dock();
    ww_z_rebuild();
}

/* ------------------------------------------------------------------ *
 * Input
 * ------------------------------------------------------------------ */

static CALayer *ww_host_of(WWWin *w)
{
    WWWin *g = w->kind == WW_ATTACHED ? ww_get(w->group, NO) : w;
    return g && g->frame ? g->frame.host : nil;
}

/* point in the root view -> desktop px of w (unclamped) */
static BOOL ww_root_to_desk(WWWin *w, CGPoint p, int *px, int *py)
{
    CALayer *host = ww_host_of(w);
    CALayer *l = w->layer;
    if (!host || !l || l.frame.size.width <= 0 || l.frame.size.height <= 0) return NO;
    CGPoint hp = [host convertPoint:p fromLayer:g_root.layer];
    CGRect lr = l.frame;
    *px = (int)floor(w->desk.origin.x + (hp.x - lr.origin.x) * w->desk.size.width / lr.size.width);
    *py = (int)floor(w->desk.origin.y + (hp.y - lr.origin.y) * w->desk.size.height / lr.size.height);
    return YES;
}

static void ww_note_mapped(uintptr_t target, int px, int py)
{
    pthread_mutex_lock(&g_target_lock);
    g_t_mapped = target;
    g_t_mx = px;
    g_t_my = py;
    g_t_mapped_valid = 1;
    pthread_mutex_unlock(&g_target_lock);
}

int winios_windowed_map_point(double wx, double wy, int *px, int *py)
{
    if (!g_root) return 0;
    CGPoint p = [g_root convertPoint:CGPointMake(wx, wy) fromView:nil];
    pthread_mutex_lock(&g_target_lock);
    unsigned pressed = g_t_pressed;
    uintptr_t latched = g_t_latched;
    int lastx = g_t_mx, lasty = g_t_my;
    pthread_mutex_unlock(&g_target_lock);
    int x = 0, y = 0;
    if (pressed && latched) {
        WWWin *w = ww_get(latched, NO);
        if (w && ww_root_to_desk(w, p, &x, &y)) {
            if (px) *px = x;
            if (py) *py = y;
            ww_note_mapped(latched, x, y);
            return 1;
        }
    }
    for (UIView *v in g_root.subviews.reverseObjectEnumerator) {
        if (![v isKindOfClass:[WWFrameView class]] || v.hidden) continue;
        WWFrameView *f = (WWFrameView *)v;
        CGPoint hp = [f.host convertPoint:p fromLayer:g_root.layer];
        for (CALayer *l in f.host.sublayers.reverseObjectEnumerator) {
            if (l.hidden || !CGRectContainsPoint(l.frame, hp)) continue;
            NSNumber *h = [l valueForKey:@"ww_hwnd"];
            WWWin *w = h ? ww_get(h.unsignedLongValue, NO) : nil;
            if (!w || !ww_root_to_desk(w, p, &x, &y)) continue;
            if (px) *px = x;
            if (py) *py = y;
            ww_note_mapped(w->hwnd, x, y);
            return 1;
        }
        /* the frame's own title bar is chrome, not the window; a touch there
         * never reaches the game view, but stop the search under it */
        if (CGRectContainsPoint(f.frame, p)) break;
    }
    /* the background: no window; the events that follow are dropped */
    if (px) *px = lastx;
    if (py) *py = lasty;
    ww_note_mapped(0, lastx, lasty);
    return 0;
}

int winios_windowed_cursor_point(double px, double py, CGPoint *pt, CGFloat *k)
{
    if (!g_root) return 0;
    pthread_mutex_lock(&g_target_lock);
    uintptr_t cand = g_t_pressed ? g_t_latched : g_t_last;
    /* a touch just mapped through a frame (Touch mode moves the arrow first) */
    if (!g_t_pressed && g_t_mapped_valid && g_t_mapped && (int)px == g_t_mx && (int)py == g_t_my) cand = g_t_mapped;
    pthread_mutex_unlock(&g_target_lock);
    WWWin *w = cand ? ww_get(cand, NO) : nil;
    CGPoint d = CGPointMake(px, py);
    if (w && !CGRectContainsPoint(CGRectInset(w->desk, -1, -1), d)) {
        pthread_mutex_lock(&g_target_lock);
        BOOL pressed = g_t_pressed != 0;
        pthread_mutex_unlock(&g_target_lock);
        if (!pressed) w = nil;
    }
    if (!w) {
        pthread_mutex_lock(&g_target_lock);
        for (int i = 0; i < g_nz; i++) if (CGRectContainsPoint(g_z[i].desk, d)) { cand = g_z[i].hwnd; break; }
        pthread_mutex_unlock(&g_target_lock);
        w = cand ? ww_get(cand, NO) : nil;
    }
    CALayer *host = w ? ww_host_of(w) : nil;
    if (!w || !host || !w->layer || w->desk.size.width <= 0 || w->layer.frame.size.width <= 0) return 0;
    CGRect lr = w->layer.frame;
    CGFloat sx = lr.size.width / w->desk.size.width, sy = lr.size.height / w->desk.size.height;
    CGPoint lp = CGPointMake(lr.origin.x + (px - w->desk.origin.x) * sx, lr.origin.y + (py - w->desk.origin.y) * sy);
    CGPoint a = [g_root.layer convertPoint:lp fromLayer:host];
    CGPoint b = [g_root.layer convertPoint:CGPointMake(lp.x + sx, lp.y) fromLayer:host];
    if (pt) *pt = a;
    if (k) *k = b.x - a.x;
    return 1;
}

void *winios_windowed_event_target(int x, int y, unsigned int flags, int *drop)
{
    *drop = 0;
    uintptr_t target;
    int background = 0;
    pthread_mutex_lock(&g_target_lock);
    if (g_t_pressed && g_t_latched) {
        target = g_t_latched;
    } else if (g_t_mapped_valid && x == g_t_mx && y == g_t_my) {
        target = g_t_mapped;                          /* a touch mapped through a frame */
        background = !target;
    } else if (flags & WW_MOUSE_ABSOLUTE) {
        target = 0;                                   /* trackpad / hardware mouse position */
        for (int i = 0; i < g_nz; i++)
            if (CGRectContainsPoint(g_z[i].desk, CGPointMake(x, y))) { target = g_z[i].hwnd; break; }
        if (!target && g_t_last) target = g_t_last;   /* off every window: stay with the last one */
        background = !target;
    } else {
        target = g_t_last;                            /* relative motion, buttons, wheel */
    }
    if (background) {
        /* never strand a button: an up with nothing pressed is harmless to drop */
        *drop = 1;
        pthread_mutex_unlock(&g_target_lock);
        return NULL;
    }
    BOOL down = (flags & WW_MOUSE_DOWNS) && target;
    if (down) { g_t_pressed |= (flags & WW_MOUSE_DOWNS); g_t_latched = target; }
    if (flags & WW_MOUSE_UPS) {
        g_t_pressed &= ~((flags & WW_MOUSE_UPS) >> 1);
        if (!g_t_pressed) g_t_latched = 0;
    }
    if (target) g_t_last = target;
    pthread_mutex_unlock(&g_target_lock);
    if (down) {
        uintptr_t t = target;
        dispatch_async(dispatch_get_main_queue(), ^{
            WWWin *w = ww_get(t, NO);
            if (w) ww_raise(w, NO, "click");   /* the click itself activates it in the guest */
        });
    }
    return (void *)target;
}
