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

// Session exit report (the library front end). ntdll calls
// wine_launched_process_did_exit() when the program the app launched (the
// session's initial process) exits; other processes are not reported.
// Returns 1 and fills *status when that program ended with an NTSTATUS error
// (0xC...) since the last reset.
void wine_launched_process_did_exit(int status);
int wine_crash_exit_status(uint32_t *status);
// Forget the recorded status; called when a session begins.
void wine_exit_status_reset(void);

// Steam S0 net-test VPN gate: write C:\madeira-continue.flag into the
// prefix's drive_c so the paused winhttp-test.exe resumes to the Steam
// stage. Called by the "Continue Net Test" UI button after the user has
// detached the JIT debugger and switched VPNs. Returns 0 on success.
int madeira_write_continue_flag(void);

// Extract the bundled prefix template if the prefix is new (idempotent).
// Madeira Dock's component setup calls it before writing Steam's registry keys.
void madeira_seed_prefix_if_needed(const char *prefix_path);

// ml1350 in-session launcher (build/ntdll-unix/process_ios.c, docs/SESSION_LAUNCH.md).
// madeira_session_launch_request queues "C:\path\program.exe args" (UTF-8; the
// working folder may be NULL: the program's own) from any thread and returns
// its id, or 0 with the reason in `reason`. A Wine thread of the running
// session starts it (the desktop window's thread: explorer's shell in a desktop
// session) and reports through the callback, on that Wine thread: state 1 when
// a thread took it (detail names the parent), state 2 when done (status is the
// NTSTATUS, 0 = started; pid then set). Flags: 1 = start services.exe first when
// none runs. env.MADEIRA_SESSION_LAUNCH=0 refuses every request.
typedef void (*madeira_session_launch_cb)(unsigned int id, unsigned int state, unsigned int status,
                                          unsigned int pid, const char *detail);
void madeira_session_launch_set_callback(madeira_session_launch_cb cb);
unsigned int madeira_session_launch_request(const char *cmdline_utf8, const char *cwd_utf8,
                                            unsigned int flags, char *reason, int reason_len);
// Drops what is still queued (WineProcessBridge.m, when the session ends).
void madeira_session_launch_fail_all(const char *why);

#ifdef __cplusplus
}
#endif
