#!/usr/bin/env python3
"""Production-source regression for ml1450 [tcp-end] and the errno fix; no Wine or guest runs.

Device log 179: the Steam client's server connection ended with 'I/O Operation Failed' and
nothing said whether the peer closed it, a receive/send failed, or the program closed it.
Part A: the receive/send error paths hand every probe AND the returned status the saved
errno (the probes call getpeername, which sets errno on a reset connection), and the server
logs program-side closes. Part B: the production ios_tcp_end_trace on real TCP sockets
connected through a non-loopback interface address.
"""
from pathlib import Path
import re, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "wine/dlls/ntdll/unix/socket.c").read_text()
srv = (root / "wine/server/sock.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]

recv = function(src, "static NTSTATUS try_recv(")
err_branch = recv[recv.index("const int recv_err = errno;"):]
err_branch = err_branch[:err_branch.index("return sock_errno_to_status( recv_err );")]
for probe in ["ios_sock_big_note( fd, 0, 0, recv_err )", "ios_sock_wire( fd, 0, NULL, 0, recv_err )",
              "ios_sock_tl( fd, 0, NULL, 0, recv_err )", "ios_loopback_io( fd, 0, 0, recv_err )",
              "ios_tcp_end_trace( fd, 0, 0, recv_err )"]:
    assert probe in err_branch, probe
assert "ios_tcp_end_trace( fd, 0, ret, 0 );" in recv, "success path reports a zero-byte receive"
send_err = src[src.index("const int send_err = errno;"):]
send_err = send_err[:send_err.index("return sock_errno_to_status( send_err );")]
assert send_err.count("send_err )") == 5, "every send probe gets the saved errno"
assert not re.search(r"ios_(sock_big_note|sock_wire|sock_tl|loopback_io|tcp_end_trace)\([^;]*errno \);", src), "no probe re-reads errno"
destroy = function(srv, "static void sock_destroy( struct object *obj )\n{")
assert destroy.index("ios_tcp_close_trace( sock );") < destroy.index("bound_addr"), "server logs the close first"
print("PASS: saved errno reaches every probe and the returned status; server logs program-side closes")

code = r"""
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
""" + function(src, "static void ios_tcp_end_trace(") + r"""
static int pair(struct in_addr ip, int *c, int *a) {
    int l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr = ip };
    socklen_t sl = sizeof(sa);
    if (bind(l, (struct sockaddr *)&sa, sizeof(sa)) || listen(l, 1) || getsockname(l, (struct sockaddr *)&sa, &sl)) return -1;
    *c = socket(AF_INET, SOCK_STREAM, 0);
    if (connect(*c, (struct sockaddr *)&sa, sizeof(sa))) return -1;
    *a = accept(l, NULL, NULL); close(l);
    return *a >= 0 ? 0 : -1;
}
int main(int argc, char **argv) {
    struct ifaddrs *ifs, *i; struct in_addr ip = { 0 };
    getifaddrs(&ifs);
    for (i = ifs; i; i = i->ifa_next)
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET &&
            (ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr) >> 24) != 127) { ip = ((struct sockaddr_in *)i->ifa_addr)->sin_addr; break; }
    freeifaddrs(ifs);
    if (!ip.s_addr) { puts("SKIP no non-loopback IPv4 address"); return 0; }
    if (argc > 1) setenv("MADEIRA_TCP_END_TRACE", "0", 1);
    int c, a; char b[8];
    assert(!pair(ip, &c, &a));
    ios_tcp_end_trace(c, 0, 5, 0);                 /* data: silent */
    ios_tcp_end_trace(c, 0, 0, EAGAIN);            /* would-block: silent */
    ios_tcp_end_trace(c, 1, 0, 0);                 /* send of 0: silent */
    close(a);
    assert(recv(c, b, sizeof(b), 0) == 0);
    ios_tcp_end_trace(c, 0, 0, 0);                 /* peer closed */
    close(c);
    assert(!pair(ip, &c, &a));
    struct linger lg = { 1, 0 }; setsockopt(a, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg)); close(a);
    usleep(20000);
    int r = recv(c, b, sizeof(b), 0), e = errno;
    assert(r < 0 && e == ECONNRESET);
    errno = e;
    ios_tcp_end_trace(c, 0, 0, e);                 /* reset */
    close(c);
    struct in_addr lo = { htonl(INADDR_LOOPBACK) };
    assert(!pair(lo, &c, &a)); close(a); recv(c, b, sizeof(b), 0);
    ios_tcp_end_trace(c, 0, 0, 0);                 /* loopback: silent */
    close(c);
    int u = socket(AF_INET, SOCK_DGRAM, 0); ios_tcp_end_trace(u, 0, 0, ECONNREFUSED); close(u);   /* not a stream */
    for (int k = 0; k < 60; k++) { assert(!pair(ip, &c, &a)); close(a); recv(c, b, 1, 0); ios_tcp_end_trace(c, 0, 0, 0); close(c); }
    puts("done");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr[-1500:]
    if "SKIP" in out.stdout:
        print("PASS (Part B skipped: no non-loopback IPv4 address on this host)")
    else:
        lines = [l for l in out.stderr.splitlines() if l.startswith("[tcp-end] ml1450")]
        assert len(lines) == 48, len(lines)                                  # app-lifetime cap
        assert "peer-closed errno=0" in lines[0] and f"recv-error errno={104}" in lines[1], lines[:3]
        off = subprocess.run([str(exe), "rollback"], check=True, capture_output=True, text=True)
        assert "[tcp-end]" not in off.stderr
        print("PASS: [tcp-end] logs peer closes and hard errors on remote TCP only, caps at 48; rollback silent")
