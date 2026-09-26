# Runtime memory and performance

## ml1960 follow-up

The newer attachments still show guest VA exhaustion after ml1950. The dominant
large allocations originate on rendering threads. This round addresses retained
CPU batch vectors in D3D9 and a separate secondary-alias CAS fault. See
[COMPATIBILITY_ML1960.md](COMPATIBILITY_ML1960.md) for evidence, memory accounting,
kill switches, tests and unresolved hangs. No new-build FPS or crash-prevention
result is established yet; keep the older findings in their original build context.

Device log 65 confirms ml1940's policies executed, but the long-session crash
recurred. The guest window reached 3,945 MiB mapped, leaving 150 MiB spread over
small holes. Its largest hole was 1.875 MiB; the failed request needed 2.1875
MiB. Lower physical RAM usage does not provide more 32-bit virtual addresses.
The owner of most live anonymous allocations remains unknown.

This round adds an allocation-failure recovery path to Wine's 32-bit heap.
It atomically takes ownership of cached LFH groups and frees only groups whose
entire free bitmap is set. Partially used groups go back to their shared list.
After any successful releases the original allocation retries once; a second
failure stays a real failure. No application pointer moves or requested size
changes. It preserves normal allocation behavior until pressure occurs.
A released group may become reusable space inside a still-live subheap; guest
addresses return to the VM allocator only when an entire region can be released.
This corrects the lack of empty-group reclamation on this path; device testing
must establish whether those groups account for enough of this workload's
address consumption to prevent its crash. Direct VirtualAlloc callers and live
heap blocks do not gain space from this recovery.

Diagnostics are enabled by default for Dock launches, with independent rollback:

| Config environment key | Default | Purpose |
| --- | --- | --- |
| MADEIRA_HEAP_RECLAIM | 1 | Reclaim empty LFH groups before one allocation retry |
| MADEIRA_HEAP_STATS | 1 | Live large/subheap bytes, free subheap capacity and allocation sites |
| MADEIRA_VA_DIAGNOSTICS | 1 | Creator thread and size of retained large anonymous mappings |
| MADEIRA_CPU_DIAGNOSTICS | 1 | Ten-second per-thread CPU deltas without suspending execution |

Use `env.KEY = 0` in madeira.cfg and fully restart to disable a policy.
`[heap-live]` and `[heap-site]` run once per 65,536 large allocations per heap
and at failure. Caller addresses come from private allocator metadata, not a
stack scan; the existing arena layout and application user-value field remain
intact. Zero denotes LFH/internal or pre-policy unattributed blocks. These are
live allocations, not proof of leaks. The 32-site snapshot reports overflow
bytes. Allocation/free counters begin when the policy is enabled and should not
be interpreted as a complete lifetime balance for preexisting blocks.

`[va-origin]` is emitted with the existing failure census. It groups anonymous
views >=1 MiB by exact size and creation TID (not current ownership), shows the
largest eight of up to 128 tracked pairs and reports overflow explicitly.
View splits inherit their original creator. The initial protection categories
still do not indicate current committed/physical memory.

`[cpu-budget]` and `[cpu-thread]` use Mach thread CPU times and stable kernel
thread IDs. They release all queried Mach rights, skip failed queries and
handle table capacity and thread replacement. At most six busy threads are
printed per ten seconds. Roles 0/1/2 mean presenter/encoder/finisher, -1 means
another thread. A 100% thread uses approximately one core over the interval;
the Mach port also correlates with existing exception-handler registration
lines that name the Windows TID, even for threads without descriptive names.
aggregate live-thread core equivalents exclude unmatched/new/dead threads.
Run state is just the state at sampling time. No register capture or thread
suspension is used, and older intrusive samplers remain off.

Log 65 contains 52 frame windows: median 43.75 FPS, presenter CPU 4.9 ms and
waiting 17.55 ms. That does not establish which worker or dependency limits
the frame. GPU command averages are also not a frame budget. This follows
Apple's emphasis on correlating CPU, synchronization and GPU activity in its
[Metal performance guidance](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/).
The goal remains better sustained FPS; no gain or 60 FPS capability is proven
by these changes. Broad scheduler/renderer changes would currently be guesses.

Validation: production-source sanitizer tests cover empty/partial ownership,
2,000 concurrent frees, backend release failure and rollback; CPU diagnostics
cover port reuse, failed queries, ten-second cadence, 300-thread overflow and
Mach-right cleanup. Existing heap policy, guest placement/window and Dock
configuration/performance-policy tests pass. The i386 and native Wine builds
pass. Device validation is still required.

Install the new IPA over the current app, fully restart, enable JIT and repeat
the long play/transition. Export the log even on success. The new heap reports
should identify which allocator/caller retains the address space, and CPU
reports should distinguish a busy worker from an idle presenting thread.
Private Dock and real authentication/ownership/DRM checks are unchanged.

## ml1940 history: 32-bit heap pressure and allocation overhead

Log 64 reaches normal authenticated Dock gameplay, then a 32-bit allocation
fails with STATUS_NO_MEMORY. The guest window contains 3,877 MiB of views with
218 MiB total free, but its largest gap is only 0x230000 bytes; the failed
reservation needs 0x240000. The guest exits with status 3, followed by teardown
faults. Dock subsequently exits normally. The reduced 512 MiB JIT pool does
not report exhaustion. This is a guest virtual-address-space failure; physical
memory and available contiguous guest addresses are different resources.

The view census labels 3,173 MiB as `reserved`, meaning reserved without commit
at initial creation. That flag does NOT prove those pages are still uncommitted.
The log does not identify every live allocation or establish a particular leak.
The code does show Wine's heap subregions grow to 0xfd0000 bytes, and those exact
requests occur in the log. Released physical pages alone do not free a live
reservation: see Microsoft's [VirtualFree contract](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualfree).

## Changes

With Dock selected, Madeira defaults these independently reversible flags to 1
before launching Wine. Explicit config overrides win. The loader applies them
only in i386 ntdll, after process parameters are initialized and before guest
application threads start. Environment queries never occur under a heap lock.

- `MADEIRA_HEAP_COMPACT`: growable subheaps stop doubling at 2 MiB instead of
  approximately 16 MiB, bounding reservation slack and allowing smaller regions
  to become wholly free. An allocation failure retries down to the actual
  aligned requirement; the old retry loop stopped near 4 MiB. Fixed heaps,
  individual requested block sizes, alignment and the guest VA ceiling remain
  unchanged. This is an address-pressure mitigation; device reproduction must
  establish whether it prevents this workload's later failure.
- `MADEIRA_HEAP_COMBINED`: fully committed regions use one MEM_RESERVE|MEM_COMMIT
  call instead of separate reserve and commit calls. Microsoft explicitly
  supports this [VirtualAlloc operation](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualalloc).
  The log contains about 5.55 million reserve calls in its reported intervals.
  This removes one VM call from each eligible pair, including its guest/native
  transition, lock and notifications. It does not cache freed blocks or enlarge
  the JIT pool. Partially committed regions retain split allocation.
- When either heap policy is enabled, a failed split commit releases the newly
  created reservation instead of leaking it. This source defect is verified;
  the log does not prove it caused the reported crash.

Logs: `[dock-heap] ml1940` reports the app's selected defaults, and
`[heap-policy] ml1940` confirms the 32-bit loader consumed them. Set either
`env.MADEIRA_HEAP_COMPACT = 0` or `env.MADEIRA_HEAP_COMBINED = 0` in madeira.cfg
and fully restart for independent A/B. Set both to 0 for the old heap behavior.
No title detection, executable patching, private Dock edit or authentication
change is involved.

Rebuilding i386 ntdll also exposed preexisting ARM-only diagnostics in shared
sources. The CHPE detach probe and ARM counter probes are now guarded for their
supported architecture. The local build adapter rejects failed make targets even
if an older DLL still exists, preventing stale output from being called a pass.

## Evidence and validation

Across 88 reported frame windows, median FPS is 43.15; total frames divided by
reported window durations gives about 43.87 FPS. These include scene/menu/loading
variation and do not contradict lower FPS during demanding gameplay. Median
presenting-thread CPU time is 6.05 ms and waiting is 16.85 ms. Much of that wait
is unattributed, so it is not valid to call it CPU computation or assert a
particular synchronization fix. Median reported GPU command time is 4.08 ms;
there can be several GPU commands per frame, so that is not a whole-frame GPU
budget. Peak reported footprint is 2,871 MiB.

The new ASan/UBSan host test compiles production allocation/growth paths with a
fault-injecting VM backend: combined/split calls, exact flags, failure cleanup,
aliasing of size arguments, non-growable heap rejection, growth caps, small-gap
retry, finite failure and rollback. Existing Dock sizing/configuration tests
also pass. These tests verify mechanics; they do not measure device RAM/FPS.

Device trial: install the new IPA over the current app, fully restart, enable
JIT and repeat the long session and transition. Export the log whether it fails
or succeeds. Compare the same scene/settings after warm-up, including FPS and
footprint; check both ml1940 policy markers. Broad compatibility and the
performance/long-session benefit remain unverified until that test.

When comparing the next VA census, use total mapped bytes and free-gap sizes,
not the `reserved` bucket alone: combined reserve+commit changes the initial
classification to anonymous/committed even when the same address range is used.
A smaller `reserved` bucket by itself is not evidence of memory savings.

ml1940 build completed and content-verified (2026-09-25):
`xtool/Madeira.ipa`, label `ml1940 · 09-25 01:50`, 166,363,201 bytes,
1,389 entries. SHA-256:
`55bdb43208945e6363d446698f36c58305f9a0fd83d086c9c992e2d8ef48a498`.
Only the app executable, i386 ntdll, Info.plist and resource seals differ from
ml1910. All 1,271 Windows resources match the source bundle; no entries removed.
CRC, new Swift/PE markers, stripped unchanged Dock, source/login/Valve-DLL
exclusions and seals pass. Native/PE build had zero missing cross-imports.
Reports: .xtool/logs/ml1940-build.log, ml1940-wine-i386-build.log,
ml1940-verified.json and ml1940-log64-analysis.json. Existing unrelated Swift
warnings remain. No device run, measured FPS gain, commit or push in this round.
Install over the app, fully restart and repeat the transition/long session.


ml1950 final IPA verified (2026-09-25): `xtool/Madeira.ipa`, label
`ml1950 · 09-25 02:37`, 166,368,757 bytes / 1,389 entries.
SHA-256: `c57e3000dd41a513736ebe2c784ed27507f9447da58f51fa0c2fbb4b280b68fc`.
i386 ntdll: `04f8314e250ba02418db6878dbc25fcb62cb8646fbfa89e7713727afc90ca4c9`.
All 1,271 Windows resources match the current source bundle; CRC, final CPU
Mach-port marker, new heap/VA diagnostics, stripped unchanged Dock, notices,
source/login/Valve-DLL exclusions and seals pass. Only Madeira, i386 ntdll,
Info.plist and CodeResources differ from ml1940; no entries added or removed.
The final rebuild includes the acquire read pairing with concurrent frees.
Native build: 36/36 ntdll and 46/46 win32u objects, wineserver success; PE import
closure has zero missing imports. Production VA-census sanitizer tests also
pass (grouping, exclusions, empty window, capacity overflow and rollback).
Existing unrelated Swift/toolchain warnings remain. No device crash prevention
or FPS gain is confirmed yet. Install over the current app, fully quit/reopen,
enable JIT, repeat the long session and export the log, even on success.
Reports: .xtool/logs/ml1950-build.log, ml1950-native-build.log,
ml1950-wine-i386-build.log, ml1950-log65-analysis.json, ml1950-verified.json.
Verifier: .xtool/verify-ml1950.py. No private Dock changes, commit or push.
