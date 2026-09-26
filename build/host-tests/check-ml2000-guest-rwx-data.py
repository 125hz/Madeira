#!/usr/bin/env python3
"""ml2000: anonymous x64-guest RWX memory stays host data (MADEIRA_GUEST_RWX_DATA).

1. Compiles the production EC-bitmap scan (virtual_ios.c, between the
   "ml2000 ec-bitmap scan" markers) and checks it against a brute-force model
   of set_arm64ec_range() over random ranges, word boundaries and the
   out-of-bitmap case (must report "unknown" = keep the old path).
2. Source-checks every condition of ios_guest_rwx_is_host_data(), its
   placement in mprotect_exec() (after ml1030, before the pool machinery), the
   EC_CODE request window in allocate_virtual_memory(), the [wr-strip] heal,
   the Mach-thread process lookup, and the kill switch on both Wine and FEX
   sides.
3. Source-checks the FEX half: 16 KB host-page trap/untrap, host-data-only
   DisableSMCDetection on iOS, the ARM64EC-only mode, the Module.cpp assist
   gate, the Core.cpp native-activation decline and the 512-slot tracker.

Device execution is still required; this proves structure and the bitmap math.
"""
from pathlib import Path
import random
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
sig = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
inval = (root / 'FEX/Source/Windows/Common/InvalidationTracker.cpp').read_text()
inval_h = (root / 'FEX/Source/Windows/Common/InvalidationTracker.h').read_text()
module = (root / 'FEX/Source/Windows/ARM64EC/Module.cpp').read_text()
core = (root / 'FEX/FEXCore/Source/Interface/Core/Core.cpp').read_text()

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def body_of(src, signature):
    start = src.index(signature)
    brace = src.index('{', start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
    raise AssertionError('unterminated body: ' + signature)


# ---------------------------------------------------------------- 1. bitmap
begin = virt.index('/* ml2000 ec-bitmap scan begin */')
end = virt.index('/* ml2000 ec-bitmap scan end */')
scan = virt[begin:end]

cases = []
rng = random.Random(2000)
WORDS = 64                      # 64 words = 4096 pages = 16 MB of VA
for _ in range(4000):
    nbits = rng.choice([0, 1, 2, 5])
    bits = sorted({rng.randrange(WORDS * 64) for _ in range(nbits)})
    b = rng.randrange(0, WORDS * 64 * 4096 + 0x20000)
    size = rng.choice([1, 0xfff, 0x1000, 0x1001, 0x4000, 0x10000, 0x40000, rng.randrange(1, 0x300000)])
    cases.append((bits, b, b + size))
# exact word/page edges
for p in (0, 63, 64, 127, 4095):
    for off in (0, 1, 0xfff):
        cases.append(([p], p * 4096 + off, p * 4096 + off + 1))
        cases.append(([p], (p + 1) * 4096, (p + 1) * 4096 + 0x1000))
        cases.append(([p], max(0, p * 4096 - 0x1000), p * 4096))


def model(bits, b, e):
    first, last = b >> 12, (e + 0xfff) >> 12      # set_arm64ec_range's [idx, end)
    if (last - 1) // 64 >= WORDS:
        return 1                                   # past the bitmap: unknown
    return int(any(first <= p < last for p in bits))


harness = ['#include <stdint.h>', '#include <stdio.h>', '#include <string.h>', '#include <stddef.h>',
           'typedef uint64_t UINT64;', scan,
           'static UINT64 map[%d];' % WORDS,
           'int main(void) { int bad = 0;']
for bits, b, e in cases:
    harness.append('memset(map, 0, sizeof(map));')
    for p in bits:
        harness.append('map[%d] |= (UINT64)1 << %d;' % (p // 64, p % 64))
    harness.append('if (ios_ec_bitmap_any(map, %d, 0x%xULL, 0x%xULL) != %d) { bad++; '
                   'printf("mismatch b=0x%x e=0x%x\\n"); }' % (WORDS, b, e, model(bits, b, e), b, e))
harness.append('printf("%d bitmap cases, %d mismatches\\n", ' + str(len(cases)) + ', bad); return bad != 0; }')

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'scan.c'
    exe = Path(tmp) / 'scan'
    c.write_text('\n'.join(harness))
    subprocess.run(['cc', '-O1', '-Wall', '-Werror', '-o', str(exe), str(c)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    print(r.stdout.strip())
    check(r.returncode == 0, 'EC-bitmap scan disagrees with the set_arm64ec_range model')

# ------------------------------------------------------------- 2. Wine side
helper = body_of(virt, 'static int ios_guest_rwx_is_host_data( const void *base, size_t size )')
for needle, what in [
    ('ios_guest_rwx_data_enabled()', 'kill switch consulted'),
    ('!arm64ec_view', 'requires an ARM64EC bitmap'),
    ('ios_ec_code_request', 'declines an EC_CODE allocation in progress'),
    ('ios_jit_current_peb()', 'asks the CURRENT process'),
    ('ios_mach_exc_teb', 'Mach exception thread resolves the faulting process'),
    ('ios_wow_base_for_peb( peb )', 'declines a WoW64 asking process'),
    ('ios_wow_base()', 'declines a not-yet-bound WoW window'),
    ('ios_wow_addr_in_any_window( base )', 'declines any 32-bit guest window address'),
    ('IMAGE_FILE_MACHINE_AMD64', 'x64 main image only'),
    ('ios_jit_rx_base_global', 'declines the JIT pool'),
    ('find_view( base, size )', 'requires a Wine view'),
    ('SEC_IMAGE | VPROT_SYSTEM | VPROT_ARM64EC', 'declines image/system/EC views'),
    ('ios_ec_bitmap_any(', 'declines EC-bitmap code'),
    ('ios_jit_anon_alias_overlaps(', 'declines ranges that already have an alias'),
]:
    check(needle in helper, 'helper: ' + what)
check(re.search(r'getenv\( "MADEIRA_GUEST_RWX_DATA" \);\s*cached = \(s && \*s == \'0\'\) \? 0 : 1;', virt),
      'Wine kill switch: MADEIRA_GUEST_RWX_DATA=0 disables, default on')
check('[rwx-data] ml2000 MADEIRA_GUEST_RWX_DATA=' in virt, 'Wine one-time switch log')

mpe = body_of(virt, 'static inline int mprotect_exec( void *base, size_t size, int unix_prot )')
i_1030 = mpe.index('ios_guest_image_is_host_data( base, size )')
i_2000 = mpe.index('ios_guest_rwx_is_host_data( base, size )')
i_pool = mpe.index('ml247: catch WHO narrows maxprot')
i_carve = mpe.index('anonymous RWX request')
check(i_1030 < i_2000 < i_pool < i_carve, 'decision sits after ml1030 and before any pool machinery')
decision = mpe[i_2000:i_pool]
check('unix_prot &= ~PROT_EXEC;' in decision and 'if (!unix_prot) unix_prot = PROT_READ;' in decision,
      'decision drops EXEC (PAGE_EXECUTE alone -> READ)')
check('ios_rwx_data_n <= 24' in decision and '[rwx-data] ml2000 #' in decision, 'first 24 decisions logged')

avm = body_of(virt, 'static NTSTATUS allocate_virtual_memory(')
i_enter = avm.index('server_enter_uninterrupted_section( &virtual_mutex, &sigset );')
i_set = avm.index('ios_ec_code_request = (attributes & MEM_EXTENDED_PARAMETER_EC_CODE) != 0;')
i_map = avm.index('map_view( &view, base, size, type, vprot')
i_ecr = avm.index('set_arm64ec_range( base, size );')
i_clr = avm.index('ios_ec_code_request = 0;')
i_leave = avm.index('server_leave_uninterrupted_section( &virtual_mutex, &sigset );')
check(i_enter < i_set < i_map < i_ecr < i_clr < i_leave, 'EC_CODE flag raised under virtual_mutex before reserve, cleared before release')

heal = body_of(virt, 'int ios_guest_rwx_heal_prot( const void *addr, int want )')
check('ios_guest_rwx_is_host_data(' in heal and 'want & ~PROT_EXEC' in heal and 'ios_guest_rwx_data_enabled()' in heal,
      'wr-strip heal drops EXEC only for host-data pages, behind the switch')
i_strip = sig.index('enum { WR_HPAGE = 0x4000 };')
strip = sig[i_strip:i_strip + 900]
check(strip.index('ios_guest_rwx_heal_prot( siginfo->si_addr, want )') < strip.index('mprotect( hp, WR_HPAGE, want )'),
      'wr-strip heal adjusts want before mprotect')
wrap = body_of(sig, 'static int ios_mach_deliver_guest_exception( thread_t thread, arm_thread_state64_t *state,\n'
                    '                                             arm_neon_state64_t *neon, int have_neon,\n'
                    '                                             int exception, uintptr_t fault_addr,\n'
                    '                                             uintptr_t thread_teb )\n{')
check('ios_mach_exc_teb = thread_teb;' in wrap and 'ios_mach_exc_teb = 0;' in wrap, 'Mach wrapper publishes/clears the faulting TEB')

# -------------------------------------------------------------- 3. FEX side
check('bool IosGuestRwxDataMode();' in inval_h, 'mode declared in InvalidationTracker.h')
mode = inval[inval.index('#if defined(FEX_IOS_HOST) && defined(ARCHITECTURE_arm64ec)\nbool IosGuestRwxDataMode()'):]
mode = mode[:mode.index('#endif') + 6]
check('getenv("MADEIRA_GUEST_RWX_DATA")' in mode and "(E && E[0] == '0') ? 0 : 1" in mode, 'FEX kill switch mirrors Wine')
check('#else\nbool IosGuestRwxDataMode() {\n  return false;' in mode, 'WoW64/non-iOS builds: mode always off')
check('constexpr uint64_t IosHostPageSize = 0x4000;' in inval, '16 KB host page')
rnd = body_of(inval, 'IosRange IosHostPageRound(uint64_t Address, uint64_t Size)')
check('if (!IosGuestRwxDataMode())' in rnd and 'return {Address, Address + Size};' in rnd, 'rounding is identity when off')
rwxav = body_of(inval, 'bool InvalidationTracker::HandleRWXAccessViolation(')
check('IosHostPageRound(Address, 1)' in rwxav and 'std::max(Host.Begin, Query.Interval.Offset)' in rwxav
      and 'std::min(Host.End, Query.Interval.End)' in rwxav, 'untrap clipped to the RWX interval')
check('InvalidateIntervalInternalLocked(UntrapBegin, UntrapEnd - UntrapBegin);' in rwxav, 'invalidates the whole untrapped range')
check(rwxav.index('InvalidateIntervalInternalLocked(UntrapBegin') < rwxav.index('NtProtectVirtualMemory('),
      'invalidate before unprotect (under CodeInvalidationMutex)')
prot = body_of(inval, 'bool InvalidationTracker::ProtectRWXIntervalsInternal(')
check(prot.index('IosHostPageRound(Address, Size)') < prot.index('const auto End = Address + Size;'), 'trap/untrap ranges rounded first')
det = body_of(inval, 'void InvalidationTracker::DetectMonoBackpatcherBlock(')
check(re.search(r'#ifndef FEX_IOS_HOST.*?DisableSMCDetection\(\);\s*#else.*?if \(IosGuestRwxDataMode\(\)\) \{.*?DisableSMCDetection\(\);',
                det, re.S), 'iOS disables SMC detection only in host-data mode')
check(det.index('DisableSMCDetection();\n  }\n#endif') < det.index('CTX.MarkMonoBackpatcherBlock(BlockEntry);'),
      'SMC trapping disabled before the backpatcher block is marked')
check('constexpr unsigned TrackerSlotCount = 512;' in inval and 'MADEIRA_FEX_TRACKER_WIDE' in inval
      and 'TrackerSlotTid[i] != Tid' in inval, '512-slot tracker with stale reclaim and kill switch')
def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)


check(not re.search(r'\bthread_local\b', strip_comments(inval)) and
      not re.search(r'\bthread_local\b', strip_comments(module[module.index('IosSmcNeedsLegacyAssist'):
                                                               module.index('IosSmcNeedsLegacyAssist') + 3000])),
      'no thread_local in changed FEX code')
gate = body_of(module, 'static bool IosSmcNeedsLegacyAssist(uint64_t FaultAddress)')
for needle, what in [('IosGuestRwxDataMode()', 'mode off keeps the assist'),
                     ('IosMonoResolveRW(FaultAddress, 1)', 'alias pages keep the assist'),
                     ('Info.Type == MEM_IMAGE', 'image pages keep the assist')]:
    check(needle in gate, 'Module.cpp gate: ' + what)
check('if (!IosSmcNeedsLegacyAssist(FaultAddress)) {' in module and
      module.index('if (!IosSmcNeedsLegacyAssist(FaultAddress)) {') < module.index('} else if (Ml1018IsByteRelStore) {'),
      'assist chain starts with the host-data gate')
act = body_of(core, 'static void IosMonoTryActivate(ContextImpl* CTX, FEXCore::Core::InternalThreadState* Thread)')
check(act.index('IosCoreGuestRwxDataMode()') < act.index('MarkMonoBackpatcherBlock'), 'native activation declined in host-data mode')
cmode = body_of(core, 'static bool IosCoreGuestRwxDataMode()')
check('#if defined(ARCHITECTURE_arm64ec)' in cmode and 'getenv("MADEIRA_GUEST_RWX_DATA")' in cmode, 'Core.cpp mode: ARM64EC only, same switch')
mbw = body_of(core, 'void ContextImpl::MonoBackpatcherWrite(')
check('!RW && IosCoreGuestRwxDataMode()' in mbw and 'ios_fex_mono_count_helper(0);' in mbw, 'alias miss is normal in host-data mode')

for tag_src, name in [(virt, 'virtual_ios.c'), (inval, 'InvalidationTracker.cpp'), (module, 'Module.cpp'), (core, 'Core.cpp')]:
    check('ml2000' in tag_src, name + ' carries the ml2000 tag')

if failures:
    for f in failures:
        print('FAIL:', f)
    raise SystemExit(1)
print('ml2000 guest-RWX-data checks: all passed')
