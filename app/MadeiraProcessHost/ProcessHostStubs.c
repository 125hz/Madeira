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
void wine_launched_process_did_exit(int status) { (void)status; }

// The display / input / GL driver surface that libwin32u_unix.a references, normally
// provided by Winios.m / WiniosGL.m / WiniosGamepad.c / WiniosWindowed.m in the app. The
// process host is headless (phase 1): its windows live in the wineserver, nothing is
// presented, no cursor, no controller is routed to the remote process. These are no-ops.
// (C links by name only, so the simple signatures below satisfy every reference; real
// presentation to the app's compositor over IOSurface is phase 2.)
void winios_window_frame(void) {}
void winios_pSetCursor(void) {}
void winios_pDestroyCursorIcon(void) {}
unsigned int winios_pShowWindow(void) { return 0; }
void winios_pWindowPosChanged(void) {}
long winios_pCreateWindow(void) { return 0; }
void winios_pDestroyWindow(void) {}
long winios_pProcessEvents(void) { return 0; }
void winios_direct_cursor_pos(int x, int y) { (void)x; (void)y; }
int winios_direct_cursor_wanted(void) { return 0; }
void winios_direct_cursor_set(void) {}
void winios_direct_cursor_show(void) {}
void winios_cursor_set(void) {}
void winios_cursor_show(void) {}
void winios_display_mode_changed(void) {}
void winios_surface_present(void) {}
int winios_windowed_active(void) { return 0; }
int winios_hidpad_get_state(void) { return 0; }
void winios_hidpad_set_output(void) {}
long winios_gamepad_get_state(void) { return 0; }
long winios_gamepad_get_battery(void) { return 0; }
long winios_gamepad_rumble_caps(void) { return 0; }
void winios_gamepad_set_vibration(void) {}

// The GL / Zink / Vulkan presentation surface (WiniosGL.m, build/win32u-unix/vulkan_ios.c),
// likewise headless no-ops here.
long madeira_gl_context_create(void) { return 0; }
void madeira_gl_context_release(void) {}
void madeira_gl_make_current(void) {}
void madeira_gl_present(void) {}
void madeira_gl_present_release(void) {}
void madeira_gl_wait_active(void) {}
long madeira_vulkan_layer_for_hwnd(void) { return 0; }
long madeira_zink_target_bind(void) { return 0; }
void madeira_zink_target_present(void) {}
void madeira_zink_target_release(void) {}
