// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host. The handful of app-only symbols a HEADLESS Wine client needs
// from the native libraries, which are normally defined in the app's ObjC sources
// (WineProcessBridge.m, Winios.m) that pull in UIKit/Metal/AVFoundation. The process
// host runs no UI and presents no frames (phase 1), so these are the real exit-path
// state plus no-op display hooks. Symbols the win32u driver declares __attribute__((weak))
// (winios_window_frame, winios_direct_cursor_*) are intentionally NOT defined here;
// they resolve to 0 and the driver skips them.

#include <setjmp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "../Madeira/Winios/WiniosGamepad.h"
#include <libkern/OSCacheControl.h>

// libntdll_unix.a's NtFlushInstructionCache references __clear_cache, which no archive in
// this standalone link provides (the app build gets it from the Xcode toolchain). On Darwin
// arm64 the correct instruction-cache flush is sys_icache_invalidate, so define it here with
// the real implementation rather than a no-op.
void __clear_cache(void *begin, void *end) {
    if (end > begin) sys_icache_invalidate(begin, (size_t)((char *)end - (char *)begin));
}

// The exit path (build/ntdll-unix/shims/wine_ios_exit.h): exit() inside the Wine Unix
// side longjmps here, so ProcessHost.m's ph_wine_thread can catch the guest's exit
// instead of the process dying. One jmpbuf per Wine "process" thread.
_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;

// The wineserver's fatal_error (normally WineServerBridge.m). We do not run the server
// here, but libntdll_unix.a's loader calls it; terminate just this thread, as the app does.
__attribute__((noreturn)) void fatal_error(const char *err, ...) {
    va_list ap; char buf[1024];
    va_start(ap, err); vsnprintf(buf, sizeof buf, err, ap); va_end(ap);
    fprintf(stderr, "[ext-proc] ml1330 FATAL: %s\n", buf);
    extern void madeira_process_host_did_exit(int);
    madeira_process_host_did_exit(1);
    pthread_exit(NULL);
}

// The wineserver event loop's stop flag (normally WineServerBridge.m). No server here.
volatile int g_wineserver_should_stop = 0;

// process_ios.c logs child-start phases through this; headless, so it is a no-op.
void winios_phase(const char *name) { (void)name; }

// win32u blits guest GDI bits through this when drawing to a window; headless, so
// nothing is drawn (frames over IOSurface are phase 2).
void winios_dump_srcbits(const void *bits, int w, int h, int stride) {
    (void)bits; (void)w; (void)h; (void)stride;
}

// The remaining app-only symbols the Wine client libraries reference, which the headless
// process host does not need. C links by name only, so these minimal definitions satisfy
// the references; nothing here is ever usefully called in phase 1 (no windows, no cursor,
// no controller routed to the remote process). The session-exit reporter is likewise a no-op.
extern void madeira_process_host_did_exit(int status);
void wine_launched_process_did_exit(int status) { madeira_process_host_did_exit(status); }

// The display / input / GL driver surface that libwin32u_unix.a references, normally
// provided by Winios.m / WiniosGL.m / WiniosGamepad.c / WiniosWindowed.m in the app. The
// process host is headless (phase 1): its windows live in the wineserver, nothing is
// presented, no cursor, no controller is routed to the remote process. These are no-ops.
// (C links by name only, so the simple signatures below satisfy every reference; real
// presentation to the app's compositor over IOSurface is phase 2.)
typedef void *HWND;
typedef void *HCURSOR;
typedef struct { int32_t left,top,right,bottom; } PHRect;
struct window_rects { PHRect window,client,visible; };
struct window_surface;
extern void madeira_process_host_window_frame(void *,int,int,int,int,int,int,int,int,int);
extern void madeira_process_host_window_destroy(void *);
void winios_window_frame(HWND hwnd,int x,int y,int w,int h,int visible,int cx,int cy,int cw,int ch) {
    madeira_process_host_window_frame(hwnd,x,y,w,h,visible,cx,cy,cw,ch);
}
void winios_pSetCursor(HWND hwnd,HCURSOR cursor) { (void)hwnd;(void)cursor; }
void winios_pDestroyCursorIcon(HCURSOR cursor) { (void)cursor; }
unsigned int winios_pShowWindow(HWND hwnd,int cmd,PHRect *rect,unsigned int swp) {
    (void)hwnd;(void)cmd;(void)rect;(void)swp; return ~0u;
}
void winios_pWindowPosChanged(HWND hwnd,HWND after,HWND owner,unsigned int swp,
                             const struct window_rects *rects,struct window_surface *surface) {
    (void)hwnd;(void)after;(void)owner;(void)swp;(void)rects;(void)surface;
}
int winios_pCreateWindow(HWND hwnd) {
    static unsigned int logs;
    if(__atomic_fetch_add(&logs,1,__ATOMIC_RELAXED)<48)
        fprintf(stderr,"[ext-proc] ml1331 window created hwnd=%p (presentation deferred)\n",hwnd);
    return 1;
}
void winios_pDestroyWindow(HWND hwnd) { madeira_process_host_window_destroy(hwnd); }
int winios_pProcessEvents(unsigned int mask) { (void)mask; return 0; }
void winios_direct_cursor_pos(int x,int y) { (void)x;(void)y; }
int winios_direct_cursor_wanted(void) { return 0; }
void winios_direct_cursor_set(unsigned int id,int w,int h,int hx,int hy,const void *bits) { (void)id;(void)w;(void)h;(void)hx;(void)hy;(void)bits; }
void winios_direct_cursor_show(int show) { (void)show; }
void winios_cursor_set(unsigned int id,int w,int h,int hx,int hy,const void *bits) { (void)id;(void)w;(void)h;(void)hx;(void)hy;(void)bits; }
void winios_cursor_show(int show) { (void)show; }
void winios_display_mode_changed(int w,int h) { (void)w;(void)h; }
int winios_surface_present(HWND hwnd,int x,int y,int w,int h,int sw,int sh,int stride,const void *bits) {
    (void)hwnd;(void)x;(void)y;(void)w;(void)h;(void)sw;(void)sh;(void)stride;(void)bits; return 1;
}
int winios_windowed_active(void) { return 0; }
int winios_hidpad_get_state(struct winios_hidpad *out) { if(out)memset(out,0,sizeof(*out)); return 0; }
void winios_hidpad_set_output(const struct winios_hidpad_output *out) { (void)out; }
int winios_gamepad_get_state(int index,struct winios_gamepad *out) { (void)index;if(out)memset(out,0,sizeof(*out)); return 0; }
int winios_gamepad_get_battery(int index,struct winios_gamepad_battery *out) { (void)index;if(out)memset(out,0,sizeof(*out)); return 0; }
int winios_gamepad_rumble_caps(void) { return 0; }
void winios_gamepad_set_vibration(int index,uint16_t left,uint16_t right) { (void)index;(void)left;(void)right; }

// The GL / Zink / Vulkan presentation surface (WiniosGL.m, build/win32u-unix/vulkan_ios.c),
// likewise headless no-ops here.
void *madeira_gl_context_create(void *share,int *major) { (void)share; if(major)*major=0; return NULL; }
void madeira_gl_context_release(void *context) { (void)context; }
int madeira_gl_make_current(void *context) { (void)context; return 0; }
int madeira_gl_present(void **state,void *hwnd,unsigned int fbo,int w,int h) { (void)state;(void)hwnd;(void)fbo;(void)w;(void)h; return 0; }
void madeira_gl_present_release(void *state) { (void)state; }
void madeira_gl_wait_active(void) {}
void *madeira_vulkan_layer_for_hwnd(void *hwnd) { (void)hwnd; return NULL; }
void *madeira_zink_target_bind(void **state,void *hwnd,int w,int h,int *rows) { (void)state;(void)hwnd;(void)w;(void)h;if(rows)*rows=0;return NULL; }
void *madeira_zink_target_present(void **state,void *hwnd,int *rows) { (void)state;(void)hwnd;if(rows)*rows=0;return NULL; }
void madeira_zink_target_release(void *state) { (void)state; }
