#!/usr/bin/env python3
"""ml1490 per-launch Steam identity (WineProcessBridge.m); no Wine runs.

Device log 188: every guest was given one title's hard-coded SteamAppPath/SteamAppId, and a
different Steam title started directly initialised with that foreign ID and exited. This
compiles the production madeira_publish_steam_identity() and runs it against a real prefix
directory for each kind of launch.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "app/Madeira/WineProcessBridge.m").read_text()
a = src.index("static void madeira_publish_steam_identity(void) {")
b = src.index("\n}\n", a) + 3
func = src[a:b]
assert "356400" not in src and 'setenv("SteamAppPath", "C:' not in src, "no hard-coded identity remains"
assert "madeira_publish_steam_identity();" in src[b:], "called at the old publication point"

harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static char *g_prefix_path = NULL;
""" + func + r"""
static int check(const char *label, const char *path, const char *id) {
  const char *p = getenv("SteamAppPath"), *a = getenv("SteamAppId"), *g = getenv("SteamGameId");
  int ok = (path ? p && !strcmp(p, path) : !p) && (id ? a && g && !strcmp(a, id) && !strcmp(g, id) : !a && !g);
  if (!ok) printf("FAIL: %s path=%s id=%s/%s\n", label, p ? p : "-", a ? a : "-", g ? g : "-");
  return ok;
}
int main(int argc, char **argv) {
  g_prefix_path = argv[1];
  int ok = 1;
  setenv("SteamAppId", "999", 1); setenv("SteamGameId", "999", 1); setenv("SteamAppPath", "C:\\stale", 1);
  setenv("MADEIRA_DESKTOP", "1", 1); setenv("MADEIRA_EXE", "explorer.exe", 1);
  madeira_publish_steam_identity(); ok &= check("desktop launch clears a previous identity", NULL, NULL);
  unsetenv("MADEIRA_DESKTOP");
  setenv("MADEIRA_EXE", "C:\\Games\\With Id\\bin\\game.exe", 1);
  madeira_publish_steam_identity(); ok &= check("steam_appid.txt next to the exe", "C:\\Games\\With Id\\bin", "4242");
  setenv("MADEIRA_STEAM_APPID", "70", 1);
  madeira_publish_steam_identity(); ok &= check("library identity wins over the file", "C:\\Games\\With Id\\bin", "70");
  setenv("MADEIRA_STEAM_APPID", "7x", 1);
  madeira_publish_steam_identity(); ok &= check("non-numeric library identity ignored", "C:\\Games\\With Id\\bin", "4242");
  unsetenv("MADEIRA_STEAM_APPID");
  setenv("MADEIRA_EXE", "C:\\Games\\Plain\\game.exe", 1);
  madeira_publish_steam_identity(); ok &= check("no identity available", "C:\\Games\\Plain", NULL);
  setenv("MADEIRA_EXE", "C:\\root.exe", 1);
  madeira_publish_steam_identity(); ok &= check("drive root folder", "C:\\", NULL);
  setenv("MADEIRA_EXE", "cube.exe", 1);
  madeira_publish_steam_identity(); ok &= check("bare name", NULL, NULL);
  setenv("MADEIRA_EXE", "C:\\Games\\With Id\\bin\\game.exe", 1); setenv("MADEIRA_STEAM_ENV", "0", 1);
  madeira_publish_steam_identity(); ok &= check("switch off publishes nothing", NULL, NULL);
  return ok ? 0 : 1;
}
"""
with tempfile.TemporaryDirectory() as t:
    prefix = Path(t) / "prefix"
    (prefix / "drive_c/Games/With Id/bin").mkdir(parents=True)
    (prefix / "drive_c/Games/With Id/bin/steam_appid.txt").write_text("4242\r\n")
    (prefix / "drive_c/Games/Plain").mkdir(parents=True)
    c = Path(t) / "env.c"; c.write_text(harness)
    exe = Path(t) / "env"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Werror", "-fsanitize=address,undefined", str(c), "-o", str(exe)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("Steam", "MADEIRA_"))}
    out = subprocess.run([str(exe), str(prefix)], capture_output=True, text=True, env=env)
    print(out.stdout, end="")
    assert out.returncode == 0, out.stdout + out.stderr
    assert "[steam-env] ml1490 direct launch: SteamAppPath=C:\\Games\\With Id\\bin app-id=4242 (steam_appid.txt)" in out.stderr, out.stderr
    assert "[steam-env] ml1490 off (MADEIRA_STEAM_ENV=0)" in out.stderr
print("PASS: Steam identity is per launch: none for desktop/client launches, exe folder plus library or steam_appid.txt ID for direct ones")
