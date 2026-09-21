/* Winios.h — registration entry point for the iOS user_driver.
 *
 * winios.drv is Madeira's iOS-side replacement for Wine's per-platform
 * display drivers (winemac.drv, winex11.drv, etc.). It plugs into the
 * win32u-unix `__wine_set_user_driver` extension point, providing the
 * minimum-viable pieces of the user_driver_funcs interface that real
 * games need: window lifecycle (CreateWindow → UIView/CAMetalLayer),
 * event pump (PeekMessage → drained UIKit events), display device
 * description, and touch→mouse input.
 *
 * Most slots in the driver struct are intentionally left NULL.
 * __wine_set_user_driver's SET_USER_FUNC fallback fills missing slots
 * with the always-success nulldrv_* stubs in win32u/driver.c, which is
 * fine for everything DXMT-rendered games need (they own the actual
 * graphics surface via CAMetalLayer; we just bridge windowing/input).
 *
 * Lifecycle: load_display_driver() in build/win32u-unix/driver_ios.c
 * calls winios_drv_register() at first user_driver lazy-load, replacing
 * the current null_user_driver registration on iOS.
 */
#ifndef WINIOS_DRV_H
#define WINIOS_DRV_H

#ifdef __cplusplus
extern "C" {
#endif

/* Build the driver-funcs struct and register it via __wine_set_user_driver.
 * Idempotent: safe to call repeatedly; first call wins. */
void winios_drv_register(void);

/* Touch → mouse bridge. Called by Madeira Swift's UIKit gesture
 * handlers; events are queued to a thread-safe ring buffer and drained
 * inside winios_pProcessEvents. (x, y) are in logical 1024×768 pixels
 * — Swift side handles iOS-pixel → logical-pixel scaling. */
void winios_post_touch_down(int x, int y);
void winios_post_touch_move(int x, int y);
void winios_post_touch_up(int x, int y);

/* Key press bridge (VK codes: RETURN=0x0D SPACE=0x20 ESCAPE=0x1B).
 * down=1 press, down=0 release. */
void winios_post_key(int vk, int down);

/* ml663 — the same, with room for KEYEVENTF_* bits the CALLER knows and the
 * driver cannot derive. In practice that is only KEYEVENTF_EXTENDEDKEY (0x1),
 * and only for a key sharing its virtual-key code with a non-extended twin:
 * numpad Enter is VK_RETURN + E0, and nothing about VK_RETURN says which one it
 * was. Every OTHER extended key (arrows, Ins/Del/Home/End/PgUp/PgDn, right
 * ctrl/alt, numpad divide, NumLock) already gets the flag inside
 * driver_ios.c:142, which derives the scan code with MAPVK_VK_TO_VSC_EX and
 * sets E0 whenever that returns 0xE0xx — so pass 0 and nothing changes.
 *
 * winios_post_key(vk, down) is exactly winios_post_key_ex(vk, down, 0). */
void winios_post_key_ex(int vk, int down, unsigned int extra_flags);

/* ml663 — while a hardware mouse is driving RELATIVE motion, advance the drawn
 * cursor arrow by each delta (clamped to the wine desktop) so it tracks the
 * hand in menus. Off by default: the aim stick and touch mouse-look post the
 * same relative events in modes where the game has hidden the cursor, and the
 * per-sample main-queue hop would be pure cost there. */
void winios_cursor_track_relative(int on);

/* ml661 — stuck-input release valve. Queues a key-up for every key (and a
 * button-up for every mouse button) the DRIVER still believes is held. The
 * app calls this whenever a held gesture can have ended without its matching
 * release being posted: scene deactivation, the control overlay being hidden
 * or rotated away under a thumb, a cancelled gesture. Cheap and idempotent —
 * it does nothing when nothing is held. */
void winios_release_all_keys(void);

/* ml665 — the two ring counters the app's mouse-delivery diagnostic needs.
 * `pushed` is every event handed to the ring; `coalesced` is how many of those
 * were folded into an already-queued move because wine had not drained yet.
 * The DIFFERENCE between two samples is the interesting quantity: a large
 * coalesced share means the game is receiving one summed delta per frame
 * instead of a burst, which is what a 30-40 fps game can consume anyway.
 * Both are monotonic and may wrap; subtract with wrapping arithmetic. */
void winios_q_stats(unsigned int *pushed, unsigned int *coalesced);

/* ml661 — driver-side held-key state, for the app's [input] diagnostic: bit i
 * of mask[i>>5] is virtual-key i. Returns the number of keys held. Comparing
 * this against the app's own held-set is what names the failing stage. */
int winios_held_keys(unsigned int mask[8]);

/* S2 desktop compositor placement. Called by the Swift presentation
 * placeholder (MetalBackedView) with its bounds in UIWindow coords —
 * the wine virtual desktop renders aspect-fit inside this frame, like
 * the games' Metal layer, instead of covering the whole phone screen.
 * Safe to call before or after the compositor exists; main-thread
 * dispatch inside. */
void winios_set_compositor_frame(double x, double y, double w, double h);

/* S2 trackpad pointer. (x, y) are ABSOLUTE wine-desktop pixels (the
 * Swift trackpad engine owns the cursor position); flags are raw
 * MOUSEEVENTF_* combos; data carries the wheel delta for
 * MOUSEEVENTF_WHEEL. Events queue to the same ring the touch bridge
 * uses. A MOVE event also repositions the compositor's cursor layer. */
void winios_pointer(int x, int y, unsigned int flags, unsigned int data);

/* Reposition the rendered cursor arrow (desktop px). Usually implied
 * by winios_pointer(MOVE); exposed for initial placement. */
void winios_cursor_move(int x, int y);

/* Desktop mode: convert a point in WINDOW coordinates (points) to a desktop
 * pixel, through the compositor's own letterbox mapping, clamped to the
 * desktop. Returns 0 when there is no compositor (direct launch). */
int winios_desktop_point_from_window(double wx, double wy, int *px, int *py);

/* ml — DIRECT-LAUNCH CURSOR HOSTING (games, not the wine virtual desktop).
 *
 * Desktop mode draws the cursor as a sublayer of the desktop compositor
 * view (winios_ensure_compositor in Winios.m), which only exists in that
 * mode. A directly-launched program has no such view — its presented
 * surface is the app's own game-host CAMetalLayer — so in that mode the
 * cursor is hosted as a sublayer of THAT layer instead. `metal_layer` is
 * `void *` rather than `CAMetalLayer *` so this header — included by
 * build/win32u-unix/driver_ios.c, a plain-C translation unit — never has
 * to import QuartzCore. Swift (MetalBackedView) calls this once, right
 * after registering the same layer with DXMT; pass NULL to clear it. */
void winios_set_game_layer(void *metal_layer);

/* ml1090 — publish the rect (view points) the game surface has been LAID OUT
 * to occupy, as opposed to whatever the presented layer's bounds happen to be.
 * Swift calls this from applyDisplayModeAndLog, the same place it sets
 * MetalHostView's frame and calls the two relayout hooks below, so the drawn
 * cursor, the GDI overlay and Swift's own touch mapping all scale guest pixels
 * by one number — including BEFORE anything has been presented, which is
 * precisely when a directly-launched program is showing its first dialog.
 * Pass 0x0 to fall back to the layer's bounds. */
void winios_set_game_rect(double w, double h);

/* Re-run the guest-pixel -> view-point cursor placement against the
 * CURRENT game layer bounds, without moving the stored guest position.
 * Call after every display-mode/layout apply (rotation, DisplayMode
 * toggle, a GeometryReader resize) so the drawn cursor tracks a moving or
 * resizing game rect even when no new pointer event lands in the same
 * tick. No-op in desktop mode (winios_layout_compositor already owns that
 * relayout there) and before any cursor has ever been positioned. */
void winios_cursor_relayout(void);

/* ml1110 — the DESKTOP-mode twin of the two relayout hooks: re-letterbox the
 * wine desktop inside the compositor's frame against the CURRENT guest
 * resolution. winios_set_compositor_frame only re-lays-out when the FRAME
 * changes (layoutSubviews storms identical frames), so a guest-side
 * ChangeDisplaySettings — which moves the mapping without moving the frame —
 * would otherwise leave the desktop drawn into a sub-rectangle of its own area,
 * with the taskbar, every window layer and the touch mapping scaled by the old
 * size. Call it from the same place as winios_cursor_relayout/
 * winios_overlay_relayout. No-op in a direct launch (no compositor). */
void winios_compositor_relayout(void);

/* ========================================================================
 * ml — THE DIRECT-LAUNCH GDI OVERLAY.
 *
 * Desktop mode composites ordinary GDI windows through winios_ensure_
 * compositor's full-screen UIView; a DIRECT launch has no such view, and its
 * only presented surface is the game's own CAMetalLayer. So every ordinary
 * top-level window a directly-launched program puts up before (or beside) its
 * 3D window — a windowed/fullscreen chooser, a message box, an installer-style
 * dialog, a popup menu or combo dropdown belonging to one — had nowhere to be
 * drawn: no layer, no surface, no present. The program then waited forever for
 * a click that could not be made.
 *
 * The fix is a TRANSPARENT overlay CALayer hosted inside the game layer, built
 * lazily the first time such a window's GDI content actually arrives, with the
 * per-window layers placed by the SAME guest-pixel -> layer-point scale the
 * drawn cursor already uses (see winios_set_game_layer above). That scale is
 * also exactly what MetalBackedView.mapPoint's touch mapping computes, so a
 * tap lands where the dialog is drawn in every pointer mode without a second
 * coordinate system to keep in sync. A CALayer cannot take touches, so the
 * overlay never steals one, and it removes itself once the last GDI window is
 * destroyed.
 *
 * MADEIRA_DIRECT_OVERLAY=0 restores the pre-overlay behaviour exactly.
 * Desktop mode does not go through any of this.
 * ======================================================================== */

/* Re-place the overlay's window layers against the CURRENT game layer bounds,
 * for the same reason (and from the same call site) as winios_cursor_relayout:
 * both are sublayers of the game layer, positioned from its local bounds, and
 * a DisplayMode/rotation/resize apply moves that rect under them. No-op in
 * desktop mode and when no overlay exists. */
void winios_overlay_relayout(void);

/* Record a window that HOSTS the presented Metal layer. Called by
 * IOSDisplayShim.m's direct-launch branch, once per swapchain, with the HWND
 * DXMT asked for a metal view. Such a window's GDI client surface is whatever
 * the program last painted there — for a D3D window, usually black — and
 * drawing it would cover the game image, so the overlay drops that window
 * (and any layer it had already made for it) instead. Desktop mode never
 * calls this: there each window has its own metal SUBLAYER and the GDI
 * content around it is the point. */
void winios_overlay_note_metal_hwnd(void *hwnd);

/* Reached from win32u as weak externs, not from the app — declared here so
 * both sides' signatures are written down in one place.
 *   skip_hwnd:     1 when this window's GDI flush must not be forwarded
 *                  (a metal-hosting window, see above). Called on the GDI
 *                  flush path, so it is lock-free.
 *   window_count:  how many overlay windows are currently VISIBLE. win32u's
 *                  blocking message wait polls the input ring while this is
 *                  non-zero — a modal dialog's message loop sleeps instead of
 *                  peeking, and nothing else would ever drain a touch to it. */
int winios_overlay_skip_hwnd(void *hwnd);
unsigned winios_overlay_window_count(void);

/* ml1110 — WHERE A WINDOW'S BITS SIT INSIDE IT. Called from win32u
 * (driver_ios.c) once per surface CREATION, on a wine thread, with the surface
 * rect in WINDOW-LOCAL pixels. win32u's get_surface_rect() rounds that rect out
 * to a 128px grid — so it is usually LARGER than the window, which is what the
 * old contentsRect clamp existed for — but for a window bigger than the virtual
 * screen it first INTERSECTS it with that screen, which makes it SMALLER: a
 * 1286x1011 window on a 1280x720 desktop gets a 1280x768 surface. Without this
 * the app side drew those bits across the whole window rect, stretching them
 * vertically by a third and inventing the rows win32u never allocated. Both
 * modes: the crop is not direct-launch-specific. */
void winios_window_surface_rect(void *hwnd, int left, int top, int right, int bottom);

/* ml1110 — THE DIRECT-LAUNCH FIT, AND ITS INVERSE.
 *
 * A direct launch has no window manager, so a top-level window larger than the
 * guest desktop is unreachable: it cannot be dragged, resized or Alt+Space'd
 * back on screen. When one exists the overlay maps the UNION of what it draws
 * (always containing the guest desktop, so it never magnifies) into the game
 * rect with one uniform scale, centred — and a touch must invert exactly that,
 * or the pointer lands somewhere the window is not.
 *
 * Returns 1 and fills the guest-pixel source rect while such a fit is active,
 * 0 when the mapping is the plain per-axis guest->game-rect one and
 * MetalBackedView.mapPoint's existing GameSurfaceLayout math already inverts
 * it. Main-thread only, like every other overlay call. MADEIRA_OVERLAY_FIT=0
 * switches the fit off and this always answers 0. */
int winios_overlay_fit_source(double *x, double *y, double *w, double *h);

/* Show/hide the drawn cursor. Normally driven by the driver's pSetCursor
 * hook (NULL cursor -> hide, non-NULL -> show — see winios_drv_set_cursor
 * in driver_ios.c); exposed here too so Swift can force it hidden once a
 * run's wine process has actually exited, or before one has started, so a
 * cursor a game was showing does not survive back into the normal UI. */
void winios_cursor_show(int show);

/* ========================================================================
 * ml668 — THE GAMEPAD SLOT.
 *
 * A gamepad is not an event stream, it is a STATE, and that is the whole
 * reason it does not go through the coalescing ring above. Every other input
 * this file carries is a TRANSITION that Windows must not lose (a key down
 * whose up was dropped leaves the key stuck); XInput is the opposite — a game
 * calls XInputGetState 60 to 1000 times a second and wants the CURRENT
 * deflection of both sticks, and the only thing it can do with a queue of
 * stale samples is throw them away. So the pad is a plain shared struct that
 * the app overwrites and wine reads, with no queue, no lock and no wakeup.
 *
 * WHY A SEQLOCK AND NOT A MUTEX. The reader is a guest thread in the middle
 * of a game's input poll, possibly inside a frame's critical path, and it
 * shares one Mach task with the writer (`WOW64_DESIGN.md` §2 — every Windows
 * process here is a thread in this task, so this really is a plain memory
 * read, no server round trip and no IPC). A mutex there would let a UI-thread
 * write preempted mid-update block a 1000 Hz poll. The seqlock costs the
 * reader two atomic loads and a 16-byte copy in the uncontended case, cannot
 * block, and cannot hand out a torn sample: an odd counter, or a counter that
 * moved across the copy, means "the writer was inside — read it again".
 *
 * PACKET NUMBERS are what a game uses to tell "nothing changed" from "I am
 * polling faster than the pad reports", so the writer bumps `packet` ONLY when
 * some field actually differs. A packet number that ticks on every sample is
 * indistinguishable from noise and defeats the optimisation it exists for.
 * ======================================================================== */

/* Field-for-field an XINPUT_GAMEPAD plus XINPUT_STATE's packet number, in the
 * XInput units (triggers 0-255, sticks signed 16-bit, buttons the
 * XINPUT_GAMEPAD_* bit set). Deliberately NOT the Windows types: this header
 * is included from Swift, and the translation to XINPUT_STATE happens once, in
 * build/win32u-unix/driver_ios.c, where the Windows headers exist.
 *
 * The DEAD ZONE IS NOT APPLIED HERE. XInput's convention is that the
 * application owns it (XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE is a constant a game
 * may ignore or replace), and a driver that pre-clamps makes a game's own
 * deadzone handling a second, wrong clamp on top. The app applies a deadzone
 * only on the paths where IT is the consumer — the on-screen control bindings. */
struct winios_gamepad {
    unsigned int   packet;      /* bumped on every CHANGE, never on a resample */
    unsigned short buttons;     /* XINPUT_GAMEPAD_* */
    unsigned char  left_trigger, right_trigger;    /* 0-255 */
    short          lx, ly, rx, ry;                 /* -32768..32767, y up */
    unsigned char  connected;
    unsigned char  reserved[3];
};

/* XINPUT_GAMEPAD_* — repeated here so the Swift side can name buttons without
 * the Windows headers. Identical values, by definition: they are what the
 * driver hands to the game verbatim. */
#define WINIOS_GAMEPAD_DPAD_UP        0x0001
#define WINIOS_GAMEPAD_DPAD_DOWN      0x0002
#define WINIOS_GAMEPAD_DPAD_LEFT      0x0004
#define WINIOS_GAMEPAD_DPAD_RIGHT     0x0008
#define WINIOS_GAMEPAD_START          0x0010
#define WINIOS_GAMEPAD_BACK           0x0020
#define WINIOS_GAMEPAD_LEFT_THUMB     0x0040
#define WINIOS_GAMEPAD_RIGHT_THUMB    0x0080
#define WINIOS_GAMEPAD_LEFT_SHOULDER  0x0100
#define WINIOS_GAMEPAD_RIGHT_SHOULDER 0x0200
#define WINIOS_GAMEPAD_GUIDE          0x0400
#define WINIOS_GAMEPAD_A              0x1000
#define WINIOS_GAMEPAD_B              0x2000
#define WINIOS_GAMEPAD_X              0x4000
#define WINIOS_GAMEPAD_Y              0x8000

#define WINIOS_GAMEPAD_MAX 4

/* Publish one pad's state. `index` is the XInput user index (0-3); `st` is
 * copied, and its `packet` field is IGNORED — the slot keeps its own counter
 * and bumps it only when a field changed, so the app may resample as often as
 * it likes. Pass connected=0 (or NULL) to mark the slot empty. Safe from any
 * thread; the writer side of the seqlock is itself serialised by a mutex, so
 * two producers cannot interleave. */
void winios_gamepad_set_state(int index, const struct winios_gamepad *st);

/* Read one pad's state. Returns 1 when a pad is connected in that slot (and
 * `out` was filled), 0 otherwise (and `out` is zeroed). Lock-free; this is the
 * call wine's XInputGetState reaches through the win32u syscall, so it is on a
 * game's polling hot path. */
int winios_gamepad_get_state(int index, struct winios_gamepad *out);

/* Diagnostics for the app's 10 s [xinput] line: total published samples and
 * the number of those that actually moved the packet number. */
void winios_gamepad_stats(unsigned int *samples, unsigned int *packets);

#ifdef __cplusplus
}
#endif

#endif

/* ml649: runtime diagnostic switch (defined in ntdll-unix/virtual_ios.c, which
 * links into the same Mach-O). Default OFF = quiet/fast. Toggling live lets
 * loud and quiet be compared inside ONE run, same scene, same thermal state —
 * something two separate builds can never give you. */
void madeira_set_diag_enabled(int on);
int  madeira_get_diag_enabled(void);
