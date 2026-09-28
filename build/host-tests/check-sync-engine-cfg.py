#!/usr/bin/env python3
"""ml2013: Settings > Memory & sync -> madeira.cfg -> the engine that actually runs.

Reproduces the app's start-up order on the host with the production code:
  1. the WineProcessBridge.m constructor (madeira_docs_dir_early, source-extracted)
     runs before main() while HOME is still the app container;
  2. Settings writes madeira.cfg through the production MadeiraConfig.swift and the
     RuntimeMemorySyncSettings.apply cases (source-extracted from Library.swift);
     the launch exports MadeiraConfig.environmentValues() (env.* keys);
  3. the in-app wineserver thread sets HOME to the Wine prefix (Documents/wine);
  4. madsync_enabled() (source-extracted from build/madsync/madsync.c) reads
     inproc-sync through the production build/madeira_cfg.h;
  5. the ntdll client parses MADEIRA_FASTSYNC (the mode block of
     madeira_fast_parse_env) and applies madeira_sync_engine_mode (both from
     wine/dlls/ntdll/unix/sync.c).
It also checks that the pre-ml2013 order (no early MADEIRA_DOCS_DIR, no container
home) really loses the Settings choice, i.e. that the test covers log 97's failure.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get("SWIFTC") or shutil.which("swiftc") or os.path.expanduser("~/.local/share/swiftly/bin/swiftc")
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")

def between(text, start, end, what, include_end=False):
    i = text.index(start)
    j = text.index(end, i + len(start))
    return text[i:j + (len(end) if include_end else 0)]

madsync = read("build/madsync/madsync.c")
bridge = read("app/Madeira/WineProcessBridge.m")
sync = read("wine/dlls/ntdll/unix/sync.c")
library = read("app/Madeira/Library.swift")
config_swift = read("app/Madeira/MadeiraConfig.swift")
# Linux Foundation resolves .documentDirectory from the passwd home, not $HOME, so
# the unpatched copy would write the developer's real ~/Documents/madeira.cfg.
# Point the test copy at $HOME/Documents (what iOS returns inside the container).
DOCS_EXPR = "FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first"
assert DOCS_EXPR in config_swift
config_swift = config_swift.replace(
    DOCS_EXPR, 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]! + "/Documents")')

# ---- C extraction ---------------------------------------------------------------
f_enabled = between(madsync, "int madsync_enabled(void)", "\n}\n", "madsync_enabled", include_end=True)
f_early = between(bridge, "static const char *g_madeira_docs_early", "__attribute__((constructor))", "madeira_docs_dir_early")
f_engine = between(sync, "static int madeira_sync_engine_mode(", "\n}\n", "madeira_sync_engine_mode", include_end=True)
parse = between(sync, 'const char *e = getenv( "MADEIRA_FASTSYNC" );', "    asked = mode;", "fastsync mode parse")
modes = between(sync, "    MADEIRA_FS_MODE_OFF   = 0,", "};", "mode enum")
assert "[madsync] ml2013 decision=" in f_enabled
assert "[sync-engine] ml2013" in sync and "madeira_sync_engine_mode( mode, inproc_device_fd >= 0" in sync
assert "[config-dir] ml2013" in bridge and "__attribute__((constructor)) static void madeira_docs_dir_ctor" in bridge

harness_c = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "madeira_cfg.h"
enum {
''' + modes + r'''};
''' + f_enabled + "\n" + f_early + "\n" + f_engine + r'''
static int parse_mode(void)
{
    ''' + parse + r'''
    (void)peek; (void)sem; (void)asked;
    return mode;
}
int main(int argc, char **argv)
{
    const char *early = "not-run", *prefix = getenv("TEST_PREFIX");
    int on, mode, final;
    if (argc > 1 && !strcmp(argv[1], "ctor")) early = g_madeira_docs_early = madeira_docs_dir_early();
    if (prefix) setenv("HOME", prefix, 1);          /* WineServerBridge.m: HOME = Wine prefix */
    on = madsync_enabled();                        /* wineserver's first object */
    mode = parse_mode();
    final = madeira_sync_engine_mode(mode, on, getenv("MADEIRA_SYNC_EXCLUSIVE"));
    printf("early=%s madsync=%d asked=%d final=%d dir=%s\n", early, on, mode, final, madeira_cfg_dir_source());
    return 0;
}
'''

# ---- Swift extraction -------------------------------------------------------------
apply_body = between(library, "static func apply(_ engine: SyncEngine) {", "\n    }\n", "apply")
apply_cases = "\n".join(l for l in apply_body.splitlines() if l.strip().startswith("case ."))
current_body = between(library, "static func currentEngine() -> SyncEngine {", "\n    }\n", "currentEngine")
current_body = current_body.split("{", 1)[1]
assert apply_cases.count("case .") == 3, apply_cases

harness_swift = '''
import Foundation
enum SyncEngine: String { case fastsync, madsync, off }
func apply(_ engine: SyncEngine) {
    switch engine {
''' + apply_cases + '''
    }
}
func currentEngine() -> SyncEngine {''' + current_body + '''
}
let args = CommandLine.arguments
if args[1] != "none" { apply(SyncEngine(rawValue: args[1])!) }
print("CURRENT \\(currentEngine().rawValue)")
for (k, v) in MadeiraConfig.environmentValues().sorted(by: { $0.key < $1.key }) { print("ENV \\(k)=\\(v)") }
'''

AUTO, OFF = 2, 0

with tempfile.TemporaryDirectory(prefix="madeira-sync-engine-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness_c, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Werror", "-Wno-unused-function", "-I", str(ROOT / "build"),
                    str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)
    (tmp / "MadeiraConfig.swift").write_text(config_swift, encoding="utf-8")
    (tmp / "main.swift").write_text(harness_swift, encoding="utf-8")
    subprocess.run([SWIFTC, str(tmp / "MadeiraConfig.swift"), str(tmp / "main.swift"), "-o", str(tmp / "s")], check=True)

    def container(name, cfg=None, legacy=None):
        home = tmp / name
        docs = home / "Documents"
        (docs / "wine").mkdir(parents=True)
        if cfg is not None: (docs / "madeira.cfg").write_bytes(cfg)
        if legacy is not None: (docs / "madeira-inproc-sync.txt").write_text(legacy)
        return home

    def base_env(home):
        env = {k: v for k, v in os.environ.items()
               if k not in ("MADEIRA_DOCS_DIR", "CFFIXED_USER_HOME", "MADEIRA_FASTSYNC", "MADEIRA_SYNC_EXCLUSIVE",
                            "MADEIRA_CFG_EARLY_DOCS")}
        env["HOME"] = str(home)
        return env

    def settings(home, engine):
        """Settings choice through the production Swift; returns (current, exported env)."""
        out = subprocess.run([str(tmp / "s"), engine], check=True, capture_output=True, text=True,
                             env=base_env(home)).stdout
        current = re.search(r"CURRENT (\w+)", out).group(1)
        env = dict(re.findall(r"ENV (\w+)=(.*)", out))
        return current, env

    def launch(home, exported, ctor=True, cffixed=False, extra=None):
        env = base_env(home)
        env.update(exported)                        # [config-env] ml1840 export before Wine starts
        if cffixed: env["CFFIXED_USER_HOME"] = str(home)
        env.update(extra or {})
        env["TEST_PREFIX"] = str(home / "Documents" / "wine")
        r = subprocess.run([str(tmp / "c"), "ctor" if ctor else "none"], check=True, capture_output=True,
                           text=True, env=env)
        m = re.search(r"early=(\S+) madsync=(\d) asked=(\d) final=(\d) dir=(\S+)", r.stdout)
        assert m, r.stdout + r.stderr
        return dict(early=m.group(1), madsync=int(m.group(2)), asked=int(m.group(3)), final=int(m.group(4)),
                    dir=m.group(5), log=r.stderr)

    def check(ok, what):
        if not ok: raise SystemExit("FAIL: " + what)
        print("ok:", what)

    # -- the three Settings choices, full app order (constructor on) --
    for engine, want_madsync, want_final in (("fastsync", 1 == 0, AUTO), ("madsync", True, OFF), ("off", False, OFF)):
        home = container("app-" + engine, cfg=b"# user file\npool = 896\n")
        current, exported = settings(home, engine)
        check(current == engine, f"{engine}: Settings reads its own choice back")
        want_env = None if engine == "fastsync" else "0"
        check(exported.get("MADEIRA_FASTSYNC") == want_env, f"{engine}: exported MADEIRA_FASTSYNC={want_env}")
        r = launch(home, exported)
        check(r["early"] == "set" and r["dir"] == "env", f"{engine}: constructor exported MADEIRA_DOCS_DIR")
        check(r["madsync"] == int(want_madsync), f"{engine}: madsync decision {int(want_madsync)}")
        check(r["final"] == want_final, f"{engine}: client fastsync mode {want_final}")
        check(f"decision={'madsync' if want_madsync else 'off'}" in r["log"], f"{engine}: [madsync] ml2013 line")
        if engine == "madsync":
            check("inproc-sync=1 cfg=present dir=env" in r["log"], "madsync: log names value, file and directory")

    # -- log 97 reproduction: pre-ml2013 order loses the choice --
    home = container("pre-ml2013", cfg=b"")
    _, exported = settings(home, "madsync")
    r = launch(home, exported, ctor=False, cffixed=False)
    check(r["madsync"] == 0 and r["dir"] == "home", "pre-ml2013 order (HOME = prefix, no MADEIRA_DOCS_DIR) misses inproc-sync")
    # the container home alone (no constructor) is enough
    r = launch(home, exported, ctor=False, cffixed=True)
    check(r["madsync"] == 1 and r["dir"] == "container", "CFFIXED_USER_HOME fallback finds the Settings choice")

    # -- kill switches --
    r = launch(home, exported, ctor=True, cffixed=True, extra={"MADEIRA_CFG_EARLY_DOCS": "0"})
    check(r["early"] == "off-env" and r["madsync"] == 0, "MADEIRA_CFG_EARLY_DOCS=0 restores the pre-ml2013 lookup")
    home = container("killcfg", cfg=b"env.MADEIRA_CFG_EARLY_DOCS = 0\n")
    _, exported = settings(home, "madsync")
    r = launch(home, {k: v for k, v in exported.items() if k != "MADEIRA_CFG_EARLY_DOCS"}, ctor=True, cffixed=True)
    check(r["early"] == "off-cfg" and r["madsync"] == 0, "env.MADEIRA_CFG_EARLY_DOCS = 0 in madeira.cfg also disables it")

    # -- hand-edited madeira.cfg: madsync on, fastsync left at its default --
    home = container("hand", cfg=b"inproc-sync = 1\n")
    current, exported = settings(home, "none")
    check(current == "madsync" and "MADEIRA_FASTSYNC" not in exported, "hand edit reads as Madsync with fastsync unset")
    r = launch(home, exported)
    check(r["madsync"] == 1 and r["asked"] == AUTO and r["final"] == OFF, "exclusive: fastsync client turned off under madsync")
    r = launch(home, exported, extra={"MADEIRA_SYNC_EXCLUSIVE": "0"})
    check(r["final"] == AUTO, "MADEIRA_SYNC_EXCLUSIVE=0 keeps both")

    # -- parse robustness shared with Swift --
    home = container("crlf-bom", cfg=b"\xef\xbb\xbfinproc-sync = 1\r\nenv.MADEIRA_FASTSYNC = 0\r\n")
    current, exported = settings(home, "none")
    r = launch(home, exported)
    check(current == "madsync" and r["madsync"] == 1 and r["final"] == OFF, "BOM + CRLF file: Swift and C agree")
    home = container("legacy", legacy="1\n")
    r = launch(home, {})
    check(r["madsync"] == 1, "no madeira.cfg: legacy madeira-inproc-sync.txt still honoured")

print("PASS: Settings sync engine -> madeira.cfg -> madsync/fastsync decision (ml2013)")
