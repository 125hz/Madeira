#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2021 donor pool: no permanent region windows, and the overlay's view of the tier
(build/ntdll-unix/virtual_ios.c, app/Madeira/Library.swift).

The first port mapped every donated region VM_FLAGS_ANYWHERE when the app registered it, before
Wine held the 32-bit guest-window placeholder; on device the windows took the only free 4 GB-aligned
slot and 32-bit programs failed at 'guest-window-reserve'. Static anchors only: registration maps a
window only behind MADEIRA_DONOR_WINDOWS=1, a give maps the freed range for its zeroing and unmaps it,
the stats function the overlay reads exists on both sides of the bridge, and the field is offered.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
swift = (ROOT / 'app/Madeira/Library.swift').read_text(encoding='utf-8', errors='replace')
bridge = (ROOT / 'app/Madeira/Madeira-Bridging-Header.h').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

add = src[src.index('int madeira_donor_pool_add( unsigned int entry, unsigned long long size )'):src.index('void madeira_donor_pool_set_pressure(')]
check(re.search(r'getenv\( "MADEIRA_DONOR_WINDOWS" \);\s*/\* 1: a permanent ANYWHERE window per region', add) is not None
      and "int permanent = windows && windows[0] == '1';" in add,
      'the permanent windows are opt-in (MADEIRA_DONOR_WINDOWS=1), with the note the config catalog takes')
check('if (permanent && mach_vm_map( mach_task_self(), &window, size, 0, VM_FLAGS_ANYWHERE, entry' in add,
      'registration maps a region window only when they are opted in')
check('ios_donor_reg[n].window = permanent ? (char *)window : NULL;' in add,
      'without them the region keeps no window (NULL)')
check(add.count('VM_FLAGS_ANYWHERE') == 1, 'no other ANYWHERE mapping at registration')

give = src[src.index('static void ios_donor_give( uint64_t off, size_t len )'):src.index('#else\nstatic uint64_t ios_donor_take( size_t len ) { (void)len;')]
check('if (ios_donor_reg[r].window) madvise( ios_donor_reg[r].window + off % ios_donor_region, len, MADV_ZERO );' in give,
      'a region with a window is zeroed through it, as before')
check('mach_vm_map( mach_task_self(), &tmp, len, 0, VM_FLAGS_ANYWHERE, ios_donor_reg[r].entry, off % ios_donor_region, FALSE,' in give
      and 'madvise( (void *)tmp, len, MADV_ZERO );' in give and 'mach_vm_deallocate( mach_task_self(), tmp, len );' in give,
      'otherwise the freed range alone is mapped, zeroed and unmapped')
check('ios_donor_free_insert( off, len );' in give and give.index('ios_donor_free_insert') > give.index('mach_vm_deallocate'),
      'the range joins the free list after the zeroing')
check('the range is reused unzeroed' in give, 'a failed temporary window is reported (bounded) and the give still completes')

check('void madeira_swap_overlay_stats( unsigned long long *file_mb, unsigned long long *donor_mb, unsigned long long *donor_pool_mb,' in src
      and '*donor_guarded = ios_donor_guarded;' in src and '* ios_donor_region) >> 20;' in src,
      'madeira_swap_overlay_stats reports file-backed MB, donor MB, the pool size and guarded takes')
check('void madeira_swap_overlay_stats(unsigned long long *file_mb, unsigned long long *donor_mb, unsigned long long *donor_pool_mb,' in bridge,
      'the bridging header declares it for Swift')
check('"RAM", "Swap & donor", "Battery"' in swift, 'the overlay settings offer the Swap & donor field')
check('madeira_swap_overlay_stats(&file, &donated, &pool, &guarded)' in swift
      and 'if model.overlayFields.contains("Swap & donor") {' in swift,
      'the metrics view samples it once a second while the field is shown')
check('"Donated \\(donatedMB)/\\(donorPoolMB) MB' in swift and '"Swap \\(swapFileMB) MB"' in swift,
      'the pill shows Donated used/pool MB (guarded count when non-zero) and the swap-file MB')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_DONOR_WINDOWS"' in text, 'the config catalog documents env.MADEIRA_DONOR_WINDOWS')

print(f'check-donor-pool: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
