#!/usr/bin/env python3
"""Source invariants for the ml1460 accept completion chain trace (wineserver); no Wine runs.

Device logs 171/181: accepts on the Steam client's loopback listener completed in the server
and were never read by the client. The trace must cover every step between the server's
accept and a thread dequeuing the completion, and only for accepts it marked.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
a = (root / "wine/server/async.c").read_text()
s = (root / "wine/server/sock.c").read_text()
c = (root / "wine/server/completion.c").read_text()
def function(source, start):
    i = source.index(start); b = source.index("{", i); depth = 1; k = b + 1
    while depth:
        depth += (source[k] == "{") - (source[k] == "}"); k += 1
    return source[i:k]

acc = function(s, "static void complete_async_accept( struct sock *sock, struct accept_req *req )\n{")
assert acc.index('ios_accept_trace( sock, "accepted", 0 );') < acc.index("async_set_ios_trace( async );") < acc.index("fill_accept_output( req );"), \
    "accepts are marked after accepting and before the output is filled (which terminates the async)"
term = function(a, "void async_terminate( struct async *async, unsigned int status )\n{")
assert "int queued = thread_queue_apc(" in term and "if (async->ios_trace && ios_chain_enabled())" in term, "APC step logged with its result"
assert "direct result status" in term, "direct-result asyncs are logged too"
res = function(a, "void async_set_result( struct object *obj, unsigned int status, apc_param_t total )\n{")
assert "[accept-chain] ml1460 result status" in res and "ios_chain_cvalue[i] = async->data.apc_context" in res, "result and posted value recorded"
assert res.index("add_async_completion( async, async->data.apc_context, status, total );") < res.index("[accept-chain] ml1460 result status"), \
    "logged after the completion is posted"
rem = function(c, "DECL_HANDLER(remove_completion)")
assert rem.index('ios_chain_note_dequeue( msg->cvalue, "immediate" );') < rem.index("free( msg );"), "immediate dequeue noted before free"
gtc = function(c, "DECL_HANDLER(get_thread_completion)")
assert gtc.index('ios_chain_note_dequeue( msg->cvalue, "after wait" );') < gtc.index("free( msg );"), "waited dequeue noted before free"
assert "MADEIRA_ACCEPT_CHAIN_TRACE" in a and "ios_chain_lines < 48" in a, "switch and cap"
assert "async->ios_trace     = 0;" in a, "flag initialised"
print("PASS: accept completion chain hooks cover APC, result, post and both dequeue paths, marked accepts only, capped")
