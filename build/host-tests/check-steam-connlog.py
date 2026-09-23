#!/usr/bin/env python3
"""Production-source regression for the Steam connection-log mirror redaction; no Wine or guest runs."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "wine/dlls/ntdll/unix/file.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
code = r"""
#include <stdio.h>
#include <string.h>
#include <assert.h>
""" + function(src, "static void ios_mask_account_data(") + r"""
static void check(const char *in, const char *want) {
    char buf[1025];
    strcpy(buf, in);
    ios_mask_account_data(buf);
    if (strcmp(buf, want)) { printf("FAIL\n in:   %s\n got:  %s\n want: %s\n", in, buf, want); assert(0); }
}
int main(void) {
    check("[2026-09-22 18:59:53] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )",
          "[2026-09-22 18:59:53] [Logged Off, 0, 0] [U:1:#] CCMInterface::SetSteamID( [U:1:#] )");
    check("[Logged On, 1, 0] [U:1:68721549] RecvMsgClientLogOnResponse() : [A:1:123:4] 'OK' (PublicIP 203.0.113.45)",
          "[Logged On, 1, 0] [U:1:#] RecvMsgClientLogOnResponse() : [A:1:123:4] 'OK' (PublicIP x.x.x.x)");
    check("Connectivity test (104.71.143.214:80 (104.71.143.214:80)): OK!",
          "Connectivity test (x.x.x.x:80 (x.x.x.x:80)): OK!");
    check("PingWebSocketCM() (cmp1-sea1.steamserver.net:443 / 162.254.193.46:443) failed talking to cm (Timeout)",
          "PingWebSocketCM() (cmp1-sea1.steamserver.net:443 / x.x.x.x:443) failed talking to cm (Timeout)");
    check("version 1769731672, 12.34 ms, 1.2.3 ok", "version 1769731672, 12.34 ms, 1.2.3 ok");   /* not an address */
    check("[U:1:", "[U:1:");
    check("", "");
    puts("PASS: connection-log mirror masks SteamIDs and IPv4 addresses, keeps ports, hosts and other numbers");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
