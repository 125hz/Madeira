#import "JITAllocator.h"
#import "FEXBridge.h"
#import "WineServerBridge.h"
#import "WineProcessBridge.h"
#import "IOSDisplayShim.h"
#import "Winios/Winios.h"

// Wine file-based logging (server_ios.c)
void wine_log_set_file(const char *path);

// UI log callback (wine_log_ios.c) — forwards C logs to Swift UI
typedef void (*wine_ui_log_callback_t)(const char *message);
void wine_set_ui_log_callback(wine_ui_log_callback_t cb);

// DXMT present counter (winemetal_unix.c) — for SwiftUI FPS overlay
#include <stdint.h>
uint64_t madeira_get_present_count(void);

// DXMT vsync-lock toggle (winemetal_unix.c) — 1 = pace presents to 60
// via afterMinimumDuration, 0 = free-run to display max (120 ProMotion,
// requires CADisableMinimumFrameDurationOnPhone in Info.plist).
// Read per present; safe to flip live mid-game.
void madeira_set_vsync_locked(int locked);
int madeira_get_vsync_locked(void);

// ml1050: what the PANEL can do and what we asked it for, published from
// Swift (only UIKit knows) so the native [frame] line can print the
// quantisation grid every present snaps to. panel_hz = the display's own
// maximum, intent_hz = the CADisplayLink rate currently requested (0 = no
// intent armed). Both are diagnostics; nothing branches on them.
void madeira_set_display_max_fps(int panel_hz, int intent_hz);

/* ml526: startup phase timeline (Winios.m) */
void winios_phase(const char *name);
