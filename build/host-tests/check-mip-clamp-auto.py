#!/usr/bin/env python3
"""ml2000: DXMT automatic (memory-pressure) mip clamp.

Compiles the production policy header (research/dxmt/src/d3d11/
d3d11_mip_clamp_policy.hpp) on the host and checks bias limits, the headroom
re-query cadence, the pressure decision and the rollback parser, then checks
that the texture path, the unix query and the wow64 entry are wired. This
proves the policy, not on-device memory savings.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
dxmt = root / 'research/dxmt/src'
policy = dxmt / 'd3d11/d3d11_mip_clamp_policy.hpp'

code = r'''
#include <cassert>
#include <cstdio>
#include "d3d11_mip_clamp_policy.hpp"
using namespace dxmt::mip_clamp;

int main() {
  /* bias limits */
  assert(ClampBias(1, 2048, 2048, 12, true) == 1);
  assert(ClampBias(1, 4096, 1024, 13, true) == 1);
  assert(ClampBias(1, 2048, 2048, 1, true) == 0);    /* MipLevels=1: nothing to drop */
  assert(ClampBias(1, 2048, 2048, 0, true) == 0);
  assert(ClampBias(1, 1028, 1028, 11, true) == 0);   /* 514 is not a whole number of blocks */
  assert(ClampBias(1, 1028, 1028, 11, false) == 1);  /* explicit path keeps its old rule */
  assert(ClampBias(1, 8, 8, 4, true) == 1);
  assert(ClampBias(1, 4, 4, 3, true) == 0);          /* physical top would be 2x2 */
  assert(ClampBias(4, 64, 64, 7, false) == 4);
  assert(ClampBias(4, 64, 64, 3, false) == 2);       /* at least one level stays */
  assert(ClampBias(3, 4096, 16, 13, false) == 2);    /* 16 >> 3 = 2 < 4 */
  assert(AutoSizeEligible(1024, 16) && AutoSizeEligible(16, 1024));
  assert(!AutoSizeEligible(1023, 1023));

  /* re-query cadence */
  const uint32_t T = 1024;
  assert(ShouldRequery(1, kHeadroomUnknown, T));
  assert(!ShouldRequery(2, 5000, T));
  assert(ShouldRequery(16, 5000, T));
  assert(!ShouldRequery(17, 5000, T));
  assert(ShouldRequery(17, 2047, T));                /* within 2x: every time */
  assert(!ShouldRequery(18, 2048, T));
  for (uint64_t n = 1; n < 100; n++) assert(!ShouldRequery(n, kHeadroomUnavailable, T));

  /* pressure decision */
  assert(!UnderPressure(kHeadroomUnknown, T));
  assert(!UnderPressure(kHeadroomUnavailable, T));
  assert(UnderPressure(0, T) && UnderPressure(1023, T));
  assert(!UnderPressure(1024, T));
  assert(!UnderPressure(10, 0));                     /* threshold 0 = never */

  /* rollback values */
  assert(IsOffValue("0") && IsOffValue("false") && IsOffValue("OFF") && IsOffValue(" no \n"));
  assert(!IsOffValue("") && !IsOffValue("1") && !IsOffValue("true") && !IsOffValue("01"));
  assert(!IsOffValue(nullptr));

  /* log rate limit */
  assert(ShouldLogClamp(1) && ShouldLogClamp(8) && !ShouldLogClamp(9) && ShouldLogClamp(64));

  /* scene-load model: headroom falls 12 MB per large texture from 3000 MB,
   * reduced by 3/4 of that once clamped. Mirrors MipClampAutoBias's order:
   * count, maybe re-query, decide. */
  double real = 3000; int64_t last = kHeadroomUnknown;
  unsigned queries = 0, clamped = 0, first_clamp = 0;
  for (uint64_t n = 1; n <= 512; n++) {
    if (ShouldRequery(n, last, T)) { last = (int64_t)real; queries++; }
    bool p = UnderPressure(last, T);
    if (p && !first_clamp) first_clamp = (unsigned)n;
    clamped += p;
    real -= p ? 3.0 : 12.0;
  }
  assert(first_clamp && last < (int64_t)T);
  /* sparse above 2x, every creation below it */
  assert(queries < 512 && queries > 300);
  /* the stale reading can lag by at most 15 creations above 2x T */
  std::printf("model: first clamp at #%u, %u clamped, %u queries\n",
              first_clamp, clamped, queries);
  return 0;
}
'''

with tempfile.TemporaryDirectory() as d:
    p = Path(d) / 't.cpp'
    o = Path(d) / 't'
    p.write_text(code)
    subprocess.run(['g++', '-std=c++20', '-O1', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', f'-I{policy.parent}', str(p), '-o', str(o)], check=True)
    subprocess.run([str(o)], check=True)

tex = (dxmt / 'd3d11/d3d11_texture_device.cpp').read_text()
for needle in ['#include "d3d11_mip_clamp_policy.hpp"', '"d3d11.mipClampAuto"', '"d3d11.mipClampAutoMB", 1536',
               '"MADEIRA_MIP_CLAMP_AUTO"', 'a.op = 7;', '[mip-clamp] ml2000 auto headroom=',
               'mip_clamp::ClampBias(1, width, height, mip_levels, true)',
               '} else if (eligible && auto_misc_ok) {']:
    assert needle in tex, needle
# explicit mipClampBC still wins: the auto branch is the else of it
assert tex.index('if (eligible && cached_clamp)') < tex.index('} else if (eligible && auto_misc_ok)')

unix = (dxmt / 'winemetal/unix/winemetal_unix.c').read_text()
case7 = unix[unix.index('case 7: {   /* ml2000'):]
case7 = case7[:case7.index('break;\n  }') + 10]
assert 'os_proc_available_memory()' in case7 and 'wmtr_enabled()' in case7 and 'a->ret = 1;' in case7
wow = unix[unix.index('static NTSTATUS _madeira_ctl_wow64(void *args)'):]
wow = wow[:wow.index('\n}') + 2]
assert 'a->op == 7' in wow and 'return _madeira_ctl(args);' in wow and 'STATUS_NOT_IMPLEMENTED' in wow
print('mip clamp auto: ok')
