# UTF-8 launch working directory

The iOS bridge supplies `MADEIRA_INITIAL_CWD` using UTF-8. Wine process
parameters require an NT UTF-16 path. Widening each byte produces an invalid
path for non-ASCII folders: a launch under `C:\TaskbarList-iPad测试\` was
reported as `C:\TaskbarList-iPad\ffe6\ffb5\ff8b\ffe8\ffaf\ff95\` and Wine
fell back to its Windows directory. Absolute EXE loading can still succeed,
while relative config, asset or save lookups use the wrong directory.

The override now uses the existing Wine UTF-8 decoder, including surrogate
pairs, and appends the trailing separator using the decoded UTF-16 length.
ASCII paths keep the same result. An absent/empty override, invalid UTF-8 or
allocation failure leaves the existing Unix/PWD/default-directory path in charge.
No code-page, path normalization, profile or game-specific behavior is changed.

Host regression, requiring the pinned Wine source:

```sh
python3 tests/host/check-initial-cwd-utf8.py
```

It compiles the actual override and Wine's actual decoder under ASan/UBSan,
compares 15 multilingual paths against independently generated UTF-16 values,
and checks missing/empty/OOM/invalid-input fallbacks. It does not exercise iOS
filesystem mappings or establish game compatibility.

For a matching rebuilt Debug package on iPad, compile:

```sh
TC=toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin
"$TC/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -Werror \
  tests/x64/initial-cwd.c -o initial-cwd-x64.exe
```

Place the EXE in a folder such as `C:\Games\测试🎮\`, leave any explicit per-game
working-folder override empty, enable JIT and launch it directly as x64.
It creates a uniquely named probe beside the EXE, reads it by a relative name,
compares its contents and deletes it. Acceptance is `[initial-cwd] PASS relative
resource lookup`, guest exit0 and no working-directory fallback in the session
log. An intentionally different working-folder setting does not satisfy this
fixture's assumption. Repeat with an ASCII folder as a control.
