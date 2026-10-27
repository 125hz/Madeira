# TaskbarList COM packaging

The bundled prefix registers `CLSID_TaskbarList`
(`{56FDF344-FD6D-11D0-958A-006097C9A090}`) to
`C:\windows\system32\explorerframe.dll`. An absent server makes in-process COM
activation fail, even though the registry entry is present. Bundle the existing
Wine module; no custom COM server, game ID check or registry override is needed.
This addresses the missing-server packaging defect reported in Madeira #450.
It does not establish the cause of every subsequent exception in that game.

From the repository root, with the prerequisites in BUILDING.md:

```sh
JOBS=2 bash build/wine-pe/build-modules.sh explorerframe
python3 tests/host/check-explorerframe.py
TC=toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin
"$TC/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -Werror \
  tests/x64/taskbarlist.c -lole32 -luuid -o taskbarlist-x64.exe
```

The normal module build list includes explorerframe. The tracked DLL is built
from the superproject's Wine pin and stripped by the same script as other
builtins. Wine's copyright, implementation and COM registration remain unchanged.

Build an unsigned iOS Debug app following BUILDING.md and sign it with your own
certificate, preserving the JIT helper. Enable JIT, add `taskbarlist-x64.exe` as a
64-bit program and launch it directly. For one run use:

```ini
env.WINEDEBUG = err+all,trace+loaddll,trace+ole
```

Retain the EXE log and Madeira session log. Success requires the real system32
DLL to load, STA initialization, two successful `CoCreateInstance` / `HrInit` /
`QueryInterface(ITaskbarList4)` / release cycles, `END failed=0` and guest exit0.
The test does not register a server or bypass failed COM activation by calling
`DllGetClassObject` directly. It has no visible window. A host packaging check
cannot prove these runtime results; device execution remains a separate gate.

To check the final app's actual farm before installation:

```sh
python3 tests/host/check-explorerframe.py /path/to/Madeira.app/arm64ec-windows
```

Wine's TaskbarList includes methods that are stubs or return `E_NOTIMPL`.
This change does not implement a Windows taskbar on iOS or promise thumbnails,
progress overlays, every shell API, 32-bit COM support or successful gameplay.
