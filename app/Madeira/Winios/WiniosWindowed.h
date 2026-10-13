/* WiniosWindowed.h — ml1300 windowed mode, the internal interface between the
 * desktop compositor (Winios.m) and the window manager (WiniosWindowed.m).
 *
 * Windowed mode (madeira.cfg `windowed = 1`, or env.MADEIRA_WINDOWED = 1; a
 * desktop session only) draws every top-level Wine window in a frame of its
 * own: a title bar with the window text and minimize / fullscreen / close
 * buttons, draggable, tapped to the front, and a taskbar along the bottom with
 * one button per program window plus the keyboard and the in-game menu. Off,
 * nothing here runs and the desktop compositor lays the guest desktop out as
 * before. See docs/WINDOWED.md. */
#ifndef WINIOS_WINDOWED_H
#define WINIOS_WINDOWED_H

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

/* Mirrors struct winios_windowed_info in build/win32u-unix/driver_ios.c. */
struct winios_windowed_info {
    unsigned int kind;              /* 0 child / gone, 1 the desktop window, 2 top-level */
    unsigned int style, exstyle;
    unsigned int pid;
    unsigned long long owner;       /* GW_OWNER */
    unsigned long long root_owner;  /* GA_ROOTOWNER */
    char cls[64];
    char title[192];                /* UTF-8 */
};

/* Any thread. 1 while this session runs in windowed mode. Resolved once per
 * session (winios_windowed_reset forgets it). Also declared in Winios.h. */
int winios_windowed_active(void);

/* Session start (any thread): forget the resolved switch and every window. */
void winios_windowed_reset(void);

/* Main thread. The compositor's root view for a windowed desktop session: it
 * passes touches through to the game view except on window chrome and the
 * taskbar. */
UIView *winios_windowed_make_root(CGRect frame);

/* Main thread. The compositor view went away (session ended / changed). */
void winios_windowed_teardown(void);

/* Wine thread, from winios_window_frame (the window's own thread): reads the
 * window's text, styles, owner, program and icon for the frame and taskbar. */
void winios_windowed_note_window_wine(void *hwnd);

/* Main thread, after Winios.m set the window layer's frame (desktop-fit
 * coordinates) and visibility: moves the layer into its frame. */
void winios_windowed_place(void *hwnd, CALayer *layer, int x, int y, int w, int h, int visible);

/* Main thread: the window is gone. */
void winios_windowed_forget(void *hwnd);

/* Main thread: the compositor was laid out again (rotation, mode change). */
void winios_windowed_relayout(void);

/* Main thread. A point in app-window coordinates to desktop pixels through the
 * frame under it, which also becomes the target of the next pointer events.
 * Returns 0 over the background (no window): those events are dropped. */
int winios_windowed_map_point(double wx, double wy, int *px, int *py);

/* Main thread. Desktop pixels to a point in the compositor view, through the
 * frame the pointer is in, and that frame's points per pixel. */
int winios_windowed_cursor_point(double px, double py, CGPoint *pt, CGFloat *k);

/* Any thread, as a mouse event is queued: the top-level window it goes to.
 * *drop is set for an absolute event over the background. */
void *winios_windowed_event_target(int x, int y, unsigned int flags, int *drop);

/* Wine thread, from pProcessEvents: posts title bar commands, activates a
 * window the user tapped (on its own thread), follows the guest's foreground
 * window and refreshes window text about once a second. */
void winios_windowed_pump_wine(void);

/* Main thread. 1 while a window is maximized (the whole screen, no title bar,
 * taskbar hidden); unmaximize brings the windows back (any thread). Also
 * declared in Winios.h for the library's in-game menu. */
int winios_windowed_maximized(void);
void winios_windowed_unmaximize(void);

#endif
