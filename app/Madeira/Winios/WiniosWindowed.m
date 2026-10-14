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
 * steamTapped) handles it: ml1350 starts Steam (or Valve's installer) inside
 * this session (MadeiraSession, docs/SESSION_LAUNCH.md); when that cannot
 * run it prepares a library entry for the next start and says so.
 * env.MADEIRA_WINDOWED_STEAM = 0 hides it. Round 5: once Steam is installed
 * in the prefix the tile shows the installed steam.exe's own icon, read at
 * run time from its PE resources (ww_pe_icon: the first RT_GROUP_ICON, its
 * 32-bit 64x64 or 48x48 RT_ICON); no Valve artwork is in the repository.
 * Round 7: the tile is there only while a Steam window is open, as that
 * window's program button among the others (its dot, its tap), with the
 * client's icon in the same 36-point box as every program icon; Steam starts
 * from the search's Steam row or the library. env.MADEIRA_WINDOWED_STEAM = 1
 * pins the round 4 tile again (now drawn at the same size).
 *
 * Search (round 5). The taskbar's search field is a launcher: while it is
 * being edited a results panel (WWLauncher, the chrome's material) sits above
 * the taskbar and lists, filtered as you type, the open windows, three tools
 * (Explorer, Command Prompt, Steam), the library's games and the programs in
 * the prefix (Start Menu / Desktop shortcuts, Program Files), the last four
 * from WindowedMode.swift (MadeiraWindowedBridge launcherItems:). A window is
 * raised; anything else starts inside the running session (launcherPick:,
 * MadeiraSession). Go picks the first result; a touch on a window or the
 * background closes it. While the field has the software keyboard, the
 * taskbar and the panel ride above it (keyboard frame notifications).
 * Round 7: when the keyboard leaves too little room for two rows (an iPhone
 * in landscape), the results become one sideways-scrolling strip of chips
 * (icon and name): directly above the keyboard with the taskbar above it, or,
 * with less room still, inside the taskbar itself right of the field (the
 * program buttons step aside while searching). The first chip is the one the
 * keyboard's Search key picks. env.MADEIRA_WINDOWED_CHIPS = 0 keeps the list.
 *
 * Maximize (round 3; round 7): the restore pill can be dragged anywhere in
 * the safe area (kept for the session), and the library's round menu button
 * hides meanwhile (WindowedMode.swift WindowedHUD): the pill has the menu.
 *
 * Resize (round 8). The bottom-right grip resizes the guest window, width and
 * height independently, as a desktop window manager does: the drag shows an
 * outline of the new size and asks for the client size it means (the visible
 * rect minus the window's non-client frame) at most ten times a second and
 * once more when the finger lifts, coalesced to the latest size per window.
 * The window's own thread applies it from its event pump (driver_ios.c
 * winios_drv_resize_client_if_owner: SetWindowPos with SWP_NOMOVE |
 * SWP_NOZORDER | SWP_NOACTIVATE, WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE around
 * the drag), and the frame follows the new size through the usual size-change
 * path with its zoom (points per pixel) unchanged. A pinch on the title bar
 * zooms the picture instead (the round 2 grip); env.MADEIRA_WINDOWED_RESIZE = 0
 * makes the grip zoom again. Fullscreen (fit) and maximized frames, and a
 * window the program maximized, are not resized (the grip zooms the last).
 * The grip shows only on the active frame, and only for about two seconds
 * after a touch on that frame (then it fades; it takes no touches while
 * faded). The title bar is 30 points with 22-point buttons (32-point touch
 * targets).
 *
 * Round 9. The grip keeps the client area's aspect ratio from the start of
 * the drag (a game that keeps its swapchain size is never shown stretched);
 * holding the grip still for a moment before dragging, or two fingers, frees
 * it for that drag, and env.MADEIRA_WINDOWED_RESIZE_FREE = 1 makes free the
 * default. Every frame's picture is scaled uniformly (one zoom for both
 * axes, ww_apply_frame); fit and maximize letterbox it. The title bar has
 * minimize, maximize (the full-screen arrows) and close; the fit button is
 * back only with env.MADEIRA_WINDOWED_FIT_BUTTON = 1. The taskbar and the
 * restore pill are about a fifth smaller (30-point items), and the library's
 * round menu button is hidden for the whole windowed session.
 *
 * Log lines: "[windowed] ml1300 ..." for on/off, add, refit, remove, activate,
 * move, scale, resize, minimize, restore, fullscreen, close, steam, search and
 * the ignored presses; the driver's "[winios] ml1302 resize ..." says whether
 * a resize was applied or refused. */

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
/* round 8 (ml1302): -2 = a libwin32u_unix.a without the resize helper */
__attribute__((weak)) int winios_drv_resize_client_if_owner(void *hwnd, int cw, int ch, unsigned int flags)
{ (void)hwnd; (void)cw; (void)ch; (void)flags; return -2; }
extern int winios_drv_process_image(unsigned int pid, char *out, unsigned int size);
extern int winios_drv_census_owner(void *hwnd, unsigned int *pid, unsigned int *style);
extern int winios_drv_foreground_if_owner(void *hwnd);
/* ml1332: a window of a Wine client in the process-host extension has no thread in
 * this task; any Wine thread asks the server to make it foreground (driver_ios.c). */
__attribute__((weak)) int winios_drv_foreground_remote(void *hwnd) { (void)hwnd; return 0; }
extern int madeira_process_host_is_remote_window(void *hwnd);   /* ProcessHostClient.m */

#define WW_WS_VISIBLE      0x10000000u
#define WW_WS_MINIMIZE     0x20000000u
#define WW_WS_MAXIMIZE     0x01000000u
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

static const CGFloat WW_BAR_H = 30;       /* title bar height, points (round 8: was 36) */
static const CGFloat WW_BTN = 22;         /* title-bar button circles, points (round 8: was 28) */
static const CGFloat WW_BTN_HIT = 32;     /* round 8: their touch targets, centred on each circle */
static const CGFloat WW_BTN_GAP = 10;     /* between two circles: the touch targets just meet */
static const CGFloat WW_BTN_GLYPH = 24;   /* the glyph as drawn for a 24-point circle (10-point symbols) */
static const CGFloat WW_MIN_BAR_W = 168;  /* a tiny window still gets a usable title bar (round 9: three buttons; was 200 with four) */
static const CGFloat WW_MIN_BAR_W_FIT = 200;   /* round 9: the same with the fit button back (env.MADEIRA_WINDOWED_FIT_BUTTON = 1) */
static const CGFloat WW_GRIP = 26;        /* the resize grip, points */
static const double WW_GRIP_SHOW_S = 2.0; /* round 8: the grip shows this long after a touch on its frame */
static const double WW_RESIZE_EVERY_S = 0.1;   /* round 8: a drag asks for a new size at most this often */
static const CGFloat WW_DOCK_H = 46;      /* round 9: was 56 */
static const CGFloat WW_DOCK_ITEM = 30;   /* taskbar icons, round buttons and the search field's height (round 9: was 36) */
static const CGFloat WW_DOCK_PAD = 8;     /* taskbar: pill edge to the first and last item (round 9: was 10) */
static const CGFloat WW_DOCK_GAP = 8;     /* taskbar: between any two items (round 9: was 10) */
static const CGFloat WW_DOCK_ICON_R = 7.5;    /* round 9: a program icon's corners (was 9) */
static const CGFloat WW_DOCK_DOT_Y = 39.5;    /* round 9: the running dot's top, WW_DOCK_H - 6.5 (was 56 - 7.5) */
static const CGFloat WW_SEARCH_W = 96;    /* round 9: was 112 */
/* round 9: the restore pill, a fifth smaller (was two 36-point buttons, 10 apart, in a 92 x 46 pill) */
static const CGFloat WW_PILL_BTN = 30, WW_PILL_PAD = 5, WW_PILL_GAP = 8;
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

/* Round 8: grip resizes waiting for their window's thread, the latest size per
 * window (flags: 1 the drag began, 2 it ended; see driver_ios.c). `busy`: its
 * thread is applying it (a pump re-entered from the window procedure skips it). */
#define WW_RESIZES_MAX 16
static struct { uintptr_t hwnd; int cw, ch; unsigned flags, gen; long long ns, wake_ns; int busy; } g_resizes[WW_RESIZES_MAX];
static int g_nresizes;

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

/* Round 8: a new client size for the window's thread; replaces one still
 * waiting for the same window (its flags add up). */
static void ww_enqueue_resize(uintptr_t hwnd, int cw, int ch, unsigned flags)
{
    pthread_mutex_lock(&g_ww_lock);
    int i;
    for (i = 0; i < g_nresizes; i++) if (g_resizes[i].hwnd == hwnd) break;
    if (i == g_nresizes && g_nresizes < WW_RESIZES_MAX) {
        memset(&g_resizes[i], 0, sizeof(g_resizes[i]));
        g_resizes[i].hwnd = hwnd;
        g_resizes[i].ns = ww_now_ns();
        g_nresizes++;
    }
    if (i < g_nresizes) {
        g_resizes[i].cw = cw;
        g_resizes[i].ch = ch;
        g_resizes[i].flags |= flags;
        g_resizes[i].gen++;
    }
    pthread_mutex_unlock(&g_ww_lock);
}

/* Wine thread, from the pump: applies the waiting resizes of windows this
 * thread owns; one whose thread has not pumped for 3 s is dropped. */
static void ww_pump_resizes(void)
{
    struct { uintptr_t hwnd; int cw, ch; unsigned flags, gen; } todo[WW_RESIZES_MAX];
    int n = 0;
    long long now = ww_now_ns();
    pthread_mutex_lock(&g_ww_lock);
    for (int i = 0; i < g_nresizes; ) {
        if (g_resizes[i].busy) { i++; continue; }
        if (now - g_resizes[i].ns > 3000000000LL) {
            ww_log("resize hwnd=%p to %dx%d (client px) dropped: its thread did not pump within 3 s",
                   (void *)g_resizes[i].hwnd, g_resizes[i].cw, g_resizes[i].ch);
            g_resizes[i] = g_resizes[--g_nresizes];
            continue;
        }
        todo[n].hwnd = g_resizes[i].hwnd; todo[n].cw = g_resizes[i].cw; todo[n].ch = g_resizes[i].ch;
        todo[n].flags = g_resizes[i].flags; todo[n].gen = g_resizes[i].gen;
        n++;
        i++;
    }
    pthread_mutex_unlock(&g_ww_lock);
    for (int k = 0; k < n; k++) {
        /* claim it, so a pump re-entered from the window procedure leaves it alone */
        pthread_mutex_lock(&g_ww_lock);
        int i, claimed = 0, wake = 0;
        for (i = 0; i < g_nresizes; i++) if (g_resizes[i].hwnd == todo[k].hwnd) break;
        if (i < g_nresizes && !g_resizes[i].busy) {
            todo[k].cw = g_resizes[i].cw; todo[k].ch = g_resizes[i].ch;
            todo[k].flags = g_resizes[i].flags; todo[k].gen = g_resizes[i].gen;
            g_resizes[i].busy = 1;
            claimed = 1;
            /* another thread wakes the window's thread with a posted WM_NULL, at most every 100 ms */
            if (now - g_resizes[i].wake_ns >= 100000000LL) { g_resizes[i].wake_ns = now; wake = 1; }
        }
        pthread_mutex_unlock(&g_ww_lock);
        if (!claimed) continue;
        int r = winios_drv_resize_client_if_owner((void *)todo[k].hwnd, todo[k].cw, todo[k].ch,
                                                  todo[k].flags | (wake ? 0x100u : 0));
        pthread_mutex_lock(&g_ww_lock);
        for (i = 0; i < g_nresizes; i++) if (g_resizes[i].hwnd == todo[k].hwnd) break;
        if (i < g_nresizes) {
            g_resizes[i].busy = 0;
            if (r != 0) {
                if (g_resizes[i].gen == todo[k].gen) g_resizes[i] = g_resizes[--g_nresizes];
                else {   /* a newer size came meanwhile: it waits, the drag's start is done */
                    g_resizes[i].flags &= ~(todo[k].flags & 1u);
                    g_resizes[i].ns = ww_now_ns();
                }
            }
        }
        pthread_mutex_unlock(&g_ww_lock);
        if (r == -2) {
            static int logged;
            if (!logged && (logged = 1))
                ww_log("resize hwnd=%p not applied: this libwin32u_unix.a has no ml1302 resize helper", (void *)todo[k].hwnd);
        }
    }
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

    /* round 8: grip resizes, on the window's own thread */
    ww_pump_resizes();

    long long now = ww_now_ns();
    /* a tapped window becomes foreground on its own thread */
    uintptr_t fg = atomic_load_explicit(&g_fg_request, memory_order_relaxed);
    if (fg) {
        if (now - atomic_load(&g_fg_request_ns) > 3000000000LL) {
            atomic_compare_exchange_strong(&g_fg_request, &fg, 0);   /* its thread never pumped */
        } else {
            int r = winios_drv_foreground_if_owner((void *)fg);
            /* ml1332: the owner-thread rule never runs for an extension client's
             * window (its threads are in another task). The server routes the
             * activation to that thread; nothing is asked of the extension. */
            if (!r && madeira_process_host_is_remote_window((void *)fg)) {
                r = winios_drv_foreground_remote((void *)fg);
                static _Atomic int said;
                if (r && !atomic_exchange(&said, 1))
                    ww_log("ml1332 activate remote hwnd=%p foreground=%d (server-routed; no extension call)", (void *)fg, r);
            }
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
    CGSize client;         /* round 8: client size, desktop px (0 x 0 until known) */
    BOOL resizing;         /* round 8: the grip is resizing the guest window */
    CGSize resizeWant;     /* round 8: the visible size the drag asks for, desktop px */
    CFTimeInterval resizeSentAt, resizeKeepK;   /* last request; until then a size change keeps the zoom */
    CGSize resizeClientWant;   /* round 9: the client size an aspect-locked drag asks for (0 x 0: from the visible size) */
    int resizeAspectW, resizeAspectH;   /* round 9: the reduced client aspect the drag keeps (0: a free drag) */
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
 * clear button, while editing, takes its own room). Round 9 (a smaller
 * taskbar): 9, 13-point glass, 6 and 8. */
static const CGFloat WW_GLASS_X = 9, WW_GLASS_SIDE = 13, WW_GLASS_GAP = 6, WW_SEARCH_RIGHT = 8;
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

/* Round 8: the grip resizes the guest window (default) or, with
 * env.MADEIRA_WINDOWED_RESIZE = 0, zooms the picture as in rounds 2-7. Read
 * once per session (winios_windowed_reset forgets it). */
static int g_resize_mode = -1;
static BOOL ww_grip_resizes(void)
{
    if (g_resize_mode < 0) {
        char cfg[16];
        const char *v = madeira_cfg_get("env.MADEIRA_WINDOWED_RESIZE", cfg, sizeof(cfg)) ? cfg : getenv("MADEIRA_WINDOWED_RESIZE");   /* 0: the windowed frame's bottom-right grip zooms the picture (the guest window keeps its size), as before round 8; default: it resizes the guest window, width and height independently */
        g_resize_mode = (v && v[0] == '0' && !v[1]) ? 0 : 1;
    }
    return g_resize_mode != 0;
}

/* Round 9: a grip drag keeps the client area's aspect ratio from the start of
 * the drag (default), so a program that keeps its swapchain (render) size is
 * never shown stretched; env.MADEIRA_WINDOWED_RESIZE_FREE = 1 makes round 8's
 * free resize the default. Holding the grip still for a moment before
 * dragging, or two fingers on it, gives the other mode for that drag. Read
 * once per session. */
static int g_resize_free = -1;
static BOOL ww_resize_free_default(void)
{
    if (g_resize_free < 0) {
        char cfg[16];
        const char *v = madeira_cfg_get("env.MADEIRA_WINDOWED_RESIZE_FREE", cfg, sizeof(cfg)) ? cfg : getenv("MADEIRA_WINDOWED_RESIZE_FREE");   /* 1: the windowed frame's grip resizes width and height on their own by default (round 8); default (round 9): it keeps the window's aspect ratio. Holding the grip a moment before dragging, or two fingers, gives the other mode for that drag */
        g_resize_free = (v && v[0] == '1' && !v[1]) ? 1 : 0;
    }
    return g_resize_free != 0;
}

/* Round 9: no fit (diagonal arrows) button on the title bar: maximize, now
 * drawn with the full-screen arrows, does that job; holding it or a double
 * tap on the title bar maximizes too. env.MADEIRA_WINDOWED_FIT_BUTTON = 1
 * brings back round 8's four buttons (maximize "+", hold fit to maximize, a
 * double tap fits). Read once per session. */
static int g_fit_button = -1;
static BOOL ww_fit_button(void)
{
    if (g_fit_button < 0) {
        char cfg[16];
        const char *v = madeira_cfg_get("env.MADEIRA_WINDOWED_FIT_BUTTON", cfg, sizeof(cfg)) ? cfg : getenv("MADEIRA_WINDOWED_FIT_BUTTON");   /* 1: the windowed title bar keeps round 8's fit-to-screen button (diagonal arrows) beside maximize; default (round 9): minimize, maximize (drawn with the full-screen arrows) and close */
        g_fit_button = (v && v[0] == '1' && !v[1]) ? 1 : 0;
    }
    return g_fit_button != 0;
}

/* The narrowest title bar for the buttons it has. */
static CGFloat ww_min_bar_w(void) { return ww_fit_button() ? WW_MIN_BAR_W_FIT : WW_MIN_BAR_W; }

/* Round 9: "16:9" for 1280 x 720 (the client size a drag began with). */
static void ww_reduce_aspect(CGSize c, int *aw, int *ah)
{
    long a = lround(c.width), b = lround(c.height), x = a, y = b;
    *aw = *ah = 0;
    if (a <= 0 || b <= 0) return;
    while (y) { long r = x % y; x = y; y = r; }
    *aw = (int)(a / x);
    *ah = (int)(b / x);
}

/* Round 8: asks the window's thread for the client size that gives the
 * visible size `want` (desktop px): the visible rect minus the client rect is
 * the window's non-client frame (caption, borders, menu bar) as last reported.
 * flags: 1 the drag began, 2 it ended. A repeat of the last size mid-drag is
 * not sent again. */
static void ww_send_resize(WWWin *w, CGSize want, unsigned flags)
{
    int cw, ch;
    if (w->resizeClientWant.width > 0 && w->resizeClientWant.height > 0) {
        /* round 9: an aspect-locked drag names the client size itself (exactly W:H) */
        cw = (int)MAX(lround(w->resizeClientWant.width), 1);
        ch = (int)MAX(lround(w->resizeClientWant.height), 1);
    } else {
        CGFloat ncw = 0, nch = 0;
        if (w->client.width > 0 && w->client.height > 0) {
            ncw = MAX(w->desk.size.width - w->client.width, 0);
            nch = MAX(w->desk.size.height - w->client.height, 0);
        }
        cw = (int)MAX(lround(want.width - ncw), 1);
        ch = (int)MAX(lround(want.height - nch), 1);
    }
    static uintptr_t last_hwnd;
    static int last_cw, last_ch;
    if (!flags && last_hwnd == w->hwnd && last_cw == cw && last_ch == ch) return;
    last_hwnd = w->hwnd; last_cw = cw; last_ch = ch;
    ww_enqueue_resize(w->hwnd, cw, ch, flags);
    CFTimeInterval now = CACurrentMediaTime();
    w->resizeSentAt = now;
    w->resizeKeepK = now + 3.0;   /* the size changes this brings keep the zoom */
    char mode[48];
    if (w->resizeAspectW > 0 && w->resizeAspectH > 0)
        snprintf(mode, sizeof(mode), " (aspect locked %d:%d)", w->resizeAspectW, w->resizeAspectH);
    else
        snprintf(mode, sizeof(mode), " (free)");
    ww_log("resize hwnd=%p to %dx%d (client px; window %.0fx%.0f, zoom %.2f pt/px kept)%s%s", (void *)w->hwnd, cw, ch,
           want.width, want.height, w->k, (flags & 1) && (flags & 2) ? " (drag began and ended)"
           : (flags & 1) ? " (drag began)" : (flags & 2) ? " (drag ended)" : "", mode);
}

@interface WWFrameView : UIView <UIGestureRecognizerDelegate>
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
/* round 8 */
@property (nonatomic) BOOL gripAllowed;           /* not fullscreen (fit) or maximized */
@property (nonatomic) BOOL gripDragging;
@property (nonatomic) BOOL gripZooming;           /* this drag zooms (env.MADEIRA_WINDOWED_RESIZE = 0, or the program maximized it) */
@property (nonatomic) CFTimeInterval touchedAt;   /* the last touch on this frame */
@property (nonatomic) BOOL gripCheckPending;
@property (nonatomic) BOOL resizeTrailPending;
@property (nonatomic) CGSize resizeStart;         /* visible size when the drag began, desktop px */
@property (nonatomic, strong) UIView *ghost;      /* the outline of the size a drag asks for */
/* round 9 */
@property (nonatomic) BOOL gripFree;              /* this drag resizes width and height on their own */
@property (nonatomic) CGSize resizeClient0;       /* the client size when the drag began, desktop px */
@property (nonatomic) CGSize resizeNC;            /* the window's non-client frame then (visible minus client) */
@property (nonatomic, strong) UIPanGestureRecognizer *gripPan;
@property (nonatomic, strong) UILongPressGestureRecognizer *gripHold;   /* held still first: the other mode */
@property (nonatomic, strong) CAShapeLayer *gripLines;
- (void)touched;
- (void)scheduleGripCheck;
- (void)updateGrip;
- (void)ghostDone;
@end

@interface WWDock : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UIVisualEffectView *pill;
@property (nonatomic, strong) WWSearchField *search;
@property (nonatomic, strong) WWAppStrip *apps;
@property (nonatomic, strong) UIButton *keyboardButton, *menuButton;
@property (nonatomic, strong) UIButton *steamButton;   /* pinned, left of the program buttons (env.MADEIRA_WINDOWED_STEAM = 1) */
@property (nonatomic, strong) UIImageView *steamIcon;  /* round 5: the installed steam.exe's icon */
@property (nonatomic, strong) UIView *steamDot;
@property (nonatomic) BOOL steamAllowed;               /* Steam on the taskbar at all (env.MADEIRA_WINDOWED_STEAM != 0, a Swift bridge) */
@property (nonatomic) BOOL steamPinned;                /* round 7: the round 4 pinned tile; else only while a Steam window is open */
@property (nonatomic, strong) NSMutableArray<UIButton *> *appButtons;
@end

static WWDock *g_dock;

/* Round 5: the search launcher (results panel) and the Steam tile's icon. */
@class WWLauncher;
static WWLauncher *g_launch;
static CGFloat g_kb_lift;                 /* points the software keyboard covers while the search field has it */
static const char *g_launch_close_why;    /* why the search field is being released (log) */
static void ww_launch_open(void);
static void ww_launch_closed(void);
static void ww_launch_filter(void);
static BOOL ww_launch_pick(NSUInteger index);
static void ww_launch_layout(void);
static void ww_steam_activate(const char *why);
static void ww_steam_icon_check(BOOL force);
/* Round 7: how the open results panel is laid out (ww_launch_mode). */
enum { WW_LAUNCH_LIST = 0, WW_LAUNCH_CHIPS_ABOVE_KB = 1, WW_LAUNCH_CHIPS_IN_DOCK = 2 };
static int ww_launch_mode(void);
static uintptr_t g_steam_tile;            /* round 7: the Steam window whose program button is the Steam tile, 0 none */

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
static BOOL g_pill_moved;                 /* round 7: dragged this session; its centre as fractions of the root */
static CGPoint g_pill_at;
static void ww_layout_pill(void);
static uintptr_t g_max;   /* the maximized window, 0 when none */
static void ww_set_maximized(WWWin *w, BOOL on, const char *why);

/* A frame was touched or activated: the search field (if a touch opened it)
 * gives the keyboard back to the program. */
static void ww_search_release(const char *why)
{
    if (!g_dock || !g_dock.search.isFirstResponder) return;
    g_launch_close_why = why;   /* round 5: the results panel closes with it */
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

/* Round 5: a bridge class method that returns a string (nil bridge: nil)... */
static NSString *ww_bridge_string(NSString *sel)
{
    Class c = ww_bridge();
    SEL s = NSSelectorFromString(sel);
    if (!c || ![c respondsToSelector:s]) return nil;
    NSString *(*fn)(id, SEL) = (NSString *(*)(id, SEL))[c methodForSelector:s];
    id value = fn(c, s);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

/* ... and one that takes an object. */
static void ww_bridge_call_with(NSString *sel, id arg)
{
    Class c = ww_bridge();
    SEL s = NSSelectorFromString(sel);
    if (c && [c respondsToSelector:s]) {
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))[c methodForSelector:s];
        fn(c, s, arg);
    }
}

/* Round 7: ... and one that takes a BOOL. */
static void ww_bridge_call_bool(NSString *sel, BOOL arg)
{
    Class c = ww_bridge();
    SEL s = NSSelectorFromString(sel);
    if (c && [c respondsToSelector:s]) {
        void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[c methodForSelector:s];
        fn(c, s, arg);
    }
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
    _label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];   /* round 8: was 13 */
    _label.textAlignment = NSTextAlignmentCenter;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [_bar.contentView addSubview:_label];
    /* maximize: the whole screen, no title bar. Round 9: drawn with the
     * full-screen arrows, and the fit button is gone (it did the same job);
     * env.MADEIRA_WINDOWED_FIT_BUTTON = 1 keeps round 8's fit button and "+" */
    BOOL fit = ww_fit_button();
    NSString *maxGlyph = fit ? @"plus" : @"arrow.up.left.and.arrow.down.right";
    _minButton = ww_round_button(@"minus", WW_BTN);
    _fullButton = ww_round_button(@"arrow.up.left.and.arrow.down.right", WW_BTN);
    _maxButton = ww_round_button(maxGlyph, WW_BTN);
    _closeButton = ww_round_button(@"xmark", WW_BTN);
    /* round 8: 22-point circles keep a 10-point glyph */
    [_minButton setImage:ww_glyph(@"minus", WW_BTN_GLYPH) forState:UIControlStateNormal];
    [_maxButton setImage:ww_glyph(maxGlyph, WW_BTN_GLYPH) forState:UIControlStateNormal];
    [_closeButton setImage:ww_glyph(@"xmark", WW_BTN_GLYPH) forState:UIControlStateNormal];
    _fullButton.hidden = !fit;
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
    /* holding the fit button maximizes too (round 9: holding maximize, the
     * button that is there) */
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(fullHeld:)];
    hold.allowedPressTypes = @[];
    [(fit ? _fullButton : _maxButton) addGestureRecognizer:hold];

    /* The title bar drags the frame. Its recognizers take touches only (no
     * presses), so a controller or keyboard focus press never reaches them. */
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    drag.maximumNumberOfTouches = 1;
    [_bar addGestureRecognizer:drag];
    UITapGestureRecognizer *twice = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(barDoubleTapped)];
    twice.numberOfTapsRequired = 2;
    twice.allowedPressTypes = @[];
    [_bar addGestureRecognizer:twice];
    UITapGestureRecognizer *once = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(barTapped)];
    once.allowedPressTypes = @[];
    [once requireGestureRecognizerToFail:twice];
    [_bar addGestureRecognizer:once];
    /* round 8: a pinch on the title bar zooms the picture (what the grip did
     * before; the guest window keeps its size) */
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(barPinched:)];
    pinch.allowedPressTypes = @[];
    [_bar addGestureRecognizer:pinch];

    /* round 8: the outline of the size a grip drag asks for, while the guest
     * window catches up (it is resized at most ten times a second) */
    _ghost = [[UIView alloc] initWithFrame:CGRectZero];
    _ghost.userInteractionEnabled = NO;
    _ghost.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    _ghost.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    _ghost.layer.borderWidth = 1.5;
    _ghost.layer.cornerRadius = 10;
    _ghost.layer.cornerCurve = kCACornerCurveContinuous;
    _ghost.hidden = YES;
    [self addSubview:_ghost];

    /* bottom-right grip: drag to resize the guest window (round 8; with
     * env.MADEIRA_WINDOWED_RESIZE = 0 it zooms the picture, the guest window
     * keeping its size). Shown on the active frame for a moment after a touch. */
    _gripAllowed = YES;
    _grip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WW_GRIP, WW_GRIP)];
    _grip.alpha = 0;
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
    _gripLines = lines;
    UIPanGestureRecognizer *gripPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(gripDragged:)];
    gripPan.maximumNumberOfTouches = 2;   /* round 9: two fingers give the other resize mode */
    gripPan.allowedPressTypes = @[];
    gripPan.delegate = self;
    [_grip addGestureRecognizer:gripPan];
    _gripPan = gripPan;
    /* round 9: the grip held still for a moment, then dragged: the other mode
     * (free when the default keeps the aspect ratio); recognized beside the pan */
    UILongPressGestureRecognizer *gripHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(gripHeld:)];
    gripHold.minimumPressDuration = 0.35;
    gripHold.allowableMovement = 12;
    gripHold.allowedPressTypes = @[];
    gripHold.cancelsTouchesInView = NO;
    gripHold.delegate = self;
    [_grip addGestureRecognizer:gripHold];
    _gripHold = gripHold;
    [self addSubview:_grip];
    return self;
}

/* Round 9: the grip's pan and its hold run side by side (the hold only marks
 * the drag that follows). */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return (a == _gripPan && b == _gripHold) || (a == _gripHold && b == _gripPan);
}

/* Round 9: the grip, held still, says the drag that follows is the other
 * mode: a light tap of the haptics and bolder lines until the finger lifts. */
- (void)gripHeld:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        if (!_gripDragging) _gripLines.lineWidth = 2;
        return;
    }
    if (g.state != UIGestureRecognizerStateBegan || _gripDragging) return;
    WWWin *w = [self win];
    if (!w || w->fullscreen || w->maximized || !ww_grip_resizes()) return;
    [self touched];
    _gripLines.lineWidth = 3;
    UIImpactFeedbackGenerator *tick = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tick impactOccurred];
    ww_log("grip held on hwnd=%p: the drag that follows %s", (void *)w->hwnd,
           ww_resize_free_default() ? "keeps the aspect ratio" : "resizes width and height freely");
}

/* Round 9: a double tap on the title bar maximizes (with the fit button back,
 * env.MADEIRA_WINDOWED_FIT_BUTTON = 1, it fits as in round 8). */
- (void)barDoubleTapped {
    if (ww_fit_button()) { [self fullscreenTapped]; return; }
    WWWin *w = [self win];
    if (w) ww_set_maximized(w, YES, "title bar double tap");
}

/* The title-bar buttons there are, right to left. */
- (NSArray<UIButton *> *)barButtons {
    return _fullButton.hidden ? @[_closeButton, _maxButton, _minButton] : @[_closeButton, _maxButton, _fullButton, _minButton];
}

/* Round 8: a touch on this frame (title bar, grip or the window in it) shows
 * the grip while the frame is the active one, for WW_GRIP_SHOW_S seconds. */
- (void)touched {
    if (_chromeless) return;
    _touchedAt = CACurrentMediaTime();
    [self updateGrip];
    [self scheduleGripCheck];
}

/* One pending check at a time (touches arrive at the touch rate): when it
 * runs, a newer touch schedules the next one. */
- (void)scheduleGripCheck {
    if (_gripCheckPending) return;
    _gripCheckPending = YES;
    double wait = MAX(WW_GRIP_SHOW_S - (CACurrentMediaTime() - _touchedAt), 0) + 0.05;
    __weak WWFrameView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WWFrameView *s = weakSelf;
        if (!s) return;
        s.gripCheckPending = NO;
        if (CACurrentMediaTime() - s.touchedAt < WW_GRIP_SHOW_S) [s scheduleGripCheck];
        [s updateGrip];
    });
}

- (void)updateGrip {
    if (_chromeless || !_grip) return;
    BOOL recent = CACurrentMediaTime() - _touchedAt < WW_GRIP_SHOW_S;
    BOOL show = _gripAllowed && (_gripDragging || (_active && recent));
    _grip.hidden = !_gripAllowed;
    CGFloat alpha = show ? 1 : 0;
    if (fabs(_grip.alpha - alpha) < 0.01) return;
    /* hidden (alpha 0) the grip takes no touches: the corner is the program's */
    [UIView animateWithDuration:show ? 0.15 : 0.5 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.grip.alpha = alpha; } completion:nil];
}

/* The guest window reached the size the drag asked for (or gave up). */
- (void)ghostDone {
    if (_gripDragging) return;
    _ghost.hidden = YES;
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
    if (w && g.state == UIGestureRecognizerStateBegan) ww_set_maximized(w, YES, _fullButton.hidden ? "maximize button held" : "fit button held");
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

/* Round 8: the grip resizes the guest window (width and height on their own),
 * or zooms the picture with env.MADEIRA_WINDOWED_RESIZE = 0 and for a window
 * the program maximized (the guest would refuse the size). */
- (void)gripDragged:(UIPanGestureRecognizer *)g {
    WWWin *w = [self win];
    BOOL end = g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed;
    if (!w || w->fullscreen || w->maximized || w->desk.size.width <= 0 || w->desk.size.height <= 0) {
        if (end && _gripDragging) {   /* became fullscreen / maximized / gone mid-drag */
            _gripDragging = NO;
            if (w && w->resizing) { w->resizing = NO; ww_send_resize(w, w->resizeWant, 2); }
            _ghost.hidden = YES;
            _gripLines.lineWidth = 2;
            [self updateGrip];
        }
        return;
    }
    if (g.state == UIGestureRecognizerStateBegan) {
        BOOL guestMax = w->infoKnown && (w->info.style & WW_WS_MAXIMIZE);
        _gripZooming = !ww_grip_resizes() || guestMax || ww_iconic(w);
        _gripDragging = YES;
        if (_gripZooming && guestMax && ww_grip_resizes())
            ww_log("resize hwnd=%p: the program maximized this window, so the grip zooms the picture instead", (void *)w->hwnd);
        if (!_gripZooming) {
            _resizeStart = w->desk.size;
            w->resizing = YES;
            w->resizeWant = w->desk.size;
            w->resizeSentAt = 0;
            /* round 9: keep the client aspect (default), or free: held first,
             * two fingers, or env.MADEIRA_WINDOWED_RESIZE_FREE = 1 (then held
             * or two fingers keep the aspect) */
            BOOL held = _gripHold.state == UIGestureRecognizerStateBegan || _gripHold.state == UIGestureRecognizerStateChanged;
            BOOL two = g.numberOfTouches >= 2;
            _gripFree = ww_resize_free_default() != (held || two);
            CGSize d = w->desk.size, c = w->client;
            if (!(c.width > 0 && c.height > 0 && c.width <= d.width && c.height <= d.height)) c = d;   /* client not known yet */
            _resizeClient0 = c;
            _resizeNC = CGSizeMake(d.width - c.width, d.height - c.height);
            w->resizeClientWant = CGSizeZero;
            w->resizeAspectW = w->resizeAspectH = 0;
            if (!_gripFree) ww_reduce_aspect(c, &w->resizeAspectW, &w->resizeAspectH);
            const char *how = held && two ? "grip held, two fingers" : held ? "grip held" : two ? "two fingers" : "default";
            if (_gripFree)
                ww_log("resize hwnd=%p: free (width and height on their own; %s%s)", (void *)w->hwnd, how,
                       ww_resize_free_default() ? ", env.MADEIRA_WINDOWED_RESIZE_FREE = 1" : "");
            else
                ww_log("resize hwnd=%p: aspect locked %d:%d (client %.0fx%.0f; %s)", (void *)w->hwnd,
                       w->resizeAspectW, w->resizeAspectH, c.width, c.height, how);
            ww_raise(w, YES, "resize");
        }
    }
    [self touched];
    if (_gripZooming) [self gripZoom:g];
    else [self gripResize:g];
    if (end) {
        _gripDragging = NO;
        _gripLines.lineWidth = 2;
        [self updateGrip];
    }
}

- (void)gripResize:(UIPanGestureRecognizer *)g {
    WWWin *w = [self win];
    if (!w || !w->resizing) return;
    BOOL end = g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed;
    CGPoint t = [g translationInView:self.superview];
    CGFloat k = MAX(w->k, 0.01);
    /* at least a grip's worth of window in points and 64 x 32 pixels; the
     * program's own limits (WM_GETMINMAXINFO) apply in the guest */
    CGFloat minW = MAX(64, ceil(2 * WW_GRIP / k)), minH = MAX(32, ceil(2 * WW_GRIP / k));
    CGSize want;
    if (_gripFree) {
        want = CGSizeMake(MIN(MAX(round(_resizeStart.width + t.x / k), minW), 8192),
                          MIN(MAX(round(_resizeStart.height + t.y / k), minH), 8192));
        w->resizeClientWant = CGSizeZero;
    } else {
        /* round 9: one scale for both axes of the client area, from the axis
         * the finger moved more (relative to the size at the start), so the
         * program's picture keeps its proportions; whole steps of the reduced
         * aspect (16 x 9 pixels for 16:9) keep it exact */
        CGSize c0 = _resizeClient0, nc = _resizeNC;
        CGFloat sw = (c0.width + t.x / k) / c0.width, sh = (c0.height + t.y / k) / c0.height;
        CGFloat s = fabs(sw - 1) >= fabs(sh - 1) ? sw : sh;
        CGFloat sMin = MAX((minW - nc.width) / c0.width, (minH - nc.height) / c0.height);
        CGFloat sMax = MIN((8192 - nc.width) / c0.width, (8192 - nc.height) / c0.height);
        s = MIN(MAX(s, sMin), MAX(sMax, sMin));
        int aw = w->resizeAspectW, ah = w->resizeAspectH;
        CGFloat cw, ch;
        if (aw > 0 && ah > 0 && aw <= 64 && ah <= 64) {
            CGFloat n = MAX(round(c0.width * s / aw), MAX(ceil(c0.width * sMin / aw - 0.001), 1));
            cw = n * aw;
            ch = n * ah;
        } else {
            cw = MAX(round(c0.width * s), 1);
            ch = MAX(round(c0.height * s), 1);
        }
        w->resizeClientWant = CGSizeMake(cw, ch);
        want = CGSizeMake(cw + nc.width, ch + nc.height);
    }
    w->resizeWant = want;
    /* the outline of the new size, from the frame's top-left */
    CGFloat barH = WW_BAR_H;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _ghost.frame = CGRectMake(0, 0, MAX(want.width * k, ww_min_bar_w()), barH + want.height * k);
    if (!end) _ghost.hidden = CGSizeEqualToSize(want, w->desk.size);
    [CATransaction commit];
    if (end) {
        w->resizing = NO;
        if (w->resizeSentAt <= 0 && CGSizeEqualToSize(want, w->desk.size)) {   /* never moved */
            _ghost.hidden = YES;
            return;
        }
        ww_send_resize(w, want, w->resizeSentAt > 0 ? 2 : 3);
        __weak WWFrameView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf ghostDone];   /* the program kept another size (its limits) or is slow */
        });
        return;
    }
    double since = CACurrentMediaTime() - w->resizeSentAt;
    if (since >= WW_RESIZE_EVERY_S) {
        if (!CGSizeEqualToSize(want, w->desk.size)) ww_send_resize(w, want, w->resizeSentAt > 0 ? 0 : 1);
    } else if (!_resizeTrailPending) {
        /* the finger may stop here: the latest size goes out when the interval is up */
        _resizeTrailPending = YES;
        __weak WWFrameView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((WW_RESIZE_EVERY_S - since) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WWFrameView *s = weakSelf;
            if (!s) return;
            s.resizeTrailPending = NO;
            WWWin *v = [s win];
            if (v && v->resizing && CACurrentMediaTime() - v->resizeSentAt >= WW_RESIZE_EVERY_S - 0.001)
                ww_send_resize(v, v->resizeWant, v->resizeSentAt > 0 ? 0 : 1);
        });
    }
}

/* Round 8: a pinch on the title bar zooms the picture (the guest window keeps
 * its size), what the grip did in rounds 2-7. */
- (void)barPinched:(UIPinchGestureRecognizer *)g {
    WWWin *w = [self win];
    if (!w || w->fullscreen || w->maximized || w->desk.size.width <= 0) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _scaleStartK = w->k;
        w->userScaled = YES;   /* from now on a size change keeps this zoom */
        ww_raise(w, NO, "zoom");
    }
    [self touched];
    w->k = MIN(MAX(_scaleStartK * g.scale, 0.15), 3.0);
    ww_clamp(w);
    ww_apply_frame(w);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
        ww_log("scale hwnd=%p zoom=%.2f pt/px (title bar pinch; the guest window keeps its size; kept when it resizes)",
               (void *)w->hwnd, w->k);
}

/* The round 2 grip: zoom the picture, the guest window keeps its size. */
- (void)gripZoom:(UIPanGestureRecognizer *)g {
    WWWin *w = [self win];
    if (!w) return;
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
    NSArray<UIButton *> *shown = [self barButtons];   /* round 9: three unless the fit button is back */
    for (UIButton *b in shown) {
        b.frame = CGRectMake(x, (WW_BAR_H - side) / 2, side, side);
        x -= side + gap;
    }
    CGFloat n = shown.count, buttons = n * side + (n - 1) * gap + 14;
    if (width >= 2 * buttons + 80) _label.frame = CGRectMake(buttons, 0, width - 2 * buttons, WW_BAR_H);   /* centred */
    else _label.frame = CGRectMake(12, 0, MAX(width - buttons - 16, 0), WW_BAR_H);   /* narrow: left of the buttons */
    WWWin *w = [self win];
    BOOL full = w && w->fullscreen;
    /* fullscreen (fit) is a state the frame is in (it cannot be dragged): the
     * button says so with the shrink arrows and a light ring, not a colour */
    [_fullButton setImage:ww_glyph(full ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right", WW_BTN_GLYPH)
                 forState:UIControlStateNormal];
    _fullButton.layer.borderWidth = full ? 1.5 : 0;
    _fullButton.accessibilityLabel = full ? @"Leave fit to screen" : @"Fit to screen";
    [self applyActive];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [self applyActive];
    [self updateGrip];   /* round 8: the grip belongs to the active frame only */
}

- (void)applyActive {
    if (_chromeless) return;
    for (UIButton *b in @[_minButton, _fullButton, _maxButton, _closeButton]) ww_style_glyph_button(b, _active);
    _label.textColor = [UIColor colorWithWhite:1 alpha:_active ? 1 : 0.62];
}

/* Touches a little outside the round buttons still hit them (round 8: a
 * 32-point square target centred on each 22-point circle; with the 10-point
 * gaps neighbouring targets just meet). A touch on the chrome (title bar,
 * buttons, grip) shows the grip for a moment; one on the window inside is
 * seen by winios_windowed_map_point. */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = nil;
    if (!_chromeless && !self.hidden && !_bar.hidden) {
        CGFloat pad = (WW_BTN_HIT - WW_BTN) / 2;
        for (UIButton *b in [self barButtons]) {
            CGRect r = CGRectInset([self convertRect:b.frame fromView:b.superview], -pad, -pad);
            if (CGRectContainsPoint(r, point)) { hit = b; break; }
        }
    }
    if (!hit) hit = [super hitTest:point withEvent:event];
    if (hit && hit != self && !_chromeless && event && event.type == UIEventTypeTouches) [self touched];
    return hit;
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
    _search.font = [UIFont systemFontOfSize:13];   /* round 9: was 14 */
    _search.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _search.layer.cornerRadius = WW_DOCK_ITEM / 2;   /* round 9: one item high (was item - 2) */
    _search.returnKeyType = UIReturnKeySearch;   /* round 7: the keyboard's Search key picks the first result */
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    /* round 7: no suggestion bar either, where iOS allows it (more room above the keyboard) */
    _search.spellCheckingType = UITextSpellCheckingTypeNo;
    _search.inlinePredictionType = UITextInlinePredictionTypeNo;
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    _search.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.5]}];
    /* placed by WWSearchField's rects: 11 points in from the edge, 7 before the text */
    UIImageView *glass = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightMedium]]];   /* round 9: was 13 */
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
     * (WindowedMode.swift) hides it. Round 7: pinned only with
     * env.MADEIRA_WINDOWED_STEAM = 1; by default the Steam window's own
     * program button is the tile (ww_dock_refresh). */
    _steamAllowed = bridge && ww_bridge_bool(@"steamButtonEnabled");
    _steamPinned = _steamAllowed && ww_bridge_bool(@"steamTilePinned");
    _steamButton = [WWButton buttonWithType:UIButtonTypeCustom];
    _steamButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    _steamButton.layer.cornerRadius = WW_DOCK_ICON_R;
    _steamButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_steamButton setImage:ww_glyph(@"gamecontroller", WW_DOCK_ITEM) forState:UIControlStateNormal];
    _steamButton.tintColor = [UIColor colorWithWhite:1 alpha:0.92];
    _steamButton.accessibilityLabel = @"Steam";
    [_steamButton addTarget:self action:@selector(steamPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _steamButton.hidden = !_steamPinned;
    [_pill.contentView addSubview:_steamButton];
    /* round 5: the installed client's own icon replaces the glyph (ww_steam_icon_check).
     * Round 7: placed by ww_layout_dock in the program icons' box (30 points since round 9); it
     * used to grow with the button (flexible size from a zero-sized button: 72
     * points, over the pill's edge). */
    _steamIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, WW_DOCK_ITEM, WW_DOCK_ITEM)];
    _steamIcon.contentMode = UIViewContentModeScaleAspectFit;
    _steamIcon.autoresizingMask = UIViewAutoresizingNone;
    _steamIcon.layer.cornerRadius = WW_DOCK_ICON_R;
    _steamIcon.layer.cornerCurve = kCACornerCurveContinuous;
    _steamIcon.clipsToBounds = YES;
    _steamIcon.userInteractionEnabled = NO;
    _steamIcon.hidden = YES;
    [_steamButton addSubview:_steamIcon];
    _steamDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, 5)];
    _steamDot.layer.cornerRadius = 2.5;
    _steamDot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    _steamDot.userInteractionEnabled = NO;
    _steamDot.hidden = YES;
    [_pill.contentView addSubview:_steamDot];

    /* round 5: while the search field has the software keyboard, the taskbar
     * (and the results panel above it) ride above the keyboard */
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)canBecomeFocused { return NO; }

/* The keyboard's end frame in the root view: a docked keyboard (it reaches
 * the bottom of the view) lifts the taskbar by the height it covers, with the
 * keyboard's own duration and curve. A floating (iPad) keyboard, one that
 * belongs to another text input, or the keyboard going away: back down. */
- (void)keyboardWillChange:(NSNotification *)n {
    if (!g_root || g_dock != self) return;
    BOOL hide = [n.name isEqualToString:UIKeyboardWillHideNotification];
    NSValue *end = n.userInfo[UIKeyboardFrameEndUserInfoKey];
    UIScreen *screen = g_root.window.windowScene.screen;
    CGFloat lift = 0;
    if (!hide && _search.isFirstResponder && end && screen) {
        CGRect kb = [g_root convertRect:end.CGRectValue fromCoordinateSpace:screen.coordinateSpace];
        CGRect b = g_root.bounds;
        if (kb.size.height > 0 && CGRectGetMaxY(kb) >= CGRectGetMaxY(b) - 1 && CGRectGetMinY(kb) < CGRectGetMaxY(b))
            lift = CGRectGetMaxY(b) - MAX(CGRectGetMinY(kb), CGRectGetMinY(b));
    }
    if (fabs(lift - g_kb_lift) < 0.5) return;
    g_kb_lift = lift;
    ww_log("search: keyboard %s (%.0f pt): taskbar %s", lift > 0 ? "up" : "down", lift,
           lift > 0 ? "and results moved above it" : "back at the bottom");
    double duration = [n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSUInteger curve = [n.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue];
    [UIView animateWithDuration:duration > 0 ? duration : 0.25 delay:0
                        options:(UIViewAnimationOptions)(curve << 16) | UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{ ww_layout_dock(); [(UIView *)g_launch layoutIfNeeded]; }
                     completion:nil];
}

/* The keyboard and menu buttons answer a touch only: a controller's A on a
 * focused button opened the keyboard over the game. */
- (void)keyboardPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar keyboard button")) return;
    ww_search_release("taskbar keyboard button");
    ww_bridge_call(@"toggleKeyboard");
}
- (void)menuPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar menu button")) return;
    ww_search_release("taskbar menu button");
    ww_bridge_call(@"openMenu");
}
/* The pinned Steam button (ww_steam_activate). */
- (void)steamPressed:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar Steam button")) return;
    ww_search_release("taskbar Steam button");
    ww_steam_icon_check(YES);
    ww_steam_activate("taskbar Steam button");
}

/* Round 5: the field is the launcher's: editing it shows the results panel,
 * typing filters it, Go picks the first result (nothing typed: just closes),
 * and the panel closes with the keyboard. */
- (void)searchChanged { ww_launch_filter(); }

- (void)textFieldDidBeginEditing:(UITextField *)field { ww_launch_open(); }

- (void)textFieldDidEndEditing:(UITextField *)field { ww_launch_closed(); }

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    NSString *typed = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (typed.length && ww_launch_pick(0)) return NO;
    g_launch_close_why = typed.length ? "Go with no match" : "Go on an empty field";
    [field resignFirstResponder];
    return NO;
}

- (void)appTapped:(UIButton *)b forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "taskbar button")) return;
    ww_search_release("taskbar button");
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
    CGFloat pillH = 2 * WW_PILL_PAD + WW_PILL_BTN;   /* round 9: 40 x 78 points (was 46 x 92) */
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 2 * WW_PILL_PAD + 2 * WW_PILL_BTN + WW_PILL_GAP, pillH)])) return nil;
    /* the chrome's material, as the title bars and the taskbar */
    _blur = ww_material(pillH / 2, kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
    _blur.frame = self.bounds;
    _blur.userInteractionEnabled = NO;
    [self addSubview:_blur];
    NSString *icon = [UIImage systemImageNamed:@"macwindow.on.rectangle"] ? @"macwindow.on.rectangle" : @"rectangle.on.rectangle";
    _restoreButton = ww_round_button(icon, WW_PILL_BTN);
    _restoreButton.accessibilityLabel = @"Show all windows";
    [_restoreButton addTarget:self action:@selector(restorePressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    _menuButton = ww_round_button(@"line.3.horizontal", WW_PILL_BTN);
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
    /* round 7: drag it anywhere (one finger, touches only; a tap still hits
     * the buttons: the pan begins only after the finger moves) */
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    drag.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:drag];
    return self;
}
- (BOOL)canBecomeFocused { return NO; }
- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;
    ww_material_fit(_blur);
    _restoreButton.frame = CGRectMake(WW_PILL_PAD, WW_PILL_PAD, WW_PILL_BTN, WW_PILL_BTN);
    _menuButton.frame = CGRectMake(WW_PILL_PAD + WW_PILL_BTN + WW_PILL_GAP, WW_PILL_PAD, WW_PILL_BTN, WW_PILL_BTN);
}
/* Round 7: the pill follows the finger, kept inside the safe area; where it
 * was left is kept for the session (ww_layout_pill). */
- (void)dragged:(UIPanGestureRecognizer *)g {
    UIView *root = self.superview;
    if (!root) return;
    if (g.state == UIGestureRecognizerStateBegan) [self wake];
    CGPoint t = [g translationInView:root];
    [g setTranslation:CGPointZero inView:root];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    CGRect b = root.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;
    g_pill_moved = YES;
    g_pill_at = CGPointMake(c.x / b.size.width, c.y / b.size.height);
    ww_layout_pill();
    g_pill_at = CGPointMake(self.center.x / b.size.width, self.center.y / b.size.height);   /* as clamped */
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self wake];
        ww_log("pill moved to (%.0f,%.0f) pt (kept for this session)", self.center.x, self.center.y);
    }
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
    CGFloat h = 2 * WW_PILL_PAD + WW_PILL_BTN;   /* round 9: 40 (was 46) */
    CGFloat w = g_pill.menuButton.hidden ? h : 2 * WW_PILL_PAD + 2 * WW_PILL_BTN + WW_PILL_GAP;
    if (!g_pill_moved || b.size.width <= 0 || b.size.height <= 0) {
        g_pill.frame = CGRectMake(CGRectGetMidX(b) - w / 2, CGRectGetMaxY(b) - MAX(s.bottom, 6) - h - 4, w, h);
        return;
    }
    /* round 7: where it was dragged (fractions of the root, so a rotation
     * keeps it on the same side), inside the safe area */
    CGFloat minX = MAX(s.left, 4) + w / 2, maxX = b.size.width - MAX(s.right, 4) - w / 2;
    CGFloat minY = MAX(s.top, 4) + h / 2, maxY = b.size.height - MAX(s.bottom, 4) - h / 2;
    CGFloat cx = MIN(MAX(g_pill_at.x * b.size.width, minX), MAX(maxX, minX));
    CGFloat cy = MIN(MAX(g_pill_at.y * b.size.height, minY), MAX(maxY, minY));
    g_pill.frame = CGRectMake(round(cx - w / 2), round(cy - h / 2), w, h);
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
        ww_log("maximize hwnd=%p on (%s): the whole screen, no title bar, taskbar hidden; the pill %s "
               "or the menu's Show all windows brings the windows back", (void *)w->hwnd, why,
               g_pill_moved ? "where it was dragged" : "at the bottom (drag it anywhere)");
        ww_bridge_call_bool(@"maximizedChanged:", YES);   /* round 7: the library's round menu button hides */
    } else {
        if (!w->maximized) return;
        w->maximized = NO;
        if (g_max == w->hwnd) g_max = 0;
        if (!g_max) {
            if (g_pill) g_pill.hidden = YES;
            if (g_dock) g_dock.hidden = NO;
            ww_bridge_call_bool(@"maximizedChanged:", NO);   /* round 7: the round menu button comes back */
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
 * Program icons from PE resources (round 5)
 *
 * The icon Windows shows for a program file: its first icon group
 * (RT_GROUP_ICON, in resource order) and, from that group, preferably the
 * 32-bit 64x64 image, else the 32-bit 48x48, else the nearest size. The
 * image is a PNG or a DIB (1/4/8/24/32 bits per pixel, AND mask for
 * transparency). Read from the user's installed files at run time, on a
 * background queue; every offset is bounds-checked against the file.
 * ------------------------------------------------------------------ */

static uint32_t ww_le16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }
static uint32_t ww_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

typedef struct {
    const uint8_t *base;
    size_t size;
    const uint8_t *sections;   /* the section table */
    unsigned nsec;
    uint32_t rsrc;             /* RVA of the resource directory */
} ww_pe;

#define WW_RES_NONE 0xFFFFFFFFu

/* `len` bytes at `rva`, inside one section's data in the file; NULL otherwise. */
static const uint8_t *ww_pe_at(const ww_pe *pe, uint32_t rva, uint32_t len)
{
    for (unsigned i = 0; i < pe->nsec; i++) {
        const uint8_t *s = pe->sections + (size_t)i * 40;
        uint32_t vsize = ww_le32(s + 8), va = ww_le32(s + 12), raw = ww_le32(s + 16), ptr = ww_le32(s + 20);
        uint32_t span = vsize > raw ? vsize : raw;
        if (rva < va || rva - va >= span) continue;
        uint64_t in = (uint64_t)(rva - va);
        if (in + len > raw) return NULL;                 /* past the file data (zero fill) */
        uint64_t off = (uint64_t)ptr + in;
        if (off + len > pe->size) return NULL;
        return pe->base + off;
    }
    return NULL;
}

/* In the resource directory at `dir` (an offset into the resource section),
 * the entry for `id` (id < 0: the first entry; named entries come first, as
 * in Windows' resource order). Its offset: a subdirectory when `want_dir`,
 * else a data entry; WW_RES_NONE when there is none. */
static uint32_t ww_res_entry(const ww_pe *pe, uint32_t dir, int id, int want_dir)
{
    const uint8_t *d = ww_pe_at(pe, pe->rsrc + dir, 16);
    if (!d) return WW_RES_NONE;
    uint32_t n = ww_le16(d + 12) + ww_le16(d + 14);
    if (!n || n > 4096) return WW_RES_NONE;
    const uint8_t *e = ww_pe_at(pe, pe->rsrc + dir + 16, n * 8);
    if (!e) return WW_RES_NONE;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t name = ww_le32(e + i * 8), data = ww_le32(e + i * 8 + 4);
        if (id >= 0 && ((name & 0x80000000u) || name != (uint32_t)id)) continue;
        int is_dir = (data & 0x80000000u) != 0;
        if (is_dir != (want_dir != 0)) {
            if (id >= 0) return WW_RES_NONE;
            continue;
        }
        return data & 0x7FFFFFFFu;
    }
    return WW_RES_NONE;
}

/* The bytes of resource `type` / `id` (id < 0: the first), first language. */
static const uint8_t *ww_res_data(const ww_pe *pe, int type, int id, uint32_t *len)
{
    uint32_t t = ww_res_entry(pe, 0, type, 1);
    uint32_t r = t == WW_RES_NONE ? WW_RES_NONE : ww_res_entry(pe, t, id, 1);
    uint32_t l = r == WW_RES_NONE ? WW_RES_NONE : ww_res_entry(pe, r, -1, 0);
    if (l == WW_RES_NONE) return NULL;
    const uint8_t *de = ww_pe_at(pe, pe->rsrc + l, 16);
    if (!de) return NULL;
    uint32_t rva = ww_le32(de), size = ww_le32(de + 4);
    if (!size || size > 16u * 1024 * 1024) return NULL;
    *len = size;
    return ww_pe_at(pe, rva, size);
}

/* An icon DIB (BITMAPINFOHEADER, XOR bitmap at twice the height, AND mask)
 * as a premultiplied BGRA image; NULL for a format it does not decode. */
static CGImageRef ww_dib_image(const uint8_t *p, uint32_t len)
{
    if (len < 40) return NULL;
    uint32_t hsize = ww_le32(p);
    int32_t w = (int32_t)ww_le32(p + 4), h2 = (int32_t)ww_le32(p + 8);
    uint32_t bpp = ww_le16(p + 14), comp = ww_le32(p + 16), used = ww_le32(p + 32);
    if (hsize < 40 || hsize > len || w <= 0 || w > 512 || h2 <= 1 || h2 > 1024 || comp != 0) return NULL;
    if (bpp != 1 && bpp != 4 && bpp != 8 && bpp != 24 && bpp != 32) return NULL;
    int h = h2 / 2;
    uint32_t ncolors = bpp <= 8 ? (used && used <= (1u << bpp) ? used : (1u << bpp)) : 0;
    uint64_t xor_off = (uint64_t)hsize + (uint64_t)ncolors * 4;
    uint64_t stride = (((uint64_t)w * bpp + 31) / 32) * 4, and_stride = (((uint64_t)w + 31) / 32) * 4;
    if (xor_off + stride * h > len) return NULL;
    const uint8_t *pal = p + hsize, *xor_bits = p + xor_off;
    const uint8_t *and_bits = xor_off + stride * h + and_stride * h <= len ? xor_bits + stride * h : NULL;
    uint8_t *px = malloc((size_t)w * h * 4);
    if (!px) return NULL;
    int any_alpha = 0;
    for (int y = 0; y < h; y++) {
        const uint8_t *row = xor_bits + (size_t)(h - 1 - y) * stride;   /* bottom-up */
        uint8_t *out = px + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            uint8_t b = 0, g = 0, r = 0, a = 255;
            if (bpp == 32) {
                b = row[x * 4]; g = row[x * 4 + 1]; r = row[x * 4 + 2]; a = row[x * 4 + 3];
                if (a) any_alpha = 1;
            } else if (bpp == 24) {
                b = row[x * 3]; g = row[x * 3 + 1]; r = row[x * 3 + 2];
            } else {
                uint32_t idx = bpp == 8 ? row[x]
                             : bpp == 4 ? (uint32_t)(row[x >> 1] >> ((x & 1) ? 0 : 4)) & 15
                                        : (uint32_t)(row[x >> 3] >> (7 - (x & 7))) & 1;
                if (idx < ncolors) { b = pal[idx * 4]; g = pal[idx * 4 + 1]; r = pal[idx * 4 + 2]; }
            }
            out[x * 4] = b; out[x * 4 + 1] = g; out[x * 4 + 2] = r; out[x * 4 + 3] = a;
        }
    }
    for (int y = 0; y < h; y++) {
        const uint8_t *mask = and_bits ? and_bits + (size_t)(h - 1 - y) * and_stride : NULL;
        uint8_t *out = px + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            uint8_t *q = out + x * 4;
            /* no alpha channel (or an all-zero one): the AND mask marks the transparent pixels */
            if (bpp < 32 || !any_alpha) q[3] = mask && ((mask[x >> 3] >> (7 - (x & 7))) & 1) ? 0 : 255;
            if (q[3] != 255) { q[0] = (uint8_t)(q[0] * q[3] / 255); q[1] = (uint8_t)(q[1] * q[3] / 255); q[2] = (uint8_t)(q[2] * q[3] / 255); }
        }
    }
    NSData *data = [NSData dataWithBytesNoCopy:px length:(size_t)w * h * 4 freeWhenDone:YES];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
                                   kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return img;
}

/* Any thread. The icon of the program file at `path` (host path), its size,
 * or nil and why not. */
static UIImage *ww_pe_icon(NSString *path, int *ow, int *oh, const char **why)
{
    *why = "unreadable";
    __attribute__((objc_precise_lifetime)) NSData *file =
        [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!file || file.length < 64) return nil;
    const uint8_t *b = file.bytes;
    size_t size = file.length;
    *why = "not a Windows program file";
    if (b[0] != 'M' || b[1] != 'Z') return nil;
    uint32_t pe_off = ww_le32(b + 60);
    if ((uint64_t)pe_off + 24 > size || memcmp(b + pe_off, "PE\0\0", 4)) return nil;
    const uint8_t *coff = b + pe_off + 4;
    unsigned nsec = ww_le16(coff + 2), optsize = ww_le16(coff + 16);
    const uint8_t *opt = coff + 20;
    if (!nsec || nsec > 96 || optsize < 2 || (uint64_t)pe_off + 24 + optsize + (uint64_t)nsec * 40 > size) return nil;
    uint32_t magic = ww_le16(opt), dd = magic == 0x10b ? 96 : magic == 0x20b ? 112 : 0;
    if (!dd || optsize < dd + 3 * 8 || ww_le32(opt + dd - 4) < 3) return nil;   /* NumberOfRvaAndSizes */
    ww_pe pe = { b, size, opt + optsize, nsec, ww_le32(opt + dd + 2 * 8) };
    *why = "no resources";
    if (!pe.rsrc) return nil;
    *why = "no icon";
    uint32_t glen = 0;
    const uint8_t *grp = ww_res_data(&pe, 14 /* RT_GROUP_ICON */, -1, &glen);
    if (!grp || glen < 6 || ww_le16(grp + 2) != 1) return nil;
    unsigned count = ww_le16(grp + 4);
    if (!count || count > 64 || 6 + count * 14 > glen) return nil;
    /* 32-bit first; then 64x64, then 48x48, then the size nearest 64 (larger first) */
    unsigned order[64];
    long rank[64];
    for (unsigned i = 0; i < count; i++) {
        const uint8_t *e = grp + 6 + i * 14;
        long side = e[0] ? e[0] : 256, bits = ww_le16(e + 6);
        long r = (bits >= 32 ? 0 : 100000) + (side == 64 ? 0 : side == 48 ? 10000 : 20000 + labs(side - 64) * 10 + (side < 64));
        unsigned k = i;
        while (k > 0 && rank[k - 1] > r) { rank[k] = rank[k - 1]; order[k] = order[k - 1]; k--; }
        rank[k] = r;
        order[k] = i;
    }
    *why = "its icon could not be decoded";
    for (unsigned k = 0; k < count; k++) {
        const uint8_t *e = grp + 6 + order[k] * 14;
        uint32_t ilen = 0;
        const uint8_t *data = ww_res_data(&pe, 3 /* RT_ICON */, (int)ww_le16(e + 12), &ilen);
        if (!data) continue;
        CGImageRef img = NULL;
        if (ilen >= 8 && !memcmp(data, "\x89PNG\r\n\x1a\n", 8)) {
            UIImage *png = [UIImage imageWithData:[NSData dataWithBytes:data length:ilen]];
            if (png.CGImage) img = CGImageRetain(png.CGImage);
        } else {
            img = ww_dib_image(data, ilen);
        }
        if (!img) continue;
        *ow = (int)CGImageGetWidth(img);
        *oh = (int)CGImageGetHeight(img);
        UIImage *icon = [UIImage imageWithCGImage:img];
        CGImageRelease(img);
        *why = NULL;
        return icon;
    }
    return nil;
}

static dispatch_queue_t ww_icon_queue(void)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("madeira.windowed.icons",
                                  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return q;
}

/* "<...>/wine/drive_c/Program Files/x.exe" -> "C:\Program Files\x.exe" (log lines). */
static NSString *ww_windows_path(NSString *host)
{
    NSRange r = [host rangeOfString:@"/drive_c/"];
    if (r.location == NSNotFound) return host.lastPathComponent ?: @"";
    return [@"C:\\" stringByAppendingString:
            [[host substringFromIndex:NSMaxRange(r)] stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

/* Main thread. The icon of a program file, or (cover) a library cover image
 * cut to a square: the cached one; nil while it loads in the background (the
 * results panel is filled again when it arrives) or, with *failed, when there
 * is none. */
static NSMutableDictionary<NSString *, id> *g_icons;     /* path -> UIImage, or NSNull */
static NSMutableSet<NSString *> *g_icons_pending;
static BOOL g_icons_refill_queued;

static UIImage *ww_icon_lookup(NSString *path, BOOL cover, BOOL *failed)
{
    if (failed) *failed = NO;
    if (![path isKindOfClass:[NSString class]] || !path.length) { if (failed) *failed = YES; return nil; }
    if (!g_icons) { g_icons = [NSMutableDictionary new]; g_icons_pending = [NSMutableSet new]; }
    id hit = g_icons[path];
    if ([hit isKindOfClass:[UIImage class]]) return hit;
    if (hit) { if (failed) *failed = YES; return nil; }
    if ([g_icons_pending containsObject:path]) return nil;
    [g_icons_pending addObject:path];
    dispatch_async(ww_icon_queue(), ^{
        UIImage *image = nil;
        if (cover) {
            UIImage *full = [UIImage imageWithContentsOfFile:path];
            CGSize s = full.size;
            if (full && s.width > 0 && s.height > 0) {
                CGFloat k = MAX(64 / s.width, 64 / s.height);
                UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)];
                image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                    [full drawInRect:CGRectMake((64 - s.width * k) / 2, (64 - s.height * k) / 2, s.width * k, s.height * k)];
                }];
            }
        } else {
            int w = 0, h = 0;
            const char *why = NULL;
            image = ww_pe_icon(path, &w, &h, &why);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_icons) return;
            [g_icons_pending removeObject:path];
            if (g_icons.count > 512) [g_icons removeAllObjects];
            g_icons[path] = image ?: (id)NSNull.null;
            if (g_icons_refill_queued) return;
            g_icons_refill_queued = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ g_icons_refill_queued = NO; ww_launch_filter(); });
        });
    });
    return nil;
}

/* A white SF Symbol on the chrome's neutral rounded tile (tools without an icon). */
static UIImage *ww_symbol_tile(NSString *symbol)
{
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    UIImage *hit = cache[symbol];
    if (hit) return hit;
    UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:
                       [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(34, 34)];
    UIImage *image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithWhite:1 alpha:0.16] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 34, 34) cornerRadius:8] fill];
        if (glyph) {
            CGSize s = glyph.size;
            [glyph drawInRect:CGRectMake((34 - s.width) / 2, (34 - s.height) / 2, s.width, s.height)];
        }
    }];
    cache[symbol] = image;
    return image;
}

/* ------------------------------------------------------------------ *
 * Steam on the taskbar (round 4; round 5: its icon)
 * ------------------------------------------------------------------ */

static UIImage *g_steam_icon;              /* the installed steam.exe's icon, once read */
static NSString *g_steam_icon_path;        /* the steam.exe last tried (loading, read or failed) */
static CFTimeInterval g_steam_icon_checked;
static BOOL g_steam_icon_logged;           /* the placeholder line, once per session */

static void ww_steam_icon_apply(void)
{
    WWDock *d = g_dock;
    if (!d) return;
    BOOL real = g_steam_icon != nil;
    d.steamIcon.image = g_steam_icon;
    d.steamIcon.hidden = !real;
    [d.steamButton setImage:real ? nil : ww_glyph(@"gamecontroller", WW_DOCK_ITEM) forState:UIControlStateNormal];
    d.steamButton.backgroundColor = real ? UIColor.clearColor : [UIColor colorWithWhite:1 alpha:0.14];
    if (g_steam_tile) ww_dock_refresh();   /* round 7: the Steam window's program button takes the icon */
}

/* Main thread. Until the tile has the client's icon: is Steam installed in the
 * prefix (WindowedMode.swift, the paths the tile starts)? Then read the icon
 * of that steam.exe in the background. At most every 5 s unless `force`
 * (a tap on the tile, the search panel opening); a file whose icon could not
 * be read is not read again this session. */
static void ww_steam_icon_check(BOOL force)
{
    WWDock *d = g_dock;
    if (!d || !d.steamAllowed || g_steam_icon) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (!force && g_steam_icon_checked > 0 && now - g_steam_icon_checked < 5) return;
    g_steam_icon_checked = now;
    NSString *path = ww_bridge_string(@"steamClientHostPath");
    if (!path.length) {
        if (!g_steam_icon_logged && (g_steam_icon_logged = YES))
            ww_log("steam: icon placeholder (Steam is not installed in the prefix; the tile keeps its glyph)");
        return;
    }
    if ([path isEqualToString:g_steam_icon_path]) return;
    g_steam_icon_path = path;
    NSString *shown = ww_windows_path(path);
    dispatch_async(ww_icon_queue(), ^{
        int w = 0, h = 0;
        const char *why = NULL;
        UIImage *icon = ww_pe_icon(path, &w, &h, &why);
        NSString *reason = why ? @(why) : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![g_steam_icon_path isEqualToString:path]) return;   /* another session since */
            if (icon) {
                g_steam_icon = icon;
                ww_steam_icon_apply();
                ww_log("steam: icon from %s (%dx%d)", shown.UTF8String, w, h);
                ww_launch_filter();
            } else {
                g_steam_icon_logged = YES;
                ww_log("steam: icon placeholder (%s: %s; the tile keeps its glyph)", shown.UTF8String, reason.UTF8String);
            }
        });
    });
}

/* The pinned Steam button, or the search's Steam tool. A Steam window already
 * open in this session comes to the front (restored first when minimized).
 * Otherwise the Swift side decides: memory warning, then Steam (installed) or
 * Valve's installer (not installed), started inside this session (ml1350), or
 * as a library entry for the next start when that cannot run. */
static void ww_steam_activate(const char *why)
{
    WWWin *w = ww_steam_window();
    if (w) {
        if (w->appMinimized || ww_iconic(w)) {
            if (ww_iconic(w)) ww_enqueue(w->hwnd, WW_SC_RESTORE);
            w->appMinimized = NO;
            ww_update(w);
        }
        ww_raise(w, YES, why);
        ww_log("steam: launch (already running in this session: hwnd=%p \"%s\" exe=%s brought to the front)",
               (void *)w->hwnd, ww_display_title(w).UTF8String, w->exe.UTF8String);
        return;
    }
    ww_log("steam: button (no Steam window in this session; the app checks the install)");
    ww_bridge_call(@"steamTapped");
}

/* ------------------------------------------------------------------ *
 * Search launcher (round 5)
 * ------------------------------------------------------------------ */

static UIImage *ww_letter_icon(NSString *name);

static const CGFloat WW_ROW_H = 50;       /* a result row */
static const CGFloat WW_LIST_PAD = 6;     /* panel edge to the rows */
#define WW_LAUNCH_MAX 60                  /* rows shown at most */
/* Round 7: results as chips (one sideways-scrolling strip) */
static const CGFloat WW_CHIP_H = 30;      /* a chip: icon and name (round 9: the taskbar's item height; was 36) */
static const CGFloat WW_CHIP_GAP = 8;
static const CGFloat WW_CHIP_ICON = 22;   /* round 9: was 24 */
static const CGFloat WW_CHIP_BAR_H = 40;  /* the chip strip's panel, directly above the keyboard (round 9: was 48) */

static NSArray<NSDictionary *> *g_launch_items;   /* tools, library, programs (WindowedMode.swift) */
static NSArray<NSDictionary *> *g_launch_shown;   /* the rows, in order */
static NSString *g_launch_windows_sig;            /* the open windows the rows were made from */
static NSString *g_launch_query;                  /* round 7: what the rows were filtered by */
static BOOL g_chips_ok = YES;                     /* round 7: env.MADEIRA_WINDOWED_CHIPS != 0 (read when the panel opens) */

/* Round 7: the lowest point the taskbar (and the chips under it) may reach:
 * 8 points above the software keyboard while the search field has it, else
 * the bottom of the safe area. */
static CGFloat ww_chrome_bottom(void)
{
    UIEdgeInsets s = g_root.safeAreaInsets;
    CGRect b = g_root.bounds;
    CGFloat y = b.size.height - MAX(s.bottom, 6);
    if (g_kb_lift > 0) y = MIN(y, b.size.height - g_kb_lift - 8);
    return y;
}

/* Round 7: how the open results fit above the keyboard. The list needs room
 * for the taskbar and two rows (176 points); with less, one strip of chips
 * directly above the keyboard and the taskbar above it (112 points; an iPhone
 * in landscape has about 170 under the docked keyboard); with less still (a
 * taller keyboard or its suggestion bar), the chips go into the taskbar,
 * right of the field. env.MADEIRA_WINDOWED_CHIPS = 0: always the list. */
static int ww_launch_mode(void)
{
    if (!g_root || !g_launch || ((UIView *)g_launch).hidden || !g_chips_ok) return WW_LAUNCH_LIST;
    CGFloat room = ww_chrome_bottom() - MAX(g_root.safeAreaInsets.top, 8);
    if (room >= WW_DOCK_H + 8 + 2 * WW_ROW_H + 2 * WW_LIST_PAD) return WW_LAUNCH_LIST;
    if (room >= WW_DOCK_H + 8 + WW_CHIP_BAR_H) return WW_LAUNCH_CHIPS_ABOVE_KB;
    return WW_LAUNCH_CHIPS_IN_DOCK;
}

@interface WWLaunchRow : WWButton
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel, *detailLabel;
@property (nonatomic) BOOL primary;      /* the row Go picks: a faint background */
@property (nonatomic) BOOL compact;      /* round 7: a chip (icon and name) in a sideways strip */
- (CGFloat)chipWidth;
@end

@implementation WWLaunchRow
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layer.cornerRadius = 10;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.layer.cornerRadius = 7;
    _iconView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView.clipsToBounds = YES;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];
    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.whiteColor;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.userInteractionEnabled = NO;
    [self addSubview:_nameLabel];
    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = [UIFont systemFontOfSize:12];
    _detailLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _detailLabel.userInteractionEnabled = NO;
    [self addSubview:_detailLabel];
    return self;
}
- (void)applyBackground {
    /* round 7: chips always show their pill; the one Go picks is brighter, with a light edge */
    CGFloat a = self.highlighted ? (_compact ? 0.30 : 0.18) : _primary ? (_compact ? 0.22 : 0.08) : _compact ? 0.08 : 0;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:a];
    self.layer.borderWidth = _compact && _primary ? 1 : 0;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
}
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self applyBackground]; }
- (void)setPrimary:(BOOL)primary { _primary = primary; [self applyBackground]; }
- (void)setCompact:(BOOL)compact {
    if (_compact == compact) return;
    _compact = compact;
    _detailLabel.hidden = compact;
    _nameLabel.font = [UIFont systemFontOfSize:compact ? 14 : 15 weight:UIFontWeightSemibold];
    self.layer.cornerRadius = compact ? WW_CHIP_H / 2 : 10;
    _iconView.layer.cornerRadius = compact ? 6 : 7;
    [self applyBackground];
    [self setNeedsLayout];
}
/* Round 7: a chip's width for its name (icon, name, padding; 72 to 220 points). */
- (CGFloat)chipWidth {
    CGFloat text = ceil([_nameLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, WW_CHIP_H)].width);
    return MIN(MAX(6 + WW_CHIP_ICON + 8 + text + 14, 72), 220);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (_compact) {
        CGFloat h = self.bounds.size.height, w = self.bounds.size.width, x = 6 + WW_CHIP_ICON + 8;
        _iconView.frame = CGRectMake(6, (h - WW_CHIP_ICON) / 2, WW_CHIP_ICON, WW_CHIP_ICON);
        _nameLabel.frame = CGRectMake(x, 0, MAX(w - x - 12, 0), h);
        return;
    }
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width, side = 32, x = 10 + side + 12;
    _iconView.frame = CGRectMake(10, (h - side) / 2, side, side);
    _nameLabel.frame = CGRectMake(x, h / 2 - 18, MAX(w - x - 12, 0), 19);
    _detailLabel.frame = CGRectMake(x, h / 2 + 2, MAX(w - x - 12, 0), 16);
}
@end

/* The results panel: the chrome's material above the taskbar, a scrolling
 * list of rows. Not focusable, touch only, as the rest of the chrome. */
@interface WWLauncher : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) WWAppStrip *list;
@property (nonatomic, strong) UILabel *message;
@property (nonatomic, strong) NSMutableArray<WWLaunchRow *> *rows;
@property (nonatomic) int mode;          /* round 7: WW_LAUNCH_LIST or one of the chip layouts */
@end

@implementation WWLauncher
- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _rows = [NSMutableArray new];
    _blur = ww_material(16, kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
    [self addSubview:_blur];
    _list = [[WWAppStrip alloc] initWithFrame:CGRectZero];
    _list.showsHorizontalScrollIndicator = NO;
    _list.alwaysBounceVertical = NO;
    [_blur.contentView addSubview:_list];
    _message = [[UILabel alloc] initWithFrame:CGRectZero];
    _message.font = [UIFont systemFontOfSize:14];
    _message.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    _message.textAlignment = NSTextAlignmentCenter;
    _message.userInteractionEnabled = NO;
    [_blur.contentView addSubview:_message];
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.35;
    self.layer.shadowRadius = 10;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.hidden = YES;
    return self;
}
- (BOOL)canBecomeFocused { return NO; }
- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;
    ww_material_fit(_blur);
    CGFloat w = self.bounds.size.width;
    if (_mode != WW_LAUNCH_LIST) {
        /* round 7: one strip of chips, scrolling sideways (in the taskbar: no
         * panel of its own, the taskbar's material shows through) */
        CGFloat h = self.bounds.size.height, inset = _mode == WW_LAUNCH_CHIPS_IN_DOCK ? 0 : WW_LIST_PAD;
        _list.frame = CGRectMake(inset, 0, MAX(w - 2 * inset, 0), h);
        CGFloat x = 0;
        for (WWLaunchRow *row in _rows) {
            row.compact = YES;
            if (row.hidden) continue;
            CGFloat cw = [row chipWidth];
            row.frame = CGRectMake(x, round((h - WW_CHIP_H) / 2), cw, WW_CHIP_H);
            x += cw + WW_CHIP_GAP;
        }
        _list.contentSize = CGSizeMake(MAX(x - WW_CHIP_GAP, 0), h);
        _message.frame = CGRectInset(self.bounds, 12, 0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:16].CGPath;
        return;
    }
    _list.frame = CGRectInset(self.bounds, 0, WW_LIST_PAD);
    NSUInteger n = 0;
    for (WWLaunchRow *row in _rows) {
        row.compact = NO;
        if (row.hidden) continue;
        row.frame = CGRectMake(WW_LIST_PAD, n * WW_ROW_H, w - 2 * WW_LIST_PAD, WW_ROW_H);
        n++;
    }
    _list.contentSize = CGSizeMake(w, n * WW_ROW_H);
    _message.frame = CGRectInset(self.bounds, 16, 0);
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:16].CGPath;
}
- (void)rowPressed:(WWLaunchRow *)row forEvent:(UIEvent *)e {
    if (!ww_by_touch(e, "search result")) return;
    ww_launch_pick((NSUInteger)row.tag);
}
- (WWLaunchRow *)rowAt:(NSUInteger)i {
    while (_rows.count <= i) {
        WWLaunchRow *row = [[WWLaunchRow alloc] initWithFrame:CGRectZero];
        [row addTarget:self action:@selector(rowPressed:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [_list addSubview:row];
        [_rows addObject:row];
    }
    return _rows[i];
}
@end

/* The open windows as rows (the taskbar's windows), and a signature of them. */
static NSArray<NSDictionary *> *ww_launch_windows(NSString **sig)
{
    NSMutableArray *list = [NSMutableArray new];
    NSMutableString *s = [NSMutableString new];
    for (NSNumber *key in g_order) {
        WWWin *w = g_wins[key];
        if (!w || !ww_present(w)) continue;
        NSString *name = ww_display_title(w);
        NSString *detail = w->exe.length ? [NSString stringWithFormat:@"Open window · %@", w->exe] : @"Open window";
        [list addObject:@{@"kind": @"window", @"hwnd": key, @"name": name, @"detail": detail, @"alt": w->exe ?: @""}];
        [s appendFormat:@"%@|%@|%d|%d;", key, name, w->icon != nil, w->appMinimized || ww_iconic(w)];
    }
    if (sig) *sig = s;
    return list;
}

/* How well `q` matches an item: 0 its name starts with it, 1 a word of the
 * name does, 2 the name contains it, 3 only its program file name does; -1
 * no match. An empty query matches everything (2). */
static int ww_launch_match(NSDictionary *item, NSString *q)
{
    if (!q.length) return 2;
    NSString *name = item[@"name"];
    NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSRange r = [name isKindOfClass:[NSString class]] ? [name rangeOfString:q options:o] : NSMakeRange(NSNotFound, 0);
    if (r.location == 0) return 0;
    if (r.location != NSNotFound) {
        unichar before = [name characterAtIndex:r.location - 1];
        return [[NSCharacterSet alphanumericCharacterSet] characterIsMember:before] ? 2 : 1;
    }
    NSString *alt = item[@"alt"];
    if ([alt isKindOfClass:[NSString class]] && [alt rangeOfString:q options:o].location != NSNotFound) return 3;
    return -1;
}

static int ww_launch_kind_rank(NSString *kind)
{
    if ([kind isEqualToString:@"window"]) return 0;
    if ([kind isEqualToString:@"tool"]) return 1;
    if ([kind isEqualToString:@"library"] || [kind isEqualToString:@"steam"]) return 2;
    if ([kind isEqualToString:@"startmenu"]) return 3;
    return 4;
}

static void ww_launch_configure(WWLaunchRow *row, NSDictionary *item, BOOL primary)
{
    NSString *kind = item[@"kind"], *name = item[@"name"] ?: @"";
    row.nameLabel.text = name;
    row.detailLabel.text = item[@"detail"];
    row.accessibilityLabel = name;
    UIImage *icon = nil;
    if ([kind isEqualToString:@"window"]) {
        WWWin *w = ww_get([item[@"hwnd"] unsignedLongValue], NO);
        if (w) icon = w->icon ?: ww_letter_icon(w->exe.length ? w->exe : name);
    } else if ([item[@"action"] isEqual:@"steam"] && g_steam_icon) {
        icon = g_steam_icon;
    } else {
        BOOL failed = NO;
        icon = ww_icon_lookup(item[@"icon"], NO, &failed);
        if (!icon && failed && item[@"cover"]) icon = ww_icon_lookup(item[@"cover"], YES, NULL);
        if (!icon && [item[@"symbol"] isKindOfClass:[NSString class]]) icon = ww_symbol_tile(item[@"symbol"]);
    }
    row.iconView.image = icon ?: ww_letter_icon(name);
    row.primary = primary;
}

/* Main thread. The rows for what is typed: windows, then tools, the library,
 * Start Menu programs, other programs, best matches first. */
static void ww_launch_filter(void)
{
    WWLauncher *L = g_launch;
    if (!L || L.hidden || !g_dock) return;
    NSString *q = [g_dock.search.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    NSString *sig = nil;
    NSMutableArray<NSDictionary *> *all = [ww_launch_windows(&sig) mutableCopy];
    g_launch_windows_sig = sig;
    if (g_launch_items) [all addObjectsFromArray:g_launch_items];
    NSMutableArray<NSArray *> *hits = [NSMutableArray new];
    for (NSUInteger i = 0; i < all.count; i++) {
        int m = ww_launch_match(all[i], q);
        if (m < 0) continue;
        [hits addObject:@[@(m * 10 + ww_launch_kind_rank(all[i][@"kind"])), @(i), all[i]]];
    }
    [hits sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult c = [a[0] compare:b[0]];
        return c != NSOrderedSame ? c : [a[1] compare:b[1]];
    }];
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray new];
    for (NSArray *h in hits) { if (shown.count >= WW_LAUNCH_MAX) break; [shown addObject:h[2]]; }
    g_launch_shown = shown;
    for (NSUInteger i = 0; i < MAX(shown.count, L.rows.count); i++) {
        WWLaunchRow *row = [L rowAt:i];
        row.hidden = i >= shown.count;
        row.tag = (NSInteger)i;
        if (!row.hidden) ww_launch_configure(row, shown[i], i == 0 && q.length > 0);
    }
    L.message.hidden = shown.count > 0;
    L.message.text = q.length ? [NSString stringWithFormat:@"Nothing matches \u201C%@\u201D", q] : @"Nothing to show yet";
    /* round 7: new text shows the first result (the one Go picks) again;
     * a refill for icons or windows leaves the scroll where it is */
    if (![q isEqualToString:g_launch_query ?: @""]) [L.list setContentOffset:CGPointZero animated:NO];
    g_launch_query = q;
    ww_launch_layout();
    [L setNeedsLayout];
}

static void ww_launch_layout(void)
{
    WWLauncher *L = g_launch;
    WWDock *d = g_dock;
    if (!L || !d || !g_root) return;
    UIEdgeInsets s = g_root.safeAreaInsets;
    CGRect b = g_root.bounds;
    CGFloat left = MAX(s.left, 8), right = MAX(s.right, 8);
    /* round 7: chips under the taskbar or in it (ww_launch_mode) */
    int mode = ww_launch_mode();
    if (mode != L.mode) {
        if (!L.hidden)
            ww_log("search: results %s (%.0f pt above the keyboard)",
                   mode == WW_LAUNCH_CHIPS_IN_DOCK ? "as chips in the taskbar, right of the field"
                   : mode == WW_LAUNCH_CHIPS_ABOVE_KB ? "as chips directly above the keyboard, the taskbar above them"
                   : "as a list above the taskbar", ww_chrome_bottom() - MAX(s.top, 8));
        L.mode = mode;
        [L.list setContentOffset:CGPointZero animated:NO];
        [L setNeedsLayout];
    }
    BOOL inDock = mode == WW_LAUNCH_CHIPS_IN_DOCK;
    L.blur.hidden = inDock;
    L.layer.shadowOpacity = inDock ? 0 : 0.35;
    if (inDock) {
        CGFloat lead = WW_DOCK_PAD + WW_SEARCH_W + WW_DOCK_GAP;
        L.frame = CGRectMake(CGRectGetMinX(d.frame) + lead, CGRectGetMinY(d.frame),
                             MAX(d.frame.size.width - lead - WW_DOCK_PAD, 0), WW_DOCK_H);
        return;
    }
    if (mode == WW_LAUNCH_CHIPS_ABOVE_KB) {
        L.frame = CGRectMake(left, CGRectGetMaxY(d.frame) + 8, MAX(b.size.width - left - right, 0), WW_CHIP_BAR_H);
        return;
    }
    CGFloat width = MIN(MAX(d.frame.size.width, 380), b.size.width - left - right);
    CGFloat x = MIN(MAX(round(CGRectGetMidX(d.frame) - width / 2), left), b.size.width - right - width);
    CGFloat bottom = CGRectGetMinY(d.frame) - 8, top = MAX(s.top, 8);
    NSUInteger n = g_launch_shown.count;
    CGFloat want = (n ? n * WW_ROW_H : WW_ROW_H) + 2 * WW_LIST_PAD;
    CGFloat h = MIN(want, MAX(bottom - top, WW_ROW_H + 2 * WW_LIST_PAD));
    L.frame = CGRectMake(x, bottom - h, width, h);
}

/* The search field became first responder (a touch on it): the panel opens
 * with the open windows and the tools at once; the library and the prefix's
 * programs follow from WindowedMode.swift (immediately from its last scan,
 * again when a new scan of the prefix finishes). */
static void ww_launch_open(void)
{
    if (!g_root || !g_dock) return;
    if (!g_launch) g_launch = [WWLauncher new];
    if (g_launch.superview != g_root) [g_root addSubview:g_launch];
    [g_root bringSubviewToFront:g_launch];
    BOOL was = !g_launch.hidden;
    if (!was) {
        char cfg[16];
        const char *chips = madeira_cfg_get("env.MADEIRA_WINDOWED_CHIPS", cfg, sizeof(cfg)) ? cfg : getenv("MADEIRA_WINDOWED_CHIPS");   /* 0: the windowed taskbar's search always shows its results as a list above the taskbar (round 7 turns them into a strip of chips when the keyboard leaves too little room, e.g. an iPhone in landscape) */
        g_chips_ok = !(chips && chips[0] == '0' && !chips[1]);
        g_launch_query = nil;
    }
    g_launch.hidden = NO;
    ww_steam_icon_check(YES);
    Class c = ww_bridge();
    SEL s = NSSelectorFromString(@"launcherItems:");
    if (c && [c respondsToSelector:s]) {
        void (*fn)(id, SEL, void (^)(NSArray *)) = (void (*)(id, SEL, void (^)(NSArray *)))[c methodForSelector:s];
        fn(c, s, ^(NSArray *items) {
            /* the main thread: the Swift side answers on the main actor */
            g_launch_items = [items isKindOfClass:[NSArray class]] ? [items copy] : nil;
            ww_launch_filter();
        });
    }
    ww_launch_filter();
    ww_layout_dock();   /* round 7: the taskbar makes room when the results are chips */
    [g_launch.list setContentOffset:CGPointZero animated:NO];
    if (!was) {
        g_launch.alpha = 0;
        [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ g_launch.alpha = 1; } completion:nil];
        NSUInteger windows = 0;
        for (NSDictionary *item in g_launch_shown) if ([item[@"kind"] isEqual:@"window"]) windows++;
        ww_log("search: open (%lu windows, %lu programs and tools%s)", (unsigned long)windows,
               (unsigned long)g_launch_items.count, c ? "" : "; no Swift bridge: windows only");
    }
}

/* The search field gave up the keyboard: the panel closes, the text goes. */
static void ww_launch_closed(void)
{
    const char *why = g_launch_close_why ? g_launch_close_why : "keyboard dismissed";
    g_launch_close_why = NULL;
    if (g_launch && !g_launch.hidden) {
        g_launch.hidden = YES;
        ww_log("search: close (%s)", why);
    }
    g_launch_shown = nil;
    g_launch_query = nil;
    if (g_dock) g_dock.search.text = @"";
    if (g_kb_lift > 0) {
        /* the keyboard's hide notification may not come (another text input takes it) */
        g_kb_lift = 0;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ ww_layout_dock(); } completion:nil];
    } else {
        ww_layout_dock();   /* round 7: the program buttons come back from behind the chips */
    }
}

/* Row `index` was picked (a touch, or Go for row 0): a window comes to the
 * front (restored when minimized); the Steam tool does what the Steam tile
 * does; anything else starts inside the running session (WindowedMode.swift
 * launcherPick:, MadeiraSession). The field gives the keyboard back first. */
static BOOL ww_launch_pick(NSUInteger index)
{
    if (index >= g_launch_shown.count || !g_dock) return NO;
    NSDictionary *item = g_launch_shown[index];
    NSString *kind = item[@"kind"] ?: @"?", *name = item[@"name"] ?: @"";
    NSString *what = [kind isEqualToString:@"window"] ? [NSString stringWithFormat:@"hwnd=%p", (void *)[item[@"hwnd"] unsignedLongValue]]
                   : [item[@"action"] isEqual:@"steam"] ? @"the Steam tile's action"
                   : (item[@"command"] ?: @"");
    ww_log("search: pick %s \"%s\" (%s)", kind.UTF8String, name.UTF8String, what.UTF8String);
    g_launch_close_why = "picked";
    [g_dock.search resignFirstResponder];
    if ([kind isEqualToString:@"window"]) {
        WWWin *w = ww_get([item[@"hwnd"] unsignedLongValue], NO);
        if (!w) return YES;
        if (w->appMinimized || ww_iconic(w)) {
            if (ww_iconic(w)) ww_enqueue(w->hwnd, WW_SC_RESTORE);
            w->appMinimized = NO;
            ww_log("restore hwnd=%p (search)", (void *)w->hwnd);
            ww_update(w);
        }
        ww_raise(w, YES, "search");
    } else if ([item[@"action"] isEqual:@"steam"]) {
        ww_steam_activate("search");
    } else {
        ww_bridge_call_with(@"launcherPick:", item);
    }
    return YES;
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
    CGFloat width = MAX(w->desk.size.width * w->k, ww_min_bar_w());
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
    CGFloat width = MAX(w->desk.size.width * w->k, ww_min_bar_w()), height = w->desk.size.height * w->k;
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
        CGFloat width = MAX(w->desk.size.width * w->k, ww_min_bar_w()), height = w->desk.size.height * w->k;
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
    /* round 8: the size the grip asked for (or the program's answer to it)
     * changes the window, never the zoom: the frame grows or shrinks with it */
    if (resized && (w->resizing || CACurrentMediaTime() < w->resizeKeepK)) {
        w->fitSize = w->desk.size;
        ww_clamp(w);
        if (!w->resizing)
            ww_log("refit hwnd=%p rect={%.0f,%.0f %.0fx%.0f} zoom=%.2f (%s; resized with the grip, zoom kept)",
                   (void *)w->hwnd, w->desk.origin.x, w->desk.origin.y, w->desk.size.width, w->desk.size.height, w->k, why);
        return YES;
    }
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
    CGFloat width = f.chromeless ? cs.width : MAX(cs.width, ww_min_bar_w());
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
    f.grip.frame = CGRectMake(cs.width - WW_GRIP, barH + cs.height - WW_GRIP, WW_GRIP, WW_GRIP);
    if (!f.chromeless) {
        /* round 8: shown on the active frame for a moment after a touch (updateGrip) */
        f.gripAllowed = !w->fullscreen && !max;
        [f updateGrip];
        /* the guest window reached the size the drag asked for: the outline goes */
        if (!f.ghost.hidden && !w->resizing && CGSizeEqualToSize(w->desk.size, w->resizeWant)) [f ghostDone];
        if (!f.gripAllowed) f.ghost.hidden = YES;
    }
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

void winios_windowed_place(void *hwnd, CALayer *layer, int x, int y, int w, int h, int visible, int cw, int ch)
{
    if (!g_root || !layer) return;
    WWWin *win = ww_get((uintptr_t)hwnd, YES);
    [layer setValue:@((uintptr_t)hwnd) forKey:@"ww_hwnd"];
    CGRect old = win->desk;
    win->layer = layer;
    win->desk = CGRectMake(x, y, w, h);
    if (cw > 0 && ch > 0 && cw <= w && ch <= h) win->client = CGSizeMake(cw, ch);   /* round 8: the resize's non-client frame */
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
    if (g_launch) [g_root bringSubviewToFront:(UIView *)g_launch];   /* round 5: the search results */
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
    /* round 7: while searching with little room above the keyboard, the
     * result chips go under the taskbar or into it (ww_launch_mode) */
    int mode = ww_launch_mode();
    BOOL merged = mode == WW_LAUNCH_CHIPS_IN_DOCK;
    CGFloat width = merged ? maxW : MIN(want, maxW);
    /* round 5: above the software keyboard while the search field has it */
    CGFloat y = ww_chrome_bottom() - WW_DOCK_H;
    if (mode == WW_LAUNCH_CHIPS_ABOVE_KB) y -= WW_CHIP_BAR_H + 8;
    y = MAX(y, s.top);
    d.frame = CGRectMake(round((b.size.width - width) / 2), y, width, WW_DOCK_H);
    d.pill.frame = d.bounds;
    ww_material_fit(d.pill);
    for (UIView *v in @[d.apps, d.steamButton, d.keyboardButton, d.menuButton]) {
        v.alpha = merged ? 0 : 1;   /* the chips take their place while searching */
        v.userInteractionEnabled = !merged;
    }
    d.steamDot.alpha = merged ? 0 : 1;
    CGFloat mid = WW_DOCK_H / 2, x = pad;
    d.search.frame = CGRectMake(x, mid - item / 2, WW_SEARCH_W, item);   /* round 9: a 30-point touch target */
    x += WW_SEARCH_W;
    if (steam) {
        x += gap;
        d.steamButton.frame = CGRectMake(x, mid - item / 2, item, item);
        d.steamIcon.frame = d.steamButton.bounds;   /* round 7: the program icons' box, never larger */
        d.steamDot.frame = CGRectMake(x + (item - 5) / 2, WW_DOCK_DOT_Y, 5, 5);
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
    /* merged: the dock is wider than its items; they keep their places from the left */
    CGFloat tx = (merged ? MIN(want, maxW) : width) - pad - (2 * item + gap);
    d.keyboardButton.frame = CGRectMake(tx, mid - item / 2, item, item);
    d.menuButton.frame = CGRectMake(tx + item + gap, mid - item / 2, item, item);
    ww_launch_layout();
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
        iv.layer.cornerRadius = WW_DOCK_ICON_R;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.clipsToBounds = YES;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake((WW_DOCK_ITEM - 5) / 2, WW_DOCK_DOT_Y, 5, 5)];
        dot.tag = 2;
        dot.layer.cornerRadius = 2.5;
        dot.userInteractionEnabled = NO;
        [b addSubview:dot];
        [b addTarget:d action:@selector(appTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [d.apps addSubview:b];
        [d.appButtons addObject:b];
    }
    /* Round 7: unless pinned (env.MADEIRA_WINDOWED_STEAM = 1), the Steam tile
     * is the first Steam window's own program button, in its place among the
     * others, with the client's icon; no Steam window, no tile. */
    WWWin *steamWin = d.steamAllowed && !d.steamPinned ? ww_steam_window() : nil;
    uintptr_t tile = steamWin ? steamWin->hwnd : 0;
    if (tile != g_steam_tile) {
        if (steamWin)
            ww_log("steam: tile shown (window hwnd=%p \"%s\" exe=%s, as its program button%s)", (void *)steamWin->hwnd,
                   ww_display_title(steamWin).UTF8String, steamWin->exe.UTF8String,
                   g_steam_icon ? ", the client's icon" : steamWin->icon ? ", the window's icon" : "");
        else
            ww_log("steam: tile hidden (no Steam window)");
        g_steam_tile = tile;
    }
    for (NSUInteger i = 0; i < d.appButtons.count; i++) {
        UIButton *b = d.appButtons[i];
        if (i >= list.count) { b.hidden = YES; b.tag = 0; continue; }
        WWWin *w = list[i];
        NSString *name = ww_display_title(w);
        b.hidden = NO;   /* round 5: typing filters the search panel, not the taskbar */
        b.tag = (NSInteger)w->hwnd;
        b.accessibilityLabel = w == steamWin ? [@"Steam: " stringByAppendingString:name] : name;
        UIImageView *iv = [b viewWithTag:1];
        iv.image = (w == steamWin ? g_steam_icon : nil) ?: w->icon ?: ww_letter_icon(w->exe.length ? w->exe : name);
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
    ww_steam_icon_check(NO);   /* round 5: Steam may have been installed meanwhile (at most every 5 s) */
    if (g_launch && !g_launch.hidden) {
        /* the open search panel follows the windows (only when they changed) */
        NSString *sig = nil;
        ww_launch_windows(&sig);
        if (![sig isEqualToString:g_launch_windows_sig]) ww_launch_filter();
    }
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
    ww_log("steam: taskbar tile %s", !g_dock.steamAllowed
           ? "off (env.MADEIRA_WINDOWED_STEAM = 0, or no Swift bridge)"
           : g_dock.steamPinned ? "pinned (env.MADEIRA_WINDOWED_STEAM = 1)"
           : "shown only while a Steam window is open (env.MADEIRA_WINDOWED_STEAM = 1 pins it; Steam starts from the search or the library)");
    ww_steam_icon_check(YES);   /* round 5: the installed client's icon on the tile */
    ww_log("grip: %s; a pinch on a title bar zooms the picture; the grip shows on the active frame for %.0f s after a touch",
           !ww_grip_resizes() ? "zooms the picture (env.MADEIRA_WINDOWED_RESIZE = 0)"
           : ww_resize_free_default() ? "resizes the guest window freely (env.MADEIRA_WINDOWED_RESIZE_FREE = 1; held a moment first or two fingers: aspect locked)"
           : "resizes the guest window, aspect locked (held a moment first or two fingers: free; env.MADEIRA_WINDOWED_RESIZE_FREE = 1 frees it by default; env.MADEIRA_WINDOWED_RESIZE = 0 zooms instead)",
           WW_GRIP_SHOW_S);
    ww_log("title bar: %s", ww_fit_button() ? "minimize, fit, maximize, close (env.MADEIRA_WINDOWED_FIT_BUTTON = 1)"
                                            : "minimize, maximize (full-screen arrows; also a hold on it or a double tap on the title bar), close "
                                              "(env.MADEIRA_WINDOWED_FIT_BUTTON = 1 brings back the fit button)");
    /* round 9: the library's round menu button hides for the whole windowed
     * session (the taskbar and the restore pill have the menu) */
    ww_bridge_call_bool(@"windowedSessionChanged:", YES);
    return root;
}

static void ww_clear_all(void)
{
    for (WWWin *w in g_wins.allValues) [w->frame removeFromSuperview];
    [g_wins removeAllObjects];
    [g_order removeAllObjects];
    g_top = 0;
    g_cascade = 0;
    if (g_max) ww_bridge_call_bool(@"maximizedChanged:", NO);   /* round 7: the round menu button comes back */
    g_max = 0;
    g_steam_tile = 0;
    g_pill.hidden = YES;
    g_dock.hidden = NO;
    if (g_dock.search.isFirstResponder) { g_launch_close_why = "new session"; [g_dock.search resignFirstResponder]; }
    g_launch.hidden = YES;
    g_launch_shown = nil;
    g_launch_windows_sig = nil;
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
    g_pill_moved = NO;   /* round 7: a dragged pill's place is kept for one session */
    /* round 5: the search panel, its items and the Steam icon go with the session */
    [(UIView *)g_launch removeFromSuperview];
    g_launch = nil;
    g_launch_items = nil;
    g_kb_lift = 0;
    g_steam_icon = nil;
    g_steam_icon_path = nil;
    g_steam_icon_checked = 0;
    g_steam_icon_logged = NO;
    g_root = nil;
    ww_bridge_call_bool(@"windowedSessionChanged:", NO);   /* round 9: the round menu button comes back */
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
    for (int i = 0; i < g_nresizes; ) {   /* round 8: one being applied right now finishes on its own */
        if (g_resizes[i].busy) i++;
        else g_resizes[i] = g_resizes[--g_nresizes];
    }
    pthread_mutex_unlock(&g_ww_lock);
    dispatch_async(dispatch_get_main_queue(), ^{ g_resize_mode = -1; g_resize_free = -1; g_fit_button = -1; ww_clear_all(); });
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
    /* round 5: a touch on a window or the background closes the search panel
     * (and gives the keyboard back to the program) */
    if (g_dock && g_dock.search.isFirstResponder) ww_search_release("tap elsewhere");
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
            WWWin *g = w->kind == WW_ATTACHED ? ww_get(w->group, NO) : w;
            if (g) [g->frame touched];   /* round 8: the grip shows for a moment */
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
            [f touched];   /* round 8: the grip shows for a moment */
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
