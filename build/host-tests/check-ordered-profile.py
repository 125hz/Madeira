#!/usr/bin/env python3
"""ml1470 ordered FEX profile for Chromium hosts and a front-end-named client; no Wine runs.

Compiles the production name-list matcher on the host and checks the source invariants of
the WoW64 process-init hook: chosen by what the process is (a CEF runtime next to it) or by an
explicit list, never replacing a user-set option, applied before the JIT context exists, with a
kill switch and one log line per process.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
m = (root / "FEX/Source/Windows/WOW64/Module.cpp").read_text()


def function(source, start):
    i = source.index(start); b = source.index("{", i); depth = 1; k = b + 1
    while depth:
        depth += (source[k] == "{") - (source[k] == "}"); k += 1
    return source[i:k]


listed = function(m, "static bool IosNameListed(std::string_view List, std::string_view Name)")
harness = "#include <string_view>\n#include <cstdio>\n#include <cstddef>\n" + listed + r'''
int main() {
  struct { const char* List; const char* Name; bool Want; } Cases[] = {
    {"Steam.exe", "steam.exe", true},
    {" launcher.exe ; Client.EXE", "client.exe", true},
    {"a.exe,b.exe", "b.exe", true},
    {"a.exe,b.exe", "c.exe", false},
    {"steam.exe", "steam.exe.bak", false},
    {"steamx.exe", "steam.exe", false},
    {"", "steam.exe", false},
    {";;,", "x.exe", false},
    {"TSOEnabled", "VectorTSOEnabled", false},
    {"Multiblock,VectorTSOEnabled", "VectorTSOEnabled", true},
  };
  int Fail = 0;
  for (auto& C : Cases) {
    if (IosNameListed(C.List, C.Name) != C.Want) { std::printf("FAIL: [%s] vs %s\n", C.List, C.Name); Fail = 1; }
  }
  return Fail;
}
'''
with tempfile.TemporaryDirectory() as t:
    src = Path(t) / "listed.cpp"; src.write_text(harness)
    exe = Path(t) / "listed"
    subprocess.run(["g++", "-std=c++20", "-Wall", "-Werror", "-fsanitize=address,undefined", str(src), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

reason = function(m, "static const char* IosOrderedProfileReason(")
assert '"libcef.dll"' in reason and '"chrome_elf.dll"' in reason and "ExePath.substr(0, Slash + 1)" in reason, \
    "a Chromium host is found by the CEF runtime next to its executable"
assert '"MADEIRA_ORDERED_PROFILE_EXES", "MADEIRA_ORDERED_PROFILE_CLIENT"' in reason, "user and front-end lists"

init = function(m, "void BTCpuProcessInit() {")
hook = init.index("// ml1470: see IosOrderedProfileReason.")
assert "BaseName(FEX::Windows::GetExecutableFilePath())" not in init and \
    init.index("const fextl::string ExecutablePath = FEX::Windows::GetExecutableFilePath();") < \
    init.index("const auto ExecutableName = FEX::Windows::BaseName(ExecutablePath);") < hook, \
    "the executable name views a path that outlives it, not a destroyed temporary"
assert init.index("FEX::Windows::Logging::Init();") < hook < init.index("CreateNewContext("), \
    "applied after logging exists and before the context reads the options"
block = init[hook:init.index("MADEIRA: pick up the guest window", hook)]
assert "getenv(\"MADEIRA_ORDERED_PROFILE\")" in block and "Switch[0] == '0'" in block, "kill switch"
assert block.index("FEXCore::Config::Exists(Entry.Option)") < block.index("FEXCore::Config::Set(Entry.Option, Entry.Value)"), \
    "a user-set option is checked before anything is set"
for option, value in [("CONFIG_MULTIBLOCK", '"0"'), ("CONFIG_VECTORTSOENABLED", '"1"'), ("CONFIG_HALFBARRIERTSOENABLED", '"1"')]:
    assert option + ", " in block and value in block, option
assert block.count("LogMan::Msg::EFmt(\"[ordered-profile] ml1470") == 2, "one line when applied, one when switched off"
assert "IosNameListed(MadeiraOrderedApplied, Entry.Name)" in init and '"(ordered-profile)"' in init, \
    "[fex-cfg] reports the profile as the profile, not as a user override"
for name in ["steam", "Steam", "webhelper"]:
    assert name not in reason + block, "chosen by what the process is, not by a product name"
print("PASS: ordered profile matches CEF hosts and listed names exactly, keeps user options, runs before the JIT, switchable")
