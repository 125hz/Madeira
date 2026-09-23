#!/usr/bin/env python3
"""Production-source regression for the loopback transport metadata probe; no Wine or guest runs."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "wine/dlls/ntdll/unix/socket.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
assert src.count("ios_loopback_io( fd, 0,") + src.count("ios_loopback_io( fd, 1,") == 4, "probe not at all four send/recv sites"
code = r"""
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
""" + function(src, "static void ios_loopback_io(") + r"""
int main(int argc, char **argv) {
    int l = socket(AF_INET, SOCK_STREAM, 0), c = socket(AF_INET, SOCK_STREAM, 0), a, u;
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t sl = sizeof(sa);
    assert(!bind(l, (struct sockaddr *)&sa, sizeof(sa)) && !listen(l, 1) && !getsockname(l, (struct sockaddr *)&sa, &sl));
    assert(!connect(c, (struct sockaddr *)&sa, sizeof(sa)) && (a = accept(l, NULL, NULL)) >= 0);
    if (argc > 1) setenv("MADEIRA_LOOPBACK_IO_TRACE", "0", 1);
    for (int i = 0; i < 10; ++i) { ios_loopback_io(c, 1, 100 + i, 0); ios_loopback_io(a, 0, 100 + i, 0); }
    ios_loopback_io(c, 0, 0, EAGAIN);                 /* ml1410: the first receive that would block is logged ... */
    ios_loopback_io(c, 0, 0, EWOULDBLOCK);            /* ... once per connection */
    ios_loopback_io(a, 0, 0, EAGAIN);                 /* the other end is its own connection record */
    ios_loopback_io(c, 1, 0, EAGAIN);                 /* a send that would block is not logged */
    ios_loopback_io(c, 0, 0, EINTR);
    ios_loopback_io(c, 1, 0, EPIPE);                  /* a hard error is logged past the per-connection cap */
    u = socket(AF_INET, SOCK_DGRAM, 0);
    ios_loopback_io(u, 1, 5, 0);                      /* unconnected: not logged */
    ios_loopback_io(-1, 1, 5, 0);
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stderr.splitlines()
    lines = [l for l in out if l.startswith("[loopback-io] ml1370")]
    assert len(lines) == 13, lines                      # 6 per side + the EPIPE error
    assert sum(" send " in l for l in lines) == 7 and sum(" recv " in l for l in lines) == 6, lines
    assert any("bytes=-1 errno=32" in l for l in lines), lines
    assert all("bytes=" in l and "peer=" in l for l in lines)
    wb = [l for l in out if l.startswith("[loopback-io] ml1410")]
    assert len(wb) == 2 and all(l.endswith("recv-would-block") for l in wb), wb
    off = subprocess.run([str(exe), "rollback"], check=True, capture_output=True, text=True).stderr
    assert "[loopback-io]" not in off
    print("PASS: loopback probe logs 6 events per connection plus hard errors, the first would-block receive per connection; skips would-block sends, unconnected and rollback")
