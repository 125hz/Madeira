#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Start Wine process initialization on a background thread.
// Must be called AFTER wineserver is running.
// prefix_path: path to the Wine prefix directory
// Returns 0 on success, -1 on error.
int wine_process_start(const char *prefix_path);

// Check if Wine process is running
int wine_process_is_running(void);
// ml1900: prepare the existing prefix template without starting Wine or JIT.
// Caller must ensure neither a Wine session nor wineserver is active.
void madeira_seed_prefix_if_needed(const char *prefix_path);
// ml1850: one session's Dock exit, including a zero exit code. Nonzero = known.
int wine_dock_exit_status(int *status);
void wine_dock_exit_reset(void);
int wine_crash_exit_status(uint32_t *status);
// ml2000: programs (not launcher/helper images) started / still running this session.
int wine_programs_started(void);
int wine_programs_live(void);
void wine_programs_reset(void);

// Steam S0 net-test VPN gate: write C:\madeira-continue.flag into the
// prefix's drive_c so the paused winhttp-test.exe resumes to the Steam
// stage. Called by the "Continue Net Test" UI button after the user has
// detached the JIT debugger and switched VPNs. Returns 0 on success.
int madeira_write_continue_flag(void);

#ifdef __cplusplus
}
#endif
