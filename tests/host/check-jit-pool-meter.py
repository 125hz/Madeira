#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The performance overlay's JIT memory field (app/Madeira/JITPoolMeter.swift).

Feeds log lines shaped like the JIT pool's own (a CS2 session: the pool shrunk to
560 MB, then ran out loading v8.dll) and checks the overlay text. Synthetic only.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
checks = r'''
assert(JITPoolMeter.text(JITPoolMeter.current) == nil)
JITPoolMeter.note("[22:02:40.904] [ERR] ml1036: no hole fits a 896MB pool — SHRINKING to 560MB")
JITPoolMeter.note("[22:02:41.548] [OK] JIT pool: RX=0x148000000, RW=0x7000000000, size=560MB")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 0/560 MB (small)")
JITPoolMeter.note("[jit-pool] image 0x119810000+0x70000 (?) → pool 0x148004000 used=0x78000/0x23000000 tramp+0x4000")
JITPoolMeter.note("[jit-pool] reused freed range off=0x1000 size=0x2000 (freelist 1 ranges) no-madvise")
JITPoolMeter.note("[jit-pool] image 0x71ffcf0000+0x110000 (ntdll.dll) → pool 0x148078000 used=0x17600000/0x23000000 tramp+0x8000")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 374/560 MB (small)", JITPoolMeter.text(JITPoolMeter.current)!)
JITPoolMeter.note("[jit-pool] EXHAUSTED (image 0x73f5f00000+0x3059000): want=0x3060000 bump=0x17664000/0x23000000 tail_resv=0xa008000")
assert(JITPoolMeter.current.exhausted == 1 && JITPoolMeter.text(JITPoolMeter.current) == "JIT FULL 560 MB")
JITPoolMeter.note("[xp] 22:36:38.872 +35.70 dt=315 cpu=25")
JITPoolMeter.reset()
assert(JITPoolMeter.current == JITPoolMeter.State())
JITPoolMeter.note("[jit-pool] image 0x1+0x1 (x.dll) → pool 0x2 used=0x100000/0x25000000 tramp+0x4000")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 1/592 MB")
assert(JITPoolMeter.hexPair("used=0x10", after: "used=0x")! == (0x10, 0))

// A split pool: 880 MB span, 64 MB hole at [464, 528) MB; pool-mid adds a 16 MB hole 2.
JITPoolMeter.reset()
JITPoolMeter.note("JIT pool: RX=0x148000000, RW=0x7000000000, size=880MB")
JITPoolMeter.note("[jit-pool] split pool: RX [0x148000000,0x165000000) + [0x169000000,0x17f000000) as one span of 0x37000000; hole [0x1d000000,0x21000000) (64 MB: the main thread's stack) is never handed out -- images 0x1d000000 below it, FEX code from the top")
assert(JITPoolMeter.current.holes == [JITPoolMeter.Hole(start: 0x1d000000, end: 0x21000000)])
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 0/816 MB (split)", JITPoolMeter.text(JITPoolMeter.current)!)
JITPoolMeter.note("[jit-pool] image 0x1+0x1 (a.dll) → pool 0x2 used=0x6400000/0x37000000 tramp+0x4000")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 100/816 MB (split)", JITPoolMeter.text(JITPoolMeter.current)!)
JITPoolMeter.note("[jit-pool] anon RWX 0x5 size=0x1000000 → used=0x22000000/0x37000000 NEW off=0x21000000 tid=0024 peb=0x6 rev=ml625")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 480/816 MB (split)", JITPoolMeter.text(JITPoolMeter.current)!)
JITPoolMeter.note("[jit-pool] pool-mid: third region RX [0x169000000,0x16a000000) (16 MB) between the holes; hole 2 [0x22000000,0x23000000) (16 MB, the main thread's stack) is never handed out either; usable 800 MB of 0x37000000 span")
JITPoolMeter.note("[jit-pool] pool-mid: WINE_IOS_JIT_HOLE2=1:2 ignored (hole 1 [0x1d000000,0x21000000), pool size 0x37000000)")
assert(JITPoolMeter.current.holes.count == 2 && JITPoolMeter.text(JITPoolMeter.current) == "JIT 480/800 MB (split)", JITPoolMeter.text(JITPoolMeter.current)!)
// pool-low's region C is a separate region: its line does not move the meter.
JITPoolMeter.note("[jit-pool] image 0x1+0x1 (b.dll) → pool 0x3 used=0x100000/0x8000000 tramp+0x4000 [pool-low] region C")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 480/800 MB (split)")
JITPoolMeter.note("[22:02:40.904] [ERR] ml1036: no hole fits a 896MB pool — SHRINKING to 880MB")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT 480/800 MB (small, split)")
JITPoolMeter.note("[jit-pool] EXHAUSTED (anon RWX): want=0x1000 bump=0x37000000/0x37000000 tail_resv=0x0 freelist=0 — FAILING allocation")
assert(JITPoolMeter.text(JITPoolMeter.current) == "JIT FULL 800 MB (split)")
// Damaged log values must not trap while the overlay formats them.
JITPoolMeter.reset()
JITPoolMeter.note("JIT pool: RX=0x1, RW=0x2, size=18446744073709551615MB")
assert(JITPoolMeter.current.sizeMB == nil)
JITPoolMeter.note("[jit-pool] image used=0xffffffffffffffff/0xffffffffffffffff")
assert(JITPoolMeter.text(JITPoolMeter.current) != nil)
JITPoolMeter.reset()
JITPoolMeter.note("[jit-pool] split pool: hole [0x100,0x300)")
JITPoolMeter.note("[jit-pool] pool-mid: hole 2 [0x200,0x400)")
assert(JITPoolMeter.current.holes.count == 1)
print("PASS: JIT memory overlay: size from setup, use from loads, small pool, FULL once exhausted, reset per session, split pool holes left out, region C ignored")
'''
# With Live logs off the tail still reads the file (once a second), so the pool's lines
# reach the meter; LogStore notes them before it drops a hidden line.
tail = (root / 'app/Madeira/LogTail.swift').read_text()
store = (root / 'app/Madeira/LogStore.swift').read_text()
assert 'if self.displayPaused { self.readWhilePaused() } else { self.readAvailable() }' in tail
assert 'guard fd >= 0, !displayPaused else { return }' not in tail and 'guard pausedTicks >= 4 else { return }' in tail
handle = store[store.index('private func handleRawLine('):]
assert handle.index('JITPoolMeter.note(raw)') < handle.index('if suppressed { return }')
print("PASS: the meter counts with Live logs off")
with tempfile.TemporaryDirectory(prefix='madeira-jit-meter-') as directory:
    source = Path(directory) / 'main.swift'; binary = Path(directory) / 'check'
    source.write_text((root / 'app/Madeira/JITPoolMeter.swift').read_text() + '\n' + checks)
    subprocess.run([SWIFTC, str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
