#!/usr/bin/env python3
"""Production-source regression for the ml1410 loopback wait trace (wineserver); no Wine or guest runs.

Device log 171: the listening process read one of two accepted local transport connections
and never the other. The trace records read requests, polls and read-queue wake-ups for
loopback stream sockets only, with per-socket and total caps and a kill switch.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "wine/server/sock.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
# each hook sits where its event happens
assert 'IOS_LB_WAIT( sock, "recv status=' in function(src, "DECL_HANDLER(recv_socket)")
wake = function(src, "static int sock_dispatch_asyncs(")
assert wake.index('IOS_LB_WAIT( sock, "wake-read') < wake.index("async_wake_up( &sock->read_q, STATUS_ALERTED )")
assert 'IOS_LB_WAIT( sock, "poll mask=' in function(src, "static void poll_socket( struct sock *poll_sock, struct async *async, int exclusive, timeout_t timeout,\n                         unsigned int count, const struct afd_poll_socket_64 *sockets )\n{")
assert 'IOS_LB_WAIT( sock, "poll-complete' in function(src, "static void complete_async_polls(")
assert "sock->ios_lb_n = 0;" in src
a = src.index("static int ios_lb_wait_enabled(")
b = src.index("} while (0)", a) + len("} while (0)")
block = src[a:b]
code = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <arpa/inet.h>
#define WS_AF_INET 2
#define WS_AF_INET6 23
#define WS_SOCK_STREAM 1
#define WS_SOCK_DGRAM 2
struct ws_in_addr { union { struct { unsigned char s_b1, s_b2, s_b3, s_b4; } S_un_b; unsigned int S_addr; } S_un; };
union win_sockaddr {
    struct { unsigned short sa_family; char sa_data[14]; } addr;
    struct { unsigned short sin_family; unsigned short sin_port; struct ws_in_addr sin_addr; char zero[8]; } in;
    struct { unsigned short sin6_family; unsigned short sin6_port; unsigned int flow; unsigned char sin6_addr[16]; unsigned int scope; } in6;
};
struct sock { unsigned short type; union win_sockaddr addr, peer_addr; unsigned char ios_lb_n; };
struct process { unsigned int id; };
struct thread { struct process *process; };
static struct process proc = { 0x34 };
static struct thread thr = { &proc };
static struct thread *current = &thr;
""" + block + r"""
static struct sock v4(unsigned char first, unsigned short type) {
    struct sock s; memset(&s, 0, sizeof(s)); s.type = type;
    s.addr.in.sin_family = WS_AF_INET; s.addr.in.sin_port = htons(52649);
    s.peer_addr.in.sin_family = WS_AF_INET; s.peer_addr.in.sin_port = htons(52656);
    s.peer_addr.in.sin_addr.S_un.S_un_b.s_b1 = first;
    return s;
}
int main(int argc, char **argv) {
    if (argc > 1) setenv("MADEIRA_LOOPBACK_WAIT_TRACE", "0", 1);
    struct sock lo = v4(127, WS_SOCK_STREAM), net = v4(10, WS_SOCK_STREAM), dg = v4(127, WS_SOCK_DGRAM), un;
    memset(&un, 0, sizeof(un)); un.type = WS_SOCK_STREAM;
    struct sock six; memset(&six, 0, sizeof(six)); six.type = WS_SOCK_STREAM;
    six.peer_addr.in6.sin6_family = WS_AF_INET6; six.peer_addr.in6.sin6_addr[15] = 1;
    struct sock six_net = six; six_net.peer_addr.in6.sin6_addr[0] = 0x20;
    for (int i = 0; i < 20; i++) IOS_LB_WAIT( &lo, "recv status=%08x nb=%d", 0x103, 0 );
    IOS_LB_WAIT( &net, "recv status=%08x", 0 );
    IOS_LB_WAIT( &dg, "recv status=%08x", 0 );
    IOS_LB_WAIT( &un, "recv status=%08x", 0 );
    IOS_LB_WAIT( &six, "wake-read event=%x", 1 );
    IOS_LB_WAIT( &six_net, "wake-read event=%x", 1 );
    current = NULL;                                   /* main-loop context: no current thread */
    struct sock lo2 = v4(127, WS_SOCK_STREAM);
    IOS_LB_WAIT( &lo2, "poll-complete wanted=%x got=%x", 1, 1 );
    for (int n = 0; n < 40; n++) { struct sock s = v4(127, WS_SOCK_STREAM); for (int i = 0; i < 12; i++) IOS_LB_WAIT( &s, "poll mask=%x", 1 ); }
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stderr.splitlines()
    lines = [l for l in out if l.startswith("[loopback-wait] ml1410")]
    assert len(lines) == 160, len(lines)                                   # app-lifetime cap
    assert sum("recv status=00000103" in l for l in lines) == 12           # per-socket cap
    assert lines[0] == "[loopback-wait] ml1410 pid=0034 local=52649 peer=52656 recv status=00000103 nb=0", lines[0]
    assert sum("wake-read" in l for l in lines) == 1                       # ::1 only
    assert any(l.startswith("[loopback-wait] ml1410 pid=0000 ") and "poll-complete" in l for l in lines)
    assert "runtime error" not in "\n".join(out)
    off = subprocess.run([str(exe), "rollback"], check=True, capture_output=True, text=True).stderr
    assert "[loopback-wait]" not in off
    print("PASS: loopback wait trace covers loopback stream sockets only, per-socket and total caps, main-loop context and rollback")
