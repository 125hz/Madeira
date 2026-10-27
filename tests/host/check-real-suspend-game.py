#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Pause threads fully, per game (app/Madeira/LibraryBCD.swift, BCDLaunch.realSuspend).

MADEIRA_REAL_SUSPEND makes a Wine SuspendThread really stop the thread (ml730). A
Unity IL2CPP game's garbage collector needs that (Megabonk crashed while loading
without it), so Automatic turns it on when GameAssembly.dll is in the game's folder.
The game's On or Off wins over madeira.cfg's real-suspend, which wins over Automatic;
with none of them the variable is unset, and wineserver reads it on every call so
the next session of the app run sees its own value.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
bcd = (root / 'app/Madeira/LibraryBCD.swift').read_text(encoding='utf-8')
prefs = (root / 'app/Madeira/LibraryPrefs.swift').read_text(encoding='utf-8')
view = (root / 'app/Madeira/ContentView.swift').read_text(encoding='utf-8')
lib = (root / 'app/Madeira/Library.swift').read_text(encoding='utf-8')
server = (root / 'build/wineserver/mach_ios.c').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


m = re.search(r'static func realSuspend\(_ entry: LibraryEntry\?\).*?\n    \}\n', bcd, re.S)
fn = m.group(0) if m else ''
i_game = fn.find('LibraryPrefs.realSuspend(entry.windowsPath)')
i_cfg = fn.find('MadeiraConfig.get("real-suspend")')
i_auto = fn.find('isUnityIL2CPP(entry)')
check(fn != '', 'BCDLaunch.realSuspend exists')
check(0 <= i_game < i_cfg < i_auto, "the game's switch, then madeira.cfg, then Automatic")
check('entry.desktop != true' in fn, 'the Desktop entry has no per-game choice')
check('"GameAssembly.dll"' in bcd, 'Automatic looks for GameAssembly.dll')
check('static func realSuspend(_ windowsPath: String) -> Bool?' in prefs and 'setRealSuspend(_ on: Bool?' in prefs,
      'LibraryPrefs keeps Automatic (nil), On and Off')
check('BCDLaunch.realSuspend(profile)' in view and 'unsetenv("MADEIRA_REAL_SUSPEND")' in view,
      'the launch sets the variable from the choice and unsets it otherwise')
check('LibraryPrefs.setRealSuspend(' in lib and '"Pause threads fully"' in lib, 'Game details has the picker')
m = re.search(r'int ios_real_suspend_enabled\(void\)\n\{(.*?)\n\}', server, re.S)
body = m.group(1) if m else ''
check('getenv( "MADEIRA_REAL_SUSPEND" )' in body and 'static int env' not in body,
      'wineserver reads the variable on every call')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
