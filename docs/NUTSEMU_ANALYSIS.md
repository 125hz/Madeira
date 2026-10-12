# NutsEmu build 1382: what its published source shows, compared with Madeira

Written 2026-10-12. Sources read: NutsEmu's LGPL release for build 1382 (Wine 11.18
plus 92 patches, the iOS compatibility layer and build scripts; vkd3d-proton commit
750061ae plus 3 patches; build and relinking notes; DXMT relink objects). The release
is untrusted downloaded data: nothing in it was executed. The Madeira side was checked
on branch `vulkan-stack` (= `test/opengl-1010`, 4b0cfeb1), plus `opengl-donor-local`
for the memory-host extension. Each "Madeira" verdict below names the file or the grep
that backs it.

What the release does **not** contain, so nothing here can say how it works: the host
app (Swift/ObjC), the display driver (`winenuts`), the XInput DLL, the audio driver,
FEX and its patches (the Wine patches reference FEX patches 0010, 0012, 0015), DXMT
source and its patches (only `winemetal.dll` objects), the Mesa/KosmicKrisp build,
the Steam integration and "NutsSync" tests. How the app obtains JIT permission is not
in the source.

Game names that appear in the patch descriptions are left out here (project rule);
engines and Steam/Chromium are named where the mechanism depends on them.

Baseline and work in progress: the verdicts describe the committed tree (4b0cfeb1 and
the Wine submodule's HEAD). While this was being written, uncommitted changes
appeared in the working tree that implement some of the items below: XInput battery
(ml2170: `WiniosGamepad.h`, `GamepadInput.swift`, `driver_ios.c`,
`wine/dlls/xinput1_3/main.c`), Windows.Gaming.Input pads from the host
(`wine/dlls/windows.gaming.input/*`, `wine/tools/tests/wgi-host-pads.c`), win32u's
Vulkan layer (`build/win32u-unix/vulkan_ios.c`, with a 0083-style re-entrancy guard in
`d3dkmt_ios.c`), a KosmicKrisp build (`build/mesa-ios/build-kosmickrisp.sh`,
`docs/KOSMICKRISP.md`) and a vkd3d-proton build carrying NutsEmu's three patches
(`build/vkd3d-proton/`). Those rows say "in progress (uncommitted)".

Version gap: Madeira's Wine submodule is 11.4 (`wine/VERSION`); NutsEmu is on 11.18.
Several NutsEmu fixes are for code that only exists after 11.4 (noted per patch).

---

## 1. Their architecture in one page

### 1.1 Process model

- **Server in the app.** `wineserver` is linked as `libwineserver.dylib`; the app calls
  `nutsemu_wineserver_main()` (`platform/wineserver-entry.c`) on a thread. Same idea as
  Madeira's `build/wineserver/main_ios.c` (`wineserver_main` on a thread).
- **One Wine instance per Windows process ("D17").** Unlike Madeira's pseudo-processes
  (one statically linked ntdll unix side, per-PEB state), NutsEmu loads a separate
  *copy* of Wine's Unix libraries for every Windows process: `lib/wine<N>/aarch64-unix/`
  ("Wine sets", RELINKING.md step 3). Each copy has its own globals (view tree, free
  ranges, signal state, `wow64_window`), so Wine's single-process assumptions hold per
  instance. Costs: N copies of `ntdll.so`/`win32u.so`; dyld path problems (0061, 0062);
  process-wide signal handlers must be demultiplexed (0030); the shared user data page
  is mapped once and shared (0030).
- **Host hooks by symbol lookup.** Every hook is optional, found with
  `dlsym(RTLD_DEFAULT, "wine_host_*")`, so the same Wine builds and runs without the
  host: `wine_host_exec_alloc/_writable/_release`, `wine_host_jit_alloc`,
  `wine_host_process_exit`, `wine_host_sigaction`, `wine_host_spawn_process`,
  `wine_host_extra_args`, `wine_host_fixed_image_slot`, `wine_host_image_base`,
  `wine_host_foreign_image`, `wine_host_signal_thread`,
  `wine_host_read_process_memory`/`_write_process_memory`. Each instance exports
  `__wine_host_release_all_memory`, `__wine_host_owns_address`, `__wine_host_image_base`
  back to the host. The presence of `wine_host_process_exit` doubles as "running inside
  a host app" (0035, 0041).
- **Spawning.** `CreateProcess` ends in `spawn_process()`, which hands
  `(argv, socketfd)` to `wine_host_spawn_process` (0031). The host starts another
  instance in the app process (D17) or in an **iOS app extension process (D18)**. Steam's
  client and its web helper run in extension processes; games run in the app.
- **Extension processes (D18), bridged through the host.** The server stays in the main
  app; the instance in the extension talks to it over the copied server socket. What
  the server cannot do across iOS processes goes through the host:
  no task port for a remote process (0039), thread signals for suspend/context
  (0040), `read/write_process_memory` (0042), "foreign code" lookups (0065). Per-iOS-
  process settings come from the Unix environment, not the inherited Windows one:
  `NUTSEMU_JIT_POOL` (0036), `NUTSEMU_FEX_SMALL_LOOKUP` (0064). In an extension, fixed
  mappings above 0x7000000000 are refused, so the host reserves a large area and hands
  it over as a preload area (0037); Chromium's 16 GB pools go into host-named sparse
  slots (`NUTSEMU_POOL_SLOTS`, 0038). The web helper runs single-process without JIT
  (`wine_host_extra_args`, 0034). Synchronization is shared memory passed by fd, so it
  works across iOS processes (0087). The developer's public statement adds that each
  extension has its own memory limit and its own 64 GB address space.
- **Process lifetime.** Exit paths go through `wine_host_process_exit` (0011, 0032:
  `#define exit(status) instance_exit(status)` for all of ntdll's Unix side); the
  server never signals its own pid (0012); the host releases an exited instance's
  memory wholesale (0024); stack overflow ends the process (0058); the UIKit main thread
  is never adopted (0035); there is no explorer (0041, 0052) and wineboot applies its
  inf sections in-process when it cannot start rundll32 (0013).

### 1.2 JIT and executable memory

- One pool per iOS process, "set up once at start" (developer). Its description reaches
  FEX as `NUTSEMU_JIT_POOL` = begin, size, write-alias offset (0036).
- **Native images live in the pool** (0005). `map_image_view` asks `wine_host_exec_alloc`
  for ARM64 and hybrid (ARM64X/ARM64EC) images and creates the view *at the pool
  address*: the image's VA is executable directly, so nothing is copied and no PC is
  redirected. Headers and sections are read with `pread` through the writable alias,
  relocations and ARM64X fixups are written through it, `STATUS_IMAGE_NOT_AT_BASE` is
  treated as success because the image was relocated while mapping.
- **JIT code buffers** (FEX) come from the pool when FEX allocates with
  `MEM_EXTENDED_PARAMETER_EC_CODE` (0009), also in non-ARM64EC processes such as FEX's
  WoW64 side (0069).
- `mprotect_exec` (0009): with host exec memory, only pool memory may be executable
  and pool memory is never made writable; any other PROT_EXEC request is dropped
  (x64 code is only read by FEX). `force_exec_prot` is ignored there (0078).
- `NtFlushInstructionCache` uses `sys_icache_invalidate` (0010). The ARM64EC code map
  covers 512 GB and `RtlIsEcCode` is bounded (0079).

### 1.3 Address space

- Search starts above `__PAGEZERO` (0018). Every `mach_vm_map` refusal means "try the
  next spot", including `KERN_INVALID_ADDRESS` inside the map; max protection is RW only
  (0019). The top is found by a binary search between powers of two (0020: 0xfc0000000
  = 63 GB on their test device, the power-of-two probe gave 32 GB).
- KUSER_SHARED_DATA is moved to a fixed host address at build time
  (`WINE_USER_SHARED_DATA_ADDRESS=0x14c000000`, used by every Wine module, PE and Unix,
  0004); program reads of the canonical 0x7ffe0000 are emulated in the SEGV handler
  (integer loads including LDAR/LDAPR/LDAPUR, 0025).
- Chromium/V8 address-space packing on a 63 GB map: reservation hints beyond the host
  limit are placed below it keeping their offset modulo the size (0028), alignment kept
  up to 64 GB with separate lanes for 16 GB pools (0033), a 16 GB "cage zone" for the
  8 GB cages, sparse pools with only their head backed (0038), lazy placeholders (0093).
- 16 KB host pages: decommitted 4 KB pages sharing a host page with live pages are
  zeroed (0092). Copy-on-write image pages report PAGE_READWRITE once "written" (0029).
- Fixed-base executables: a relocatable EXE goes top-down, leaving 0x140000000 to EXEs
  without relocations; one that cannot move waits up to 20 s for its base (0059), or
  asks the host about a slot it keeps mapped (0060).
- Physical memory reported = app footprint + `os_proc_available_memory()` (0081).

### 1.4 32-bit programs

First a stopgap (0048: a 32-bit EXE outside the system directories starts as a 64-bit
EXE of the same name in system32, used for Steam's service). Then real WoW64 (D19):

- A 4 GB window aligned to 4 GB per 32-bit process (0070), reserved when the main
  module is 32-bit. A host address truncated to 32 bits is the guest address; the guest
  address ORed with the window base is the host address. Limits below 4 GB
  (`zero_bits`, `user_space_wow_limit`, TEB blocks) mean "inside the window", everything
  else is kept out of it; 32-bit images go at their preferred base inside it, so
  relocations and `PtrToUlong` need nothing.
- `wow64.dll` redefines `ULongToPtr`/`UlongToPtr` to OR in the window (values below
  64 KB stay values); real non-pointers are cast explicitly (0070). `wow64win`
  converts message parameters and the one/two-parameter user calls whose argument is an
  address (0071, 0075). `opengl32`'s generated WoW64 thunks tell handles, integers,
  pointers and "pointer or buffer offset" apart by the current buffer binding (0074).
- KUSD is mapped at window+0x7ffe0000 and also at window+0x4c000000 (the truncated
  build-time address Wine's own 32-bit DLLs were compiled with).
- FEX's side is in FEX patches 0012/0015 (not published here). DXMT ships an i386
  `winemetal.dll`.

### 1.5 TEB and x18

iOS zeroes x18. NutsEmu builds Wine's PE modules, vkd3d-proton and FEX with
`WINE_TEB_TSD_SLOT=300`: `NtCurrentTeb()` reads TPIDRRO_EL0 and the pthread TSD slot
300 (`include/winnt.h`, `include/wine/asm.h __ASM_LOAD_TEB`, every syscall/unix-call
dispatcher), and the Unix side sets that slot with `pthread_setspecific(300, teb)`
(0008). Code compiled elsewhere (CRT start-up, compiler TLS, native ARM64 programs)
still reads `[x18,#imm]`; the SEGV handler emulates unsigned-immediate LDR/STR based
on x18 against the real TEB (0016). Instruction faults skip that decoding (0085).

### 1.6 Synchronization

NutsSync (0087, `include/wine/nutssync.h`, 702 lines, header-only): Wine 11.18's
in-process synchronization (built for Linux ntsync) runs on a shared-memory
implementation on Apple systems. The server creates one region (a `mkstemp` file in
`$TMPDIR`, unlinked) and hands its fd to every process as the "inproc device";
objects are numbers (generation << 17 | slot+1), 131072 objects, 8192 waiters,
64 handles per wait. One lock word for everything, `os_sync_wait_on_address` with
`OS_SYNC_WAIT_ON_ADDRESS_SHARED` for the lock and for each waiter's own word, signals
blocked while the lock is held, a dead holder (other process, `kill(pid,0)` = ESRCH)
is taken over after 1 s. Abandoned mutexes and a dead thread's waits are cleaned
up. `NUTSEMU_SYNC=0` turns it off. A zero-length alertable sleep with no APC pending
yields locally. 0088 adds server request profiling; 0090 makes a thread that yields
32 times within 100 µs sleep 50 µs per yield.

### 1.7 Graphics

- **OpenGL:** Wine 11.18's own EGL-based WGL path in win32u, with Mesa's `libEGL` and
  Zink on MoltenVK (`libvulkan.1.dylib`), configured `--with-opengl` and
  `EGL_LIBS=-lEGL` from the Mesa build. 0073 fixes an 11.18 bug that dropped every
  extension of a GL 2.1 context (Zink on MoltenVK is 2.1); 0074 is the 32-bit thunks.
  D3D9 runs on wined3d over that GL (developer statement; no wined3d patch exists, so
  wined3d is unmodified).
- **Vulkan:** winevulkan is built (`--with-vulkan`). Wine's own Vulkan loads
  `libvulkan_nuts.dylib`, a "switchboard" (KosmicKrisp by default,
  `NUTSEMU_VULKAN_DRIVER=moltenvk` for MoltenVK), while `libvulkan.1.dylib` stays
  MoltenVK for Zink (0080). 0083 avoids a recursive `pthread_once` (iOS traps on it)
  when Vulkan's set-up loads the display driver which lists Vulkan GPUs; 32-bit
  processes get no D3DKMT Vulkan instance.
- **D3D12:** vkd3d-proton built as ARM64EC PE (meson cross file with
  `arm64ec-w64-mingw32-clang`, `-Wl,--section-alignment=16384`), on KosmicKrisp,
  "beta" (section 3).
- **D3D11:** DXMT v0.80 (commit 589adb78) with private patches (32-bit, "2 GB of video
  memory", texture upload limits per the developer); only object files are published.
- **Display driver** `winenuts` (closed): gives windows Metal layers
  (`build-wine-ios.sh` comment), receives tray icons (0052). Their demo shows several
  Windows windows of different processes on screen at once.

### 1.8 Input, media, network, other

- Controllers: their own `xinput1_4.dll` on GameController (closed), up to 4 pads,
  rumble, battery; Wine's HID path is not used. `windows.gaming.input` enumerates those
  XInput pads as Gamepads (0066).
- Media Foundation: `winedmo` on AVFoundation (0084): `AVURLAsset` + `AVAssetReader`,
  MP4/MOV/M4V/M4A/MP3/WAV, H.264/HEVC/AAC/MP3 decoded by the system, video as 32-bit
  BGRA, audio as 16-bit PCM (max stereo); all AVFoundation calls on one serial queue;
  non-file streams copied to a temp file; `mfsrcsnk` uses winedmo by default; WoW64
  table included.
- Offline mode (0063, `include/wine/nutsemu_offline.h`): while the file named by
  `NUTSEMU_OFFLINE_FLAG` exists, sends/connects to non-loopback addresses (ntdll
  `socket.c`, server `sock.c`) and name lookups (ws2_32 `getaddrinfo`,
  `gethostbyname`) fail; loopback still works. A file so that every iOS process sees
  the switch at once.
- Network: Apple routing/ARP/TCP-state headers taken from the macOS SDK (0044, 0046),
  nsi calling nsiproxy's Unix side directly (0045, 0089). Root certificates from a
  bundled `cacert.pem` (`NUTSEMU_CA_BUNDLE`, 0047).
- Diagnostics: about a third of the patches only log (crash backtraces with registers,
  `dladdr` names for native code, fault descriptions with view/host-page state, big
  allocations, address-space maps at first OOM, TLS slot owners, server request
  statistics, 32-bit crash stacks). Rate limits everywhere ("first 20, then every
  10000th").

### 1.9 The ios-compat layer

`platform/ios-compat/nutsemu_ios_compat.h` is force-included (`-include`) into every
Unix-side file: missing `<sys/conf.h>`/`<sys/vnode.h>` constants (`D_TAPE`, `VLNK`),
declarations for `MPCurrentTaskID`, `MPTaskIsPreemptive`,
`CFNotificationCenterGetDistributedCenter`. The static library
`libnutsemu_ios_compat.a` (linked into every `.so` and `libwineserver.dylib`)
implements those stubs (the distributed center maps to the Darwin notify center),
returns NULL from `IOPSCopyPowerSourcesInfo` and friends (no battery info to Windows
yet), and replaces `bootstrap_register2`/`bootstrap_look_up` with a table in the host
app (`nutsemu_host_service_register/_look_up`, found with `dlsym(RTLD_MAIN_ONLY)`),
falling back to the real `bootstrap_look_up`. Stub headers: `IOKit/ps/*`,
`mach/mach_vm.h`, `servers/bootstrap.h`, an `AppKit.tbd` stub framework. The build
script also generates wrapper headers that include the macOS SDK's `net/route.h`,
`net/if_arp.h`, `netinet/if_ether.h`, `netinet/tcp_fsm.h`, `sys/kern_event.h`,
`sys/sys_domain.h`.

### 1.10 Build configuration (BUILD-INFO.md, build-wine-ios.sh)

- Xcode 27.1, iOS SDK 27.1, deployment target **iOS 26.0**, Apple clang 21,
  llvm-mingw 20260421 (the same toolchain Madeira pins; the script's default path on
  their build machine is a `.../work/Madeira/toolchains/llvm-mingw-...` directory).
- Host tools: a native macOS configure `--enable-archs=arm64ec --without-x
  --without-freetype --without-gnutls --without-vulkan`, built once for `winebuild`,
  `widl`, `makedep` (rebuilt when patch 0057 changes it).
- iOS configure: `--host=aarch64-apple-darwin --with-wine-tools=... 
  --enable-archs=aarch64,arm64ec,i386 --prefix=/nutsemu --bindir=/nutsemu`, CC =
  `clang -target arm64-apple-ios26.0 -isysroot <iPhoneOS SDK> -I ios-compat/include
  -include nutsemu_ios_compat.h -DWINE_USER_SHARED_DATA_ADDRESS=0x14c000000
  -DWINE_TEB_TSD_SLOT=300`, the same two defines in `CROSSCFLAGS` (so the PE side
  agrees), FreeType and GnuTLS (Nettle with mini-GMP) built for iOS, `EGL_LIBS` from
  the Mesa build, `--with-freetype --with-gnutls --with-vulkan --with-opengl` and
  `--without-` everything else (x, cups, sane, krb5, gssapi, usb, pcap, netapi, pulse,
  gstreamer, sdl, capi, v4l2, udev, dbus, oss, alsa, ffmpeg, wayland, inotify,
  fontconfig, coreaudio, opencl, pthread).
- After configure, `SONAME_LIBFREETYPE/GNUTLS/EGL/VULKAN` in `config.h` are rewritten to
  `@loader_path/<lib>` so each Wine set finds them next to itself.
- Link: `LDFLAGS=libnutsemu_ios_compat.a -framework CoreFoundation -F<stub
  frameworks> -Wl,-dead_strip_dylibs`. `make -k`, then the essential modules again
  without `-k` (ntdll.so, win32u.so, wineserver, ntdll/kernel32/kernelbase.dll,
  crypt32.so, wineboot.exe) so a broken essential module stops the build.
- wineserver objects relinked as `libwineserver.dylib` with the entry shim.
- PE output: aarch64 + arm64ec → ARM64X hybrids in `lib/wine/aarch64-windows`, i386 in
  `lib/wine/i386-windows`, debug info stripped, NLS, Wine's fonts and `wine.inf`
  staged. Separate build directories per settings hash, so switching options does not
  force a full rebuild.

---

## 2. Every patch, with a verdict for Madeira

Format: **number**, title exactly as published (file name where the patch has no
subject line), what it does and why, then **Madeira:** verdict. Efforts: S (hours to
a day), M (days), L (weeks).

### 2.1 iOS port basics

- **0002** `0002-ios-cdrom-not-supported.patch`. All CD-ROM ioctls return
  STATUS_NOT_SUPPORTED on iOS (no IOKit storage headers).
  **Madeira:** already have (`build/ntdll-unix/cdrom_stub.c`).
- **0003** `0003-ios-server-dir-in-prefix.patch`. Server directory under the prefix,
  not `/tmp`. **Madeira:** already have (`server_ios.c:3278` `init_server_dir`).
- **0004** `0004-configurable-shared-user-data-address.patch`. `WINE_USER_SHARED_DATA_ADDRESS`
  macro replaces the 0x7ffe0000 constant in kernel32, kernelbase, ntdll (PE and Unix),
  win32u, so Wine's own code reads KUSD at its real host address.
  **Madeira:** partially. KUSD is relocated at run time (`virtual_ios.c:19118`), and
  reads of the constant from Wine's PE modules are served by the sub-floor window
  emulation (`virtual_ios.c` ml952) and a register-rewriting "USD redirect"
  (`signal_arm64_ios.c:9763`); `GetTickCount64` was rewritten to avoid three Mach
  exceptions per call (`wine/dlls/kernelbase/sync.c:45`). The PE constants are still
  0x7ffe0000 (`wine/dlls/kernel32/process.c:42`, `sync.c:45`, `ntdll/thread.c:38`,
  `win32u/message.c:48`). Missing piece: a fixed host address chosen at build time
  (M: every PE module rebuilt, the address reserved early; NutsEmu's 0x14c000000 may
  collide with Madeira's executable window near 0x140000000, so pick another).
- **0010** `0010-apple-flush-instruction-cache.patch`. `sys_icache_invalidate`, also
  correct for code written through an alias. **Madeira:** already have
  (`virtual_ios.c:26603`, plus sub-floor address translation, ml1202).
- **0017** "crypt32: iOS has no trust-settings API for listing root certificates".
  Build fix. **Madeira:** already have (`build/crypto-unix/crypt32_unixlib_ios.c:33`).
- **0018** "ntdll: on iOS, the address space starts above page zero". Free-space
  search starts after `__PAGEZERO`; otherwise ENOMEM below 4 GB ended the search.
  **Madeira:** already have (usable-VA floor, `ios_usable_va_floor`, and the
  __PAGEZERO notes in `env_ios.c:2526`, `signal_arm64_ios.c:11513`).
- **0019** "ntdll: on iOS, reserve fixed addresses as read/write, and keep searching on
  refusals". Max protection RW; every `mach_vm_map` refusal becomes EEXIST ("try
  elsewhere"); one address-space dump on failure. **Madeira:** partially.
  `anon_mmap_tryfixed` still asks for `VM_PROT_ALL` (fine with CS_DEBUGGED) and maps
  every refusal except `KERN_NO_SPACE` to ENOMEM (`virtual_ios.c:7392-7410`, ml813
  only records the raw code), which ends `map_free_area`'s search at an
  invalid-address hole inside the map. S: treat `KERN_INVALID_ADDRESS` like EEXIST.
- **0020** "ntdll: on iOS, find the real top of the address space, not the power of
  two below it". Binary search for the top. **Madeira:** unverified.
  `get_host_addr_space_limit` (`virtual_ios.c:16984`) probes powers of two with mmap
  hints; reserved areas can extend the limit (`virtual_ios.c:18398`). On a 63 GB
  (small-map) device check the logged limit; if it reads 32 GB, port the binary
  search (S).
- **0044** "nsiproxy: Apple's routing and ARP headers on iOS too (NutsEmu)".
  **Madeira:** already have (`nsi_network_ios.c`, `nsi_ndis_ios.c`, `nsi_ip_ios.c`
  compile Wine's BSD providers).
- **0046** "server: Apple's TCP states on iOS too (NutsEmu)". Linux TCP state numbers
  were used with Darwin's `getsockopt` values. **Madeira:** already have
  (`wine/server/sock.c:130` comment and Darwin numbering).
- **0047** "crypt32: root certificates from the host's bundle (NutsEmu)".
  **Madeira:** already have (`app/Madeira/cacert.pem`, loaded by
  `crypt32_unixlib_ios.c`).
- **0068** "include: NutsEmu's headers listed (NutsEmu)". Makefile listing for their new
  headers. **Madeira:** not applicable.

### 2.2 Executable memory and JIT

- **0005** `0005-host-exec-memory-for-native-images.patch`. ARM64/ARM64EC images are
  placed inside host executable memory; sections are read and relocated through the
  write alias; code pages are never made writable. Why: on iOS, memory that started
  writable never becomes executable. **Madeira:** has the problem solved differently:
  images are mapped at their own VA and executed from a *pool copy*, with IAT
  rewriting to the copy (`virtual_ios.c:4240`), exec-fault redirects from the PE VA to
  the copy (`virtual_ios.c:2220`), per-child ntdll copies (`virtual_ios.c:13955`) and
  the related stale-alias/tombstone machinery. Placing the image itself at a pool
  address would remove the copy, the redirects and the "[rip-leak]" class of bugs. L,
  prerequisite: confirm on device that writable data sections of a pool-hosted image
  can be RW pages of the pool's RX mapping under TXM (NutsEmu's code implies yes for
  their pool; Madeira has seen pool pages "born non-exec" with max=3).
- **0009** `0009-host-exec-memory-for-native-jit-code.patch`. FEX code buffers
  (`MEM_EXTENDED_PARAMETER_EC_CODE`) from `wine_host_jit_alloc`; `mprotect_exec` never
  makes pool memory writable and never makes other memory executable. **Madeira:**
  already have in substance (anon RWX regions are `vm_remap`'d from the pool with a RW
  alias, `virtual_ios.c:2220`; JIT pool via `app/Madeira/JITAllocator.c`).
- **0069** "ntdll: native JIT code memory in processes that aren't ARM64EC, from the
  host's JIT pool (NutsEmu, iOS)". **Madeira:** already have (WoW64 processes run
  `xtajit.dll` from the same pool, docs/WOW64.md §1 "Everything that executes comes from
  the one dual-mapped RX/RW JIT pool").
- **0078** "ntdll: no forced execute permission where the host provides executable
  memory (NutsEmu)". **Madeira:** already have (`virtual_ios.c:12453-12482`, force_exec
  limited to WoW64 windows).
- **0079** "ntdll: the ARM64EC code map covers 512 GB, and RtlIsEcCode checks its bound
  (NutsEmu)". **Madeira:** already have (`alloc_arm64ec_map` ml124 at
  `virtual_ios.c:17065`; bound check `wine/dlls/ntdll/signal_arm64ec.c:4151`).

### 2.3 TEB, x18 and KUSD fault emulation

- **0008** `0008-teb-in-a-tsd-slot.patch`. Compile-time `NtCurrentTeb()` from TSD slot
  300 in every PE module and dispatcher. **Madeira:** has an equivalent by other
  means: the TEB is in a dynamically created pthread key (`ios_teb_tls_slot_offset`,
  `signal_arm64_ios.c:287`, `loader_ios.c:3029`), dispatchers re-derive x18 from it
  (`loader_ios.c:2197`), and an x18 binary patcher rewrites PE code at
  `mprotect_exec` time. A compile-time slot would take Wine's own modules off the
  patcher (M; needs a fixed slot number reserved before any PE code runs).
- **0016** `0016-emulate-teb-access-through-x18.patch`. SEGV emulation of
  `LDR/STR [x18,#imm]`. **Madeira:** already have, broader (`ios_x18_derived_base`,
  `signal_arm64_ios.c:1765`, also handles `add x8,x18,...` derived bases).
- **0025** "ntdll: emulate program reads of KUSER_SHARED_DATA at 0x7ffe0000 (NutsEmu)".
  **Madeira:** already have (sub-floor window for the canonical page, ml952,
  `virtual_ios.c:19131`).
- **0085** "ntdll: no instruction decoding in the fault handler after a jump to a bad
  address (NutsEmu)". **Madeira:** already have in effect (fault-path instruction reads
  are guarded: "instruction stream at pc unreadable", `signal_arm64_ios.c:9563`).

### 2.4 Server in-process and process lifetime

- **0007** `0007-ios-server-uses-own-task-port.patch`. Server uses `mach_task_self()`
  for its in-process clients; the client does not send its task port. **Madeira:**
  already have its own variant (`build/wineserver/mach_ios.c:75`, thread contexts via
  `ios_fill_thread_context` on `mach_task_self()`).
- **0011** `0011-host-can-outlive-the-windows-process.patch`. Process exit calls the
  host instead of `exit()`. **Madeira:** already have (`server_ios.c:3595`
  `process_exit_wrapper` closes only the pseudo-process's socket).
- **0012** `0012-in-process-server-never-kills-its-host.patch`. **Madeira:** already
  have (`build/wineserver/wineserver_ios_kill.h`, `kill` redirected).
- **0013** `0013-wineboot-without-child-processes.patch`. Inf sections applied in
  wineboot's own process when rundll32 cannot start; registry flushed at the end.
  **Madeira:** not applicable (prefix comes from `prefix-template.tar.gz`,
  `WineProcessBridge.m:425`; Madeira can start child processes).
- **0014** `0014-setupapi-unattended-prefix-install.patch`. Skip rewriting identical
  fake DLLs; stop the endless "need media" loop in unattended installs.
  **Madeira:** partially relevant. The fake-DLL part is not (template prefix). The
  `SetupCommitFileQueueW` loop fix applies to any unattended installer run (Dock
  installers, docs/MADEIRA_DOCK.md); not present in `wine/dlls/setupapi/queue.c`
  (Madeira's setupapi has no iOS commits, `git log -- dlls/setupapi`). S.
- **0015** `0015-server-flush-key-saves-the-registry.patch`. `RegFlushKey` writes the
  registry, as the app may be killed. **Madeira:** partially. Registry is saved by
  Wine's periodic save and at `close_socket_timeout` (`build/wineserver/request_ios.c:1048`);
  `DECL_HANDLER(flush_key)` is still a no-op (`wine/server/registry.c:2231`). S, worth
  doing: iOS kills apps without notice.
- **0032** "ntdll: exit() on the Unix side ends the Windows process only (NutsEmu, D17
  stage B)". **Madeira:** partially. `fatal_error` and `ios_fatal_startup_error` end only
  the pseudo-process with `pthread_exit` (`loader_ios.c:141`, `env_ios.c:2050`), but
  bare `exit()` calls remain, e.g. `virtual_ios.c:19127` (KUSD mapping failure). S:
  audit `exit(`/`abort(` in `build/ntdll-unix/*.c`.
- **0035** "ntdll: a host app's main thread isn't adopted (NutsEmu)". **Madeira:**
  already have by construction (`apple_main_thread` returns when not on the main
  thread, `loader_ios.c:3312`; Wine never starts on the UIKit thread).
- **0058** `0058-stack-overflow-ends-the-process.patch`. A stack overflow without room
  for the exception ends the process, not just the thread (a half-dead browser
  process was never restarted). **Madeira:** missing; `virtual_ios.c:20350` still calls
  `abort_thread(1)`. S, but it must end the pseudo-process only.

### 2.5 Several processes in one iOS process

- **0024** "ntdll: let the host release all of an exited instance's memory (NutsEmu)".
  **Madeira:** partially. JIT-pool copies (`ios_jit_reclaim_process`,
  `virtual_ios.c:10205`) and 32-bit windows (`virtual_ios.c:11590`) are reclaimed; a
  64-bit pseudo-process's anonymous views (heaps, stacks, mapped files) are not, and
  `struct file_view` has no owner (`virtual_ios.c:5410`). M: tag views with the
  owning PEB and free them in the pseudo-process teardown.
- **0030** "ntdll: several Wine instances in one host process (NutsEmu, D17 stage B)".
  Per-instance signal handlers through `wine_host_sigaction`, shared KUSD mapping,
  relocate the main EXE when its base is taken. **Madeira:** not applicable (one ntdll
  instance, pseudo-processes).
- **0031** "ntdll: new processes are started by the host as more Wine instances
  (NutsEmu, D17 stage B)". **Madeira:** already have (`wine_ios_child_main` on a new
  pthread, `process_ios.c:412-531`).
- **0034** "ntdll: the host can add command-line switches for a new process (NutsEmu)".
  Used for the web helper's single-process, no-JIT mode. **Madeira:** already have the
  effect (`process_ios.c:1243` appends `--single-process` and refuses `--type=`
  children; `--js-flags=--jitless`, `process_ios.c:1399`). A generic host hook is not
  needed.
- **0036** "ntdll: NUTSEMU_JIT_POOL is per process (NutsEmu)". **Madeira:** not
  applicable today (one iOS process); required for extension processes (section 4c).
- **0041** "win32u: no wait for explorer's desktop inside a host app (NutsEmu)".
  **Madeira:** not observed as a problem; the `WM_NULL` wait is still there
  (`build/win32u-unix/driver_ios.c:1767`). Keep in mind if a second GUI process ever
  hangs at driver load while the first does not pump messages.
- **0051** "ntdll: code in another process's DLL, named for this one to run, is
  translated (NutsEmu)". An APC or remote thread whose start address is in another
  process's copy of a system DLL (Steam queuing its own `kernel32!LoadLibraryW` into a
  game for the overlay) is moved to the same export in this process's copy. FEX asks
  through `NtQueryVirtualMemory` class 0x4e55. **Madeira:** missing. All pseudo-
  processes share one address space but each maps its own DLL copies
  (`virtual_ios.c:13955`), so such an address is mapped but belongs to another
  process's copy. No grep hit for foreign/remote-APC handling in `build/ntdll-unix`.
  M; matters only if the Dock's client injects into games.
- **0059** `0059-fixed-base-programs-keep-their-address.patch`. Relocatable EXEs go
  top-down; an EXE without relocations waits for its base. **Madeira:** already have
  (executable window and hand-off, `ios_exe_win_claim`/`ios_exe_win_wait_for_handoff`,
  `virtual_ios.c:7087-7370`; parent does not block on such a child,
  `process_ios.c:1723`).
- **0060** `0060-fixed-image-slot-from-the-host.patch`. Same, through a host-kept slot.
  **Madeira:** already have (same mechanism, `MADEIRA_EXE_WINDOW_HANDOFF`).
- **0061** `0061-shared-libraries-by-full-path.patch`. Retry dlopen of EGL, Vulkan,
  FreeType, GnuTLS in `NUTSEMU_SHARED_LIBS` when `@loader_path` resolves against the
  app executable. **Madeira:** not applicable (unix libraries are linked statically:
  `libntdll_unix.a`, FreeType/GnuTLS via static symbol tables, `build/ntdll-unix/build.sh:52`).
- **0062** `0062-ntdll-path-from-the-host.patch`. `ntdll_dir` from `argv[0]` when
  `dladdr` names the app. **Madeira:** not applicable (same reason).
- **0064** "ntdll: NUTSEMU_FEX_SMALL_LOOKUP is per process too (NutsEmu)".
  **Madeira:** not applicable today; same note as 0036.
- **0067** "ntdll: foreign code is translated unless it is this process's own code
  (NutsEmu)". Refinement of 0051. **Madeira:** missing with 0051.

### 2.6 Extension processes (D18)

- **0037** "ntdll: the host's reserved areas count toward the address space limit
  (NutsEmu)". In an extension, fixed mappings above 0x7000000000 are refused; the host
  reserves a large area itself and passes it as a preload area. **Madeira:** not
  applicable today (upstream Wine already widens the limit for reserved areas,
  `virtual_ios.c:18398`); needed for 4c.
- **0038** "ntdll: sparse pools in host-named slots (NutsEmu)". 16 GB-aligned slots named
  by the host; a 16 GB pool gets only its head backed; '!' slots stay exclusive for
  BackupRefPtr pools. **Madeira:** has the same idea for the in-app 64 GB window:
  ml151 lazy pool reservation (`virtual_ios.c:1345`), slot probes (`virtual_ios.c:365`),
  `[cage]` holdback (`virtual_ios.c:8457`). Compare the '!' rule (nothing else inside a
  BackupRefPtr pool's slot) against Madeira's slot allocator.
- **0039** "server: no task port for a process in another iOS process (NutsEmu)".
  **Madeira:** missing; needed only for 4c.
- **0040** "server: signal a thread in another iOS process through the host (NutsEmu)".
  **Madeira:** missing; needed for 4c (Madeira's suspend/context code assumes the same
  task: `mach_ios.c:560` `ios_thread_mach_hold`, `:876` `ios_fill_thread_context`).
- **0042** "server: another iOS process's memory through the host (NutsEmu)".
  **Madeira:** missing; needed for 4c (`mach_ios.c:1085` reads client memory directly).
- **0065** "ntdll: code named by a process in another iOS process, translated too
  (NutsEmu)". **Madeira:** missing; needed for 4c if 0051 is done.

### 2.7 Address-space packing and memory semantics

- **0006** `0006-ios-host-address-space-limit.patch`. First probe for the iOS top; EC
  map sized to it. **Madeira:** already have (`virtual_ios.c:16984`, ml122/ml124).
- **0028** "ntdll: a reservation beyond the host's address space is placed below it,
  alignment kept (NutsEmu)". Random Chromium hints in an 8 TB space are placed below
  the 63 GB limit at the same offset modulo their power-of-two size; 8 GB cages
  bottom-up, aligned pools top-down, a 16 GB zone for the cages. **Madeira:**
  largely have (task #34/#35 placement, `[jumbo]`/`[bigres]` census and lazy pools,
  `virtual_ios.c:21920-21945`, `:1345`). Worth a side-by-side check for 4 GB and 8 GB
  hints with offsets (NutsEmu's packing rules are explicit and short).
- **0029** "ntdll: VirtualProtect reports a copy-on-write image page's old protection
  as read-write (NutsEmu)". V8 checks that its flags page was PAGE_READWRITE.
  **Madeira:** missing (`virtual_ios.c:24475` returns `get_win32_prot` unchanged). S.
- **0033** "ntdll: reservation hints keep alignment up to 64 GB; 16 GB pools get their
  own lanes (NutsEmu)". **Madeira:** largely have (same section as 0028).
- **0081** "ntdll: on iOS, physical memory is the app's memory limit (NutsEmu)".
  **Madeira:** already have (ml992, footprint + `os_proc_available_memory()`,
  `MADEIRA_TOTAL_PHYS_MB`, `virtual_ios.c:18645`).
- **0092** "ntdll: decommitted pages come back zeroed on hosts with bigger pages
  (NutsEmu)". **Madeira:** already have, with one gap: `decommit_pages`
  (`virtual_ios.c:16340`) memsets the partial host pages at the edges, but assumes
  they are writable ("edge pages belong to the same committed RW guest heap"); NutsEmu
  temporarily makes a read-only host page writable before zeroing. S.
- **0093** "ntdll: big placeholder reservations hold their address space lazily
  (NutsEmu)". A placeholder of 64 MB or more holds 16 MB; the rest is backed in 16 MB
  steps when split or replaced. V8 reserves three 512 MB placeholders per isolate and
  uses 64 KB of each; in a single-process web helper each notification toast is a new
  isolate, so the fourth one exhausted the 64 GB. **Madeira:** missing (no lazy
  placeholder logic; placeholder code at `virtual_ios.c:16635`, `:14897`). Madeira runs
  the web helper the same way (single-process, `process_ios.c:1243`), so it should hit
  the same wall. M. **High value.**

### 2.8 Networking

- **0043** "iphlpapi, nsiproxy: log the TCP table requests (NutsEmu diagnostics)".
  **Madeira:** not needed (its TCP table is served in-process, ml470).
- **0045** "nsi: call nsiproxy's Unix side directly when there's no \\.\Nsi device
  (NutsEmu)". **Madeira:** already have (`nsi_unixlib_ios.c`, `nsi_network_ios.c`).
- **0063** `0063-offline-mode.patch`. Network kill switch by flag file (section 1.8).
  **Madeira:** partially. The Dock has Steam's own offline logon
  (docs/MADEIRA_DOCK.md "Offline play"); no Wine-level block of outside connections
  (no hit for an offline switch in `build/ntdll-unix`, `wine/dlls/ws2_32/unixlib.c`).
  S (env var instead of a file is enough in one iOS process).
- **0089** "nsi: try the missing \\.\Nsi device once, not on every call (NutsEmu)".
  **Madeira:** already have (`wine/dlls/nsi/nsi.c:109` `nsi_device_missing`).

### 2.9 32-bit programs

- **0048** "ntdll: a 32-bit program starts as its 64-bit stand-in (NutsEmu)".
  **Madeira:** not applicable (real WoW64, docs/WOW64.md).
- **0070** "ntdll, wow64: a 32-bit program's memory is a 4 GB window aligned to 4 GB
  (NutsEmu, iOS, D19)". **Madeira:** already have, more complete: guest windows
  `[B, B+4GB)` 4 GB-aligned, lazy and several at once, released on exit,
  `ProcessWineIosWowGuestBase` as the single source of `B`, FEX pins a register to `B`
  (docs/WOW64.md §2). NutsEmu's model is one window per Wine instance.
- **0071** "wow64win: the 32-bit program's pointers in its 4 GB window (NutsEmu, iOS,
  D19)". **Madeira:** already have (WoW64 layer converts through typed helpers,
  docs/WOW64.md §2; win32u through `wow64win.dll`).
- **0072** "ntdll: a 32-bit system program runs as itself, not as its 64-bit stand-in
  (NutsEmu, D19)". **Madeira:** not applicable.
- **0074** "opengl32: 32-bit programs' OpenGL calls in the 4 GB window (NutsEmu, D19)".
  **Madeira:** already have, same design (`patches/wine-opengl-winios.patch`:
  `get_wow64_buffer_binding` chooses pointer or offset from the bound buffer,
  `ios_wow_host_ptr` for client objects).
- **0075** "wow64win: one- and two-parameter user calls whose argument is an address
  (NutsEmu, D19)". `NtUserCallOneParam/TwoParam/HwndParam` codes whose argument is a
  struct address get the window (D3DKMT adapter lookup, monitor rects,
  ClientToScreen...). **Madeira:** already have (`wine/dlls/wow64win/user.c`,
  `wow64_NtUserCallOneParam`/`TwoParam`/`HwndParam` run the same codes through
  `guest_ptr32()`: primary monitor rect, async key state, D3DKMT adapter lookup, desk
  pattern, monitor info, IME rect, monitor from rect, virtual screen rect,
  AdjustWindowRect, around lines 1766-1914).
- **0076** "wow64: a 32-bit program's last-chance exception or fast fail is logged with
  its stack (NutsEmu, D19)". **Madeira:** partial diagnostics exist (`wine/dlls/wow64/syscall.c:1946`
  handles fast fail); a 32-bit stack dump on last chance was not found by grep. S,
  diagnostic only.

### 2.10 Graphics

- **0073** "win32u: an OpenGL 2.x context's extensions are found (NutsEmu)". Fixes an
  11.18 bug (`parse_current_extensions` wrote into a shadowed local). **Madeira:** not
  applicable (Wine 11.4 has no `parse_current_extensions`; Madeira's GL driver is
  `build/win32u-unix/opengl_ios.c`). Re-check on a Wine rebase.
- **0080** "win32u: Wine's Vulkan through NutsEmu's driver switchboard (NutsEmu)".
  **Madeira:** missing in the committed tree (no winevulkan; `build/wine-i386/build.sh:49`
  `--without-vulkan`). In progress (uncommitted): `build/win32u-unix/vulkan_ios.c` loads
  the library named by `MADEIRA_VULKAN_LIBRARY` (`vulkan = moltenvk|kosmickrisp`) by
  full path, so MoltenVK is the same image Zink uses. Part of 4b.
- **0083** "win32u: no Vulkan GPU listing inside Vulkan's own set-up (NutsEmu)".
  **Madeira:** in progress (uncommitted): `madeira_vulkan_init_on_this_thread()` guard in
  `build/win32u-unix/d3dkmt_ios.c`. Note the general rule it records: iOS's
  `pthread_once` traps on re-entry.

### 2.11 Compatibility

- **0050** "ntdll: a program's own x64 LuaJIT is replaced by a GC64 build (NutsEmu)".
  **Madeira:** already have (`build/wineserver/luajit_compat.c` in `create_mapping`,
  `build/luajit-x64/build.sh`).
- **0052** "shell32: without explorer, tray icons go to the display driver (NutsEmu)".
  **Madeira:** missing (`nulldrv_NotifyIcon`, `build/win32u-unix/driver_ios.c:1482`).
  Low priority: the Dock runs the client headless. S if a launcher needs it.
- **0056** "vcruntime140, msvcp140_*, concrt140: Visual C++ 2015-2022 version numbers
  (NutsEmu)". **Madeira:** partially. Microsoft's x64 runtime is layered over Wine's
  for x64 sessions except `vcruntime140.dll`, which stays Wine's ARM64EC builtin for SEH
  (`WineProcessBridge.m:1565-1600`); that builtin has no `VER_PRODUCTVERSION`
  (`wine/dlls/vcruntime140/Makefile.in`). S: add 14.x version resources to the builtin.
- **0057** "makedep: an ARM64EC-only module linked for aarch64 gets the aarch64
  resources (NutsEmu)". **Madeira:** unverified. Madeira builds ARM64EC-only trees, so
  the bug shape differs; scan `app/Madeira/arm64ec-windows/*.dll` for missing version
  resources before porting.
- **0066** "windows.gaming.input: NutsEmu's XInput pads are Gamepads (NutsEmu)". Polls
  XInput once a second and exposes each pad as a Gamepad (VID 045E PID 02EA), rumble
  through `XInputSetState`. **Madeira:** partially. With `MADEIRA_PAD_MODE=hid` WGI
  sees the HID pad (docs/CONTROLLERS.md, "Readers"); in the default XInput mode there
  is no HID device, so WGI finds nothing. No Madeira commit in
  `wine/dlls/windows.gaming.input`; in progress (uncommitted) in the Wine working tree.
  S. See 4e.
- **0084** "winedmo: media files read and decoded with AVFoundation; mfsrcsnk uses
  winedmo (NutsEmu)". **Madeira:** partially, different design: winegstreamer's unix
  side on FFmpeg demux + VideoToolbox/AudioToolbox (docs/MEDIA.md); 64-bit processes get
  the WMA transform only, `wg_parser` is opt-in with `MADEIRA_WG_64BIT=1`. See 4g.
- **0086** "ntdll: on ARM64, the extended state of an x64 CPU with AVX (NutsEmu)". KUSD
  XState says AVX (x87+SSE+AVX, 0x340 bytes) so `GetEnabledXStateFeatures` and .NET
  use AVX; thread contexts carry no AVX state. **Madeira:** missing. AVX is opt-in per
  game (`MADEIRA_FEX_AVX=1`, `FEX/Source/Windows/Common/CPUFeatures.cpp:162`), but
  `init_xstate_features` runs only on x86 hosts (`wine/dlls/ntdll/unix/system.c:544`),
  so with AVX on, `GetEnabledXStateFeatures` still says no AVX. S: fill XState when
  `MADEIRA_FEX_AVX=1`.
- **0090** "ntdll: a thread that keeps yielding sleeps a moment instead (iOS)".
  **Madeira:** already have (adaptive yield ml1063, `wine/dlls/ntdll/unix/sync.c:3564`).

### 2.12 Synchronization

- **0087** "server, ntdll: NutsSync, Windows synchronization in shared memory
  (NutsEmu)". **Madeira:** have two engines: fastsync (default; events and semaphores,
  single-handle non-alertable waits, 2 ms park cap then server,
  `wine/dlls/ntdll/unix/sync.c:1043`) and madsync (opt-in userspace ntsync, process-
  local memory, `build/madsync/madsync.c`). See 4f.
- **0088** "server: which threads make which requests most often (NutsEmu)".
  **Madeira:** already have (`[srv-req]` ml1055, `build/wineserver/request_ios.c:334`).

### 2.13 Diagnostics only

Madeira's diagnostics already exceed these in most areas; only gaps are flagged.

- **0021** "ntdll: log backtraces for crashes (aarch64)". **Madeira:** have
  (`ios_fault_operand_trace` ml1200, `signal_arm64_ios.c:9510`).
- **0022** "ntdll: log big allocations and releases with their caller; repeated errors
  rate-limited". **Madeira:** have (`[jumbo]`, `[bigres]`, `virtual_ios.c:21920`).
- **0023** "ntdll: describe an access violation (diagnostics)". Includes the last 64
  released views. **Madeira:** mostly have (fault reports with view state); a
  "recently released views" ring was not found by grep (`released_views`). S.
- **0026** "ntdll: fault reports add the host page's protections and the thread's
  stack (NutsEmu)". **Madeira:** have (Mach region probes throughout the fault path).
- **0027** "ntdll: on a stack overflow, log the most frequent code addresses on the
  stack (NutsEmu)". **Madeira:** have a recursion fingerprint (`virtual_ios.c:19691`).
- **0049** "kernelbase: log a program start that fails, with its command line (NutsEmu
  diagnostics)". **Madeira:** have (`NtCreateUserProcess` logs every image and command
  line, `process_ios.c` `[proc-gate]`, `spawn:` phases).
- **0053** "kernelbase: an unhandled exception is reported with its module and stack
  (NutsEmu)". **Madeira:** have on the unix side (ml1200, block ring); not in
  kernelbase. No action.
- **0054** "ntdll: log the address space at the first failed allocation (NutsEmu
  diagnostics)". **Madeira:** have (ml90 gap walk, allocation-failure probe ml813).
- **0055** "ntdll, kernelbase: log TLS slot owners and small values at thread exit
  (NutsEmu diagnostics)". **Madeira:** not found; add only when a case needs it.
- **0077** "ntdll: a failed NtProtectVirtualMemory is logged with the view (NutsEmu)".
  **Madeira:** partially (refused restores inside pool copies, `virtual_ios.c:24487`).
- **0082** "ntdll: a trap in native code is logged with its library, function and
  callers (NutsEmu)". **Madeira:** have (`dladdr` naming, `signal_arm64_ios.c:1983`).
- **0091** "kernelbase: log the crashed thread's registers and stack (NutsEmu)".
  **Madeira:** have (ml1200 registers and operands; block ring).

Count check: 0002-0093 = 92 patches, each listed once above.

---

## 3. vkd3d-proton patches and what they say about the drivers

Base: vkd3d-proton 750061ae, built as ARM64EC PE with llvm-mingw (`arm64ec-w64-mingw32`),
`-DWINE_TEB_TSD_SLOT=300` and a `winnt.h` wrapper (NtCurrentTeb from the TSD slot),
`--section-alignment=16384` for 16 KB pages, static libstdc++, then stamped
"Wine builtin DLL". Only `d3d12.dll` and `d3d12core.dll` ship.

- **0001** "vkd3d-proton: transform feedback and single-texel alignment are not
  required (NutsEmu)". Device creation no longer fails when
  `transformFeedbackQueries` is missing (`EXT_transform_feedback` is cleared, stream
  output pipelines then fail to create) or when single-texel alignment for storage and
  uniform texel buffers is missing (unaligned typed buffer views read the wrong place).
  Implies **KosmicKrisp has no VK_EXT_transform_feedback** and **places texel buffer
  views at 16-byte aligned offsets only** (no `*SingleTexelAlignment`). Games using
  stream output or unaligned typed views will misbehave.
- **0002** "vkd3d-proton: the layered-API properties aren't asked for (NutsEmu)".
  `VkPhysicalDeviceLayeredApiPropertiesListKHR` (maintenance7) is no longer chained.
  Two findings: Wine's winevulkan crashed converting that nested chain back
  (`vkGetPhysicalDeviceProperties2`), a winevulkan bug any port will hit; and
  **KosmicKrisp advertises VK_KHR_maintenance7** but is not a layered driver.
- **0003** "vkd3d-proton: KosmicKrisp isn't held below shader model 6.5 by denormal
  control or compute derivatives (NutsEmu)". For `VK_DRIVER_ID_MESA_KOSMICKRISP`:
  feature level 12_0 without tiled resources tier 2 (KosmicKrisp has **no sparse
  residency**); shader model raised past 6.0 although there is **no per-shader float32
  denormal control**; the NVIDIA-style fallback for compute derivatives. SM 6.6 still
  needs **64-bit buffer atomics, which KosmicKrisp does not expose**. Implies:
  `shaderBufferInt64Atomics` absent, `computeDerivativeGroupLinear` absent or partial,
  `shaderDenormPreserveFloat32` absent. Engines that require 12_0 and SM 6.5 can start;
  anything needing SM 6.6 (64-bit atomics, dynamic resources) cannot yet.
- **MoltenVK** (0080's description): lacks VK_EXT_robustness2 and mutable descriptor
  types "and more", so vkd3d-proton does not start on it. This is why NutsEmu keeps
  two Vulkan drivers: MoltenVK under Zink (Zink did not start on KosmicKrisp in their
  test 1286) and KosmicKrisp under winevulkan.
- KosmicKrisp is written against Metal 4 (MTL4CommandQueue/Compiler/ArgumentTable),
  so iOS 26 is the floor (Madeira's own cross file says the same:
  `build/mesa-ios/kosmickrisp-ios-arm64.cross`). NutsEmu's whole app targets iOS 26.0.

---

## 4. Ranked plan for Madeira

Ranking weighs value to current Madeira users against effort and risk. Every default
change gets a kill switch (project rule); none of these names a game.

| Rank | Item | Effort | Why now |
|---|---|---|---|
| 1 | Lazy placeholders (0093) | M | Same single-process web helper; V8 isolates per toast exhaust the window |
| 2 | Stack overflow ends the pseudo-process (0058) | S | Half-dead processes are worse than dead ones |
| 3 | Copy-on-write old protection reported RW (0029) | S | V8 CHECK failure class |
| 4 | Registry written on `RegFlushKey` (0015) | S | iOS kills apps without a clean server exit |
| 5 | XState AVX in KUSD when `MADEIRA_FEX_AVX=1` (0086) | S | .NET and others only use AVX when XState says so |
| 6 | Any `mach_vm_map` refusal continues the search (0019); binary-search top check (0020) | S | Small-map devices |
| 7 | XInput battery + Windows.Gaming.Input pads in XInput mode (0066), item 4e (both in progress, uncommitted) | S-M | Unity titles read only WGI |
| 8 | Remaining bare `exit()` in ntdll-unix (0032), setupapi media loop (0014) | S | One pseudo-process must not end the app |
| 9 | wined3d over Zink for D3D8/DDraw/D3D9 fallback (4a) | M | Mostly assembled already |
| 10 | Several visible windows (4d) | M | Desktop mode exists |
| 11 | NutsSync ideas for fastsync/madsync (4f) | S-M | Alertable zero sleeps, shared-memory design |
| 12 | winevulkan + vkd3d-proton on KosmicKrisp (4b) | L | Paused by the owner on 2026-10-05; build pieces now in progress (uncommitted), device runs pending |
| 13 | Release a dead 64-bit pseudo-process's views (0024) | M | Long sessions with launchers |
| 14 | Configurable KUSD address for Wine's PE modules (0004) | M | Removes Mach faults from Wine's own code |
| 15 | Images hosted directly in the JIT pool (0005), item 4g | L | Removes the pool-copy/redirect bug class |
| 16 | Web helper in an extension process (4c) | L-XL | Biggest change; needed only if the 64 GB window or memory limit is the wall |

### 4a. D3D9 and OpenGL via wined3d on Zink/MoltenVK

What NutsEmu does: Wine's stock wined3d (no patches) over Wine 11.18's EGL WGL path,
Mesa EGL + Zink + MoltenVK. Their findings: the 11.18 extension bug (0073), and that
wined3d told "GL 3.3" used depth clamp and uniform buffers Zink-on-MoltenVK lacks
and drew nothing, so the context must report what it really supports (2.1).

Madeira today: D3D9 goes through DXMT's frontend for both bitnesses (docs/WOW64.md
"Direct3D 9", `MADEIRA_D3D9_X64`); Wine's `wined3d.dll`, `d3d8.dll`, `ddraw.dll` ship but
have had "no GL" (HANDOFF line ~385). On `test/opengl-1010` a desktop GL backend
exists: `build/win32u-unix/opengl_ios.c` (`gl-backend = zink`: OSMesa + Zink on
MoltenVK, fallback GLES), Mesa patches 0001-0007 including
`0007-zink-moltenvk-depth-clamp-and-no-overflow-query.patch`, and the WoW64 GL thunks.

Steps:
1. With `gl-backend = zink`, run Wine's d3d8/ddraw/d3d9 (wined3d) test programs through
   the Custom... path (no per-test buttons) and log the GL version/extension set wined3d
   sees. Make the Zink context report its real version so wined3d does not take 3.x
   paths MoltenVK cannot back (NutsEmu's lesson).
2. Route D3D8 and DirectDraw to wined3d-on-Zink by default when the Zink backend is
   available (DXMT has no D3D8/DDraw); keep DXMT for D3D9, with wined3d as a per-game
   fallback switch.
3. 32-bit: wined3d's GL calls go through the already regenerated WoW64 thunks.
Effort M. Prerequisite: Zink backend in the default build (IPA size: Mesa is already
under `app/Madeira/gl/`).

### 4b. winevulkan + vkd3d-proton on KosmicKrisp

Owner decisions already recorded (HANDOFF 2026-10-05, queue item 2, paused): all
stages, build everything ourselves, Vulkan PE layers as an in-app download (IPA under
200 MB), driver probably bundled, per-game renderer choice; DXVK for D3D11/i386 D3D9
was also on that list.

State of the working tree when this was written (uncommitted): KosmicKrisp builds for
iOS (`docs/KOSMICKRISP.md`: Mesa 26.2.4, two Mesa patches, not yet run on a device),
`vulkan_ios.c` exists, `build/vkd3d-proton/` carries NutsEmu's three patches. The list
below is the full path; check items off against that work.

What it takes, in order:
1. **KosmicKrisp for iOS**: Mesa with `-Dvulkan-drivers=kosmickrisp`, iOS 26
   deployment target (Metal 4), `build/mesa-ios/kosmickrisp-ios-arm64.cross` and
   `build-kosmickrisp.sh` (in progress). The app must `dlopen` it only on iOS 26+.
2. **winevulkan unix side** in `build/win32u-unix` (Wine 11.4's `win32u/vulkan.c` plus
   the winios surface hook: a `VK_EXT_metal_surface` surface on the HWND's
   `CAMetalLayer`, `winios_metal_layer_for_hwnd`, `Winios.m:1314`). Load KosmicKrisp
   for winevulkan and keep MoltenVK for Zink, as NutsEmu's 0080 does (Zink did not
   start on KosmicKrisp for them). Port 0083 (pthread_once re-entry traps on iOS).
3. **winevulkan PE** (`winevulkan.dll`, `vulkan-1.dll`) for ARM64EC; the i386 farm is
   `--without-vulkan` (`build/wine-i386/build.sh:49`), so 32-bit Vulkan needs a second
   build.
4. **vkd3d-proton** for ARM64EC with llvm-mingw (NutsEmu's meson cross file is a working
   template; Madeira does not need their TSD `winnt.h` because its x18 handling covers
   PE code). Apply the three patches in section 3. Fix the winevulkan maintenance7
   conversion crash properly instead of hiding it (0002 shows it).
5. Per-game choice between `madeira-d3d12` (Metal Shader Converter) and vkd3d-proton.

What MoltenVK lacks for vkd3d-proton (per NutsEmu): VK_EXT_robustness2, mutable
descriptor types and more. What KosmicKrisp lacks: transform feedback, single-texel
alignment, sparse residency, per-shader denorm control, 64-bit buffer atomics (SM 6.6).
Effort L. Memory note: the driver runs in the app; shader compilation goes through
Metal, so no extra executable memory is needed.

### 4c. Steam's web helper in a separate extension process

NutsEmu's design (D18): the extension runs its own Wine instance (own Unix libraries,
own JIT pool, own 64 GB address space, own memory limit) and connects to the
wineserver in the app. Required pieces, all in their patches: per-process environment
for JIT and FEX settings (0036, 0064), preload area for the extension's address space
(0037), sparse pool slots (0038), no task port for remote processes (0039), thread
signals through the host (0040), process memory through the host (0042), foreign-code
translation across processes (0065), and synchronization in shared memory (0087).

Madeira today: one Mach task; pseudo-processes; the web helper is a single-process,
jitless pseudo-process placed in the 64 GB window by the slot allocator. Extension
mechanism already proven: `app/MadeiraJITHelper` (NSExtension, `com.apple.ar.viewer`,
XPC) and, on `opengl-donor-local`, `app/MadeiraMemoryHost` (started like
LiveContainer's LiveProcess, XPC endpoint passed in the request,
`app/MadeiraMemoryHost/MemoryHost.m`), whose notes say iOS 27's jetsam table gives that
extension point no memory limit.

What it would take:
1. **A second Wine build target**: the extension binary must link `libntdll_unix.a`,
   `libwin32u_unix.a`, the FEX bridge and the JIT allocator. Today they are linked into
   the app binary only.
2. **JIT in the extension**: Madeira needs a debugger attached per process. StikJIT's
   `enableJIT(targetPID:...)` takes a pid, so the helper can attach to the extension's
   pid; the extension builds its own pool and the pool description must come from its
   own environment (0036 equivalent: `MADEIRA_*` pool variables must not be inherited
   from the parent's Windows environment).
3. **Server connection**: pass the client end of the server socket to the extension
   (XPC can carry a file descriptor; the MemoryHost already receives an
   `NSXPCListenerEndpoint`). Wine's protocol passes further fds over that socket, which
   works across processes.
4. **Server paths that assume one task**, each needing a remote variant through an
   XPC call into the extension: `ios_fill_thread_context`/`set_thread_context`,
   `ios_thread_mach_hold`/`release` (suspend), `send_thread_signal`,
   `read_process_memory`/`write_process_memory` (`build/wineserver/mach_ios.c`), plus
   anything in `server_ios.c`/`process_ios.c` that reads another pseudo-process's state
   directly (fd cache, proc ident, thread registry, `[proc-gate]` slots).
5. **Synchronization across processes**: fastsync cells and madsync objects live in
   process memory. Either keep the extension on server sync (correct, slower; the web
   helper is not frame-critical) or build a shared-memory engine like NutsSync
   (`os_sync_wait_on_address` with the SHARED flag, signals blocked under the lock,
   dead-holder takeover).
6. **Graphics**: the web helper renders through Chromium's software/GL path in
   single-process mode today; in an extension it cannot present into the app's
   layers, so its frames must go back over IOSurface (an XPC-transferable
   `IOSurfaceRef`) to the app's compositor.
7. **Address space in the extension**: NutsEmu found fixed mappings above
   0x7000000000 refused in their extension and reserved the area through the host
   (0037). Test the same on `com.apple.ar.viewer` before designing placement.
Effort L-XL. Do it only if the web helper's address space or memory is the limiting
factor on device logs; the lazy placeholders (rank 1) attack the same exhaustion first.

### 4d. Several visible windows at once

NutsEmu: the closed `winenuts` driver gives each window a Metal layer; patches only
show the supporting changes (no explorer: 0041, 0052; no Cocoa main thread: 0035;
several Wine instances at once: 0030). Their demo shows windows from different
processes at the same time.

Madeira today: **desktop mode** (`MADEIRA_DESKTOP=1`, `explorer.exe /desktop=shell,WxH`,
`ContentView.swift:1845`/`2008`) already composites every top-level window as its own
`CALayer` (`winios_layer_for`, `Winios.m:1195`), with DXMT swapchains as `CAMetalLayer`
sublayers framed to the client rect (`Winios.m:1238-1330`) and a desktop-fit option.
Game mode uses one full-screen layer. A known problem is recorded for a second GUI
pseudo-process in desktop mode (the `env.MADEIRA_DESKTOP` note in
`ConfigCatalog.generated.swift`: a NULL window procedure through shared user32 data).

Steps: fix the second-GUI-process issue first; give Zink/GLES presentation the same
per-HWND layer (`madeira_zink_target_present` already takes an HWND); add touch window
management (drag title bar, focus/raise on tap, minimise list) in the compositor;
offer desktop mode for launchers by default with a kill switch. Effort M.

### 4e. GameController-based XInput

| Feature | NutsEmu (closed DLL + 0066) | Madeira |
|---|---|---|
| Pads | 4 | 4 stable slots, touch merges into slot 0 (docs/CONTROLLERS.md) |
| Reading | GameController in app, own `xinput1_4.dll` | GameController at 250 Hz, `WiniosGamepad.c` snapshot, win32u query, Wine's xinput tries it before HID |
| HID bypass | yes, no HID at all | yes in XInput mode; optional HID DualSense/generic device (`MADEIRA_PAD_MODE=hid`) |
| Rumble | yes | yes (ml2106, CoreHaptics; needs rebuilt xinput1_1-1_4, docs/CONTROLLERS.md:359) |
| Battery | yes | committed XInput: no (`wine/dlls/xinput1_3/main.c:1231` returns UNKNOWN/EMPTY); HID mode: yes (GCDeviceBattery); XInput battery in progress (ml2170, uncommitted) |
| Windows.Gaming.Input | XInput pads as Gamepads (0066) | committed: only in HID mode; host pads in progress (uncommitted) |
| DirectInput | not visible in the release | opt-in DirectInput pad (`MADEIRA_DINPUT_PAD`) |

Missing in the committed tree: XInput battery (publish `GCDeviceBattery` per slot,
answer `XInputGetBatteryInformation`; S) and WGI in XInput mode (0066's provider; S-M).
Both are being done in the working tree (uncommitted). One design point from 0066
worth keeping: it polls XInput once a second for pads that come and go, because no
device-arrival notification exists without Wine's driver host. Also confirm the
rebuilt xinput DLLs carrying the motor forwarding are in the farm.

### 4f. NutsSync compared with fastsync and madsync

| | NutsSync | fastsync (default) | madsync (opt-in) |
|---|---|---|---|
| Scope | all Wine 11.18 inproc objects: sem, mutex, event, alert; wait-any/all | events and semaphores, single-handle, non-alertable | full ntsync semantics |
| State | shared memory region (fd from server) | cells shared with the server, in-process | process memory, pthread mutex + Mach semaphores |
| Cross-process | yes | no | no |
| Waiting | per-waiter word, `os_sync_wait_on_address` SHARED | park ≤ 2 ms then server | per-waiter Mach semaphore |
| Lock safety | signals blocked; dead holder taken over after 1 s | n/a | signals blocked (`madsync.c:94`) |
| Alertable `SleepEx(0,TRUE)` | answered locally when no APC | goes to server | goes to server |

Worth taking: (1) the zero-length alertable sleep shortcut (their job-worker case:
hundreds of server round trips per second per thread; S, needs the alert state
visible to the client); (2) if 4c happens, a shared-memory engine on the NutsSync
model. Madsync's open problem (services.exe RPC never answered,
`env.MADEIRA_MADSYNC_SESSION` note) is worth comparing with NutsSync's handling of
abandoned mutexes and dead waiters.

### 4g. Other notable items

- **Images hosted directly in the JIT pool (0005).** The single largest architectural
  difference. NutsEmu has no pool copies, no IAT sync, no exec-fault redirect, no
  per-child ntdll copy: the image's address is executable. Each child still gets its
  own ntdll because each instance maps its own. For Madeira this would be an L
  project with a device spike first: allocate an ARM64EC DLL's view inside the pool,
  read sections through the RW alias, relocate through the alias, and check that
  `.data` pages of the RX mapping can be made RW and back under TXM.
- **Lazy placeholders (0093)** and **decommit zeroing on read-only edges (0092)**:
  section 2.7.
- **32-bit stand-ins (0048)**: not needed with real WoW64; the idea (substitute a
  64-bit helper for a known 32-bit one) is only useful for host-provided helpers.
- **Media Foundation on AVFoundation (0084)**: `AVAssetReader` gives decoded frames
  for the common intro-video containers with no FFmpeg demuxer, and needs no decoder
  MFTs. Madeira's FFmpeg + VideoToolbox route is more general but 64-bit `wg_parser`
  is still opt-in (`MADEIRA_WG_64BIT`). Their rule that every AVFoundation call runs on
  one serial queue (a thread killed inside AVFoundation left a system lock held) applies
  to Madeira's VideoToolbox/AudioToolbox calls too.
- **AVX in the extended state (0086)**: section 2.11; S when AVX is enabled.
- **Microphone input**: the developer says NutsEmu has it; Madeira's audio driver
  refuses capture endpoints (`build/ntdll-unix/audio_null_ios.c:1084`). M (AVAudioSession
  record category, RemoteIO input bus, the capture half of the unix table).
- **Offline switch (0063)**: S; a privacy feature independent of Steam's offline logon.
- **Release a dead process's memory (0024)**: M; owner tag on views.
- **KUSD at a build-time address (0004)**: M; removes the remaining Mach exceptions from
  Wine's own PE reads of KUSD.
- **Fixed-slot TEB (0008)**: M; would let Wine's PE modules stop depending on the x18
  patcher. Not a priority while the patcher works.
- **Build hygiene from their script**: per-settings build directories (no full rebuild
  when toggling options), "essential modules rebuilt without `-k`" so a broken ntdll
  cannot ship silently, content-hash timestamps for patched files. Useful for
  `.xtool/upstream-build`.
- **Version gap**: NutsEmu is on Wine 11.18 with ntsync-style inproc sync and the EGL
  WGL path. A Madeira rebase past 11.4 would bring those, plus the 0073 bug.
