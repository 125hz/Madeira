# Process host (ml1330): running a Wine process in an app extension

Written 2026-10-12, branch `vulkan-stack`, uncommitted. Phase 1 of the plan in
`docs/NUTSEMU_ANALYSIS.md` section 4c: a Wine process that runs in its own iOS app
extension (its own address space, its own jetsam memory limit, its own JIT pool) and
connects to the wineserver in the app, so eventually the full Steam client and its
Chromium web helper can run beside games. This phase delivers the mechanism, honest and
compile-checked, **off by default**, able to run ONE Wine process remotely.

Nothing here runs unless asked:

| cfg line | effect |
|---|---|
| `env.MADEIRA_EXT_PROCESS = 0` | kill switch for the whole feature |
| `env.MADEIRA_EXT_PROCESS_TEST = 1` | at session start, run `cmd.exe /c echo remote-ok` in the extension |

Every step logs an `[ext-proc] ml1330 …` line (app side) or an `[ext-proc] ml1330` NSLog
(extension side, also in the extension's own `Documents/madeira-ext-log.txt`).

## The pieces

- **The extension target `MadeiraProcessHost`** (`app/MadeiraProcessHost/`,
  bundle id `<app>.ProcessHost`, `com.apple.ar.viewer` NSExtension like the JIT helper
  and the donor memory host). Its binary links the **same native static libraries as the
  app** (libntdll_unix.a, libwin32u_unix.a, libwineserver.a, libdxmt_combined.a, the FEX
  host libs, gnutls, ffmpeg) plus `JITAllocator.c` (the debugger JIT pool) and
  `wine_stubs.c`, and the headless app-only symbols in `ProcessHostStubs.c`. It is embedded
  by `.xtool/upstream-build/embed-process-host.py` (modelled on `embed-jit-helper.py` /
  `embed-memory-host.py`) and called from `build-app.sh`.
  - It does NOT compile `FEXBridge.mm`: the guest JIT is the FEX ARM64EC PE module, which
    reads `WINE_IOS_JIT_*` from the extension's **own** environment (competitor patch 0036
    idea — the pool description is never inherited from the parent's Windows environment).
  - `ProcessHost.m` is the principal class. On the NSExtension request it connects back to
    the app's anonymous XPC endpoint, reports its pid, and then, on the app's calls, sets up
    its JIT pool, its environment and the server socket, and runs `__wine_main`.

- **The app side.** `ProcessHostClient.m` (ObjC, so it can carry a file descriptor and a
  Mach send right in xpc dictionaries, as the donor pool does) starts the extension, passes
  over XPC: the prefix/bundle/docs paths, the environment, the command line, the **client
  end of a socketpair** for the wineserver connection, and receives back the extension's pid
  and, when the platform permits it, a **send right to its task port**.
  `MadeiraExtProcess.swift` is the orchestration for the opt-in test: start the extension →
  ask the JIT helper to enable JIT for the extension's pid (`StikJIT.enableJIT(targetPID:)`,
  the helper takes a pid) → prepare the guest → start it. `ProcessHostProtocol.h` is the
  shared XPC contract. The app registers the task port with the wineserver through
  `ios_remote_task_register` (exported from `libwineserver.a`).

- **The wineserver "remote task" process kind** (`build/wineserver/mach_ios.c`). A process
  whose server-side `unix_pid` is not the app's `getpid()` is a remote process. A small,
  mutex-guarded registry maps its unix_pid to the task port the app received:
  - `read_process_memory` / `write_process_memory` use `mach_vm_read_overwrite` /
    `mach_vm_write` on that remote task port. **This is real and direct — the task port is
    all cross-process memory needs** (the competitor routes even memory through the host in
    their patch 0042; a direct task-port read is strictly better).
  - `ios_fill_thread_context` reads the remote thread's guest x86-64 context out of its
    `TEB->ChpeV2CpuAreaInfo->ContextAmd64` **through the remote task port**, so a
    GetThreadContext on a remote thread completes instead of waiting forever. The native
    ARM64 registers (which need a thread port, not a task port) are host-routed — see phase 2.
  - `send_thread_signal`, and the real-suspend hold/release, are host-routed through
    `wine_host_signal_thread` (competitor patch 0040). A remote process never has its
    `trace_data` set to our own task (competitor patch 0039: that killed the app with
    EXC_GUARD when `thread_policy_set` ran on a bogus port), so `apply_thread_priority`
    leaves it alone.
  - `server_ios.c` marks the client side with `ios_ext_process_role()` (the extension sets
    `MADEIRA_EXT_PROCESS_ROLE=host`); `process_ios.c` documents that a remote process is
    started by the app over XPC, not by `spawn_process`/`CreateProcess`.

- **Synchronisation.** The remote process runs **plain server synchronisation**: the app
  builds a clean environment for it with no `MADEIRA_FASTSYNC` and no `inproc-sync` selection,
  so fastsync cells and madsync (both process memory, not coherent across iOS tasks) never
  engage.

## The task-port transfer

The extension attempts `xpc_dictionary_set_mach_send(result, "task", mach_task_self())` and
reports whether it put the right in the reply (`task_ok`). The app reads it with
`xpc_dictionary_copy_mach_send`. **On iOS a process's own task port may be guarded and the
send refused** (the competitor's whole patch set 0039/0040/0042 exists because they could not
send it). When the right does not arrive, the app logs `task port no …` and the wineserver
falls back to the host-routed path for thread/memory ops. That host path is a documented
phase-1 stub: `wine_host_signal_thread` is not yet exported by the app, so thread control of
a remote process fails with a logged line rather than acting on a wrong port. **Whether the
task port can be sent at all on device is the first thing a device run must answer.**

## What works (compile/link level) and what is unverified

Compiled in WSL against the iOS 26.5 SDK: `build/wineserver/mach_ios.c`,
`build/ntdll-unix/server_ios.c`, `build/ntdll-unix/process_ios.c` (the C changes);
`app/MadeiraProcessHost/ProcessHost.m`, `ProcessHostStubs.c`, `app/Madeira/ProcessHostClient.m`
(ObjC, `-fsyntax-only`); `app/Madeira/MadeiraExtProcess.swift` (Swift type-check with stubs).
The full `build-app.sh` link-and-embed (which proves the extension binary actually links the
native libraries and embeds) is run by the owner.

Unverified (device, or a full build):
- Whether an app extension's own task port can be sent over XPC on this OS.
- Whether the JIT helper extension can attach a debugger to, and grant a JIT pool for,
  **another** extension (the process host). Both have `get-task-allow`; this is untried.
- Whether `__wine_main` actually boots a guest inside the extension (pool placement here is
  simplified vs. `StikJITHelper.allocatePool`; FEX host-side init is not called — only the
  PE ARM64EC module path, which reads `WINE_IOS_JIT_*`).
- The host-routed thread-control path (`wine_host_signal_thread`) is a stub.

## Phase 2 (not in this change)

- **Web helper placement.** Steam's Chromium web helper in its own extension; its 16 GB
  PartitionAlloc pools need the host-named sparse slots (competitor patch 0038) and the
  preload-area address-space reservation (patch 0037): in an extension, fixed mappings above
  `0x7000000000` are refused, so the host must reserve the large area and hand it over. The
  ml1310 `[ext-probe]` result decides the exact numbers.
- **IOSurface frames.** Phase 1 is headless — the remote process's windows live in the
  wineserver and its GDI surfaces are not drawn. A visible remote window must send its frames
  back to the app's compositor as an XPC-transferable `IOSurfaceRef`.
- **A 64 GB guest window inside a ~6 GB anywhere cap** via fixed mappings (the device probe
  found `anywhere_max ≈ 6 GB` but fixed mappings at `0x7000000000` / `0x14c000000` accepted),
  i.e. reserve the window with `VM_FLAGS_FIXED` rather than one big ANYWHERE reservation.
- **Cross-process thread control without a task port**: a real host-routed
  `wine_host_signal_thread` / per-thread registration so suspend, native GetThreadContext and
  SetThreadContext work on a remote process (competitor patches 0040/0065), and routing a
  guest `CreateProcess` to spawn a remote extension (patch 0031).
