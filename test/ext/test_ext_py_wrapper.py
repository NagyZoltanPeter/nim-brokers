"""Runtime tests of the generated EXTAPI Python wrapper (review W5, W6, Python
cancel) against a fake `broker_ext_host` built with ctypes: the test plays the
Nim host (calls invoke / cancel) and records the replies.

    python3 test/ext/test_ext_py_wrapper.py <dir holding life_ext.py>

`nimble testExtPyWrapper` generates life_ext.py from test_ext_lifecycle.nim.
"""

import asyncio
import ctypes
import functools
import os
import sys
import threading
import time
import warnings

sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else os.path.join("build", "extwrap"))
import life_ext as L  # noqa: E402
import cbor2  # noqa: E402

FIELDS = dict(L._Host._fields_)
REPLIES = {}
CAPTURED = {}


def h_open(host, ctx, impl_ptr, out):
    # Like the real host: copy the impl (the struct lives only for the call).
    impl = impl_ptr.contents
    CAPTURED["invoke"] = L._INVOKE_FN(ctypes.cast(impl.invoke, ctypes.c_void_p).value)
    CAPTURED["cancel"] = L._CANCEL_FN(ctypes.cast(impl.cancel, ctypes.c_void_p).value)
    CAPTURED["user"] = impl.user
    CAPTURED["caps"] = impl.caps
    out[0] = 1
    return 0


def h_reply(host, port, call_id, status, buf, n):
    REPLIES[call_id] = (status, ctypes.string_at(buf, n) if n else b"")
    return 0


HOST = L._Host()
HOST.abiVersion = 1
HOST.open = FIELDS["open"](h_open)
HOST.close = FIELDS["close"](lambda h, p: 0)
HOST.provide = FIELDS["provide"](lambda h, p, n: 0)
HOST.withdraw = FIELDS["withdraw"](lambda h, p, n: 0)
HOST.reply = FIELDS["reply"](h_reply)
HOST.emit = FIELDS["emit"](lambda h, p, n, b, ln: 0)
HOST_ADDR = ctypes.addressof(HOST)

IDX = {v[0]: k for k, v in L._NAMES.items()}

failures = 0


def expect(cond, what):
    global failures
    print(f"  {'ok  ' if cond else 'FAIL'}  {what}")
    if not cond:
        failures += 1


def invoke(name, call_id, payload):
    data = cbor2.dumps(payload) if payload is not None else b""
    buf = (ctypes.c_uint8 * max(len(data), 1)).from_buffer_copy(data or b"\0")
    CAPTURED["invoke"](CAPTURED["user"], call_id, IDX[name], name.encode(), buf, len(data))


def wait_reply(call_id, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if call_id in REPLIES:
            return REPLIES[call_id]
        time.sleep(0.005)
    return REPLIES.get(call_id)


def main() -> int:
    loop = asyncio.new_event_loop()
    t = threading.Thread(target=loop.run_forever, daemon=True)
    t.start()

    # W5: honest caps.
    port = L.Builder().life_echo(lambda x: L.LifeEcho(n=x)).open(HOST_ADDR, 1, loop)
    caps = CAPTURED["caps"]
    expect(caps & L._CAP_NONBLOCKING and caps & L._CAP_REPLY_INLINE, "caps = NONBLOCKING | REPLY_INLINE")

    # inplace name + sync handler: replies before invoke returns.
    invoke("life_echo", 1, {"x": 7})
    r = REPLIES.get(1)
    expect(r is not None and r[0] == L._REPLY_OK and cbor2.loads(r[1]) == {"n": 7},
           "inplace sync handler replies inline")

    # W6: missing argument -> error reply, not a call with None.
    invoke("life_echo", 2, {})
    r = REPLIES.get(2)
    expect(r is not None and r[0] == L._REPLY_ERR and b"missing argument" in r[1], "missing argument -> error")
    port.close()

    # W5: a slow sync handler on a bridge name runs on the pool, not on the
    # invoking (bridge) thread.
    def slow():
        time.sleep(0.4)
        return L.LifeTid(n=1)

    port = L.Builder().life_tid(slow).open(HOST_ADDR, 1, loop)
    t0 = time.monotonic()
    invoke("life_tid", 3, None)
    expect(time.monotonic() - t0 < 0.1, "slow sync handler does not block invoke")
    r = wait_reply(3, 2.0)
    expect(r is not None and r[0] == L._REPLY_OK, "slow sync handler replies later")
    port.close()

    # Python cancel: an async handler is cancelled, no reply.
    async def forever():
        await asyncio.sleep(30)
        return L.LifeBridge(n=0)

    port = L.Builder().life_bridge(forever).open(HOST_ADDR, 1, loop)
    invoke("life_bridge", 4, None)
    time.sleep(0.05)
    CAPTURED["cancel"](CAPTURED["user"], 4)
    time.sleep(0.2)
    expect(4 not in REPLIES, "cancelled async handler sends no reply")
    port.close()

    # W6: a partial of an async function is treated as async.
    async def add(base, x):
        return L.LifeEcho(n=base + x)

    port = L.Builder().life_echo(functools.partial(add, 100)).open(HOST_ADDR, 1, loop)
    invoke("life_echo", 5, {"x": 1})
    r = wait_reply(5, 2.0)
    expect(r is not None and r[0] == L._REPLY_OK and cbor2.loads(r[1]) == {"n": 101},
           "functools.partial(async def) runs as async")
    port.close()

    # W6: async signal handler without a loop warns instead of vanishing.
    async def on_sig(v):
        pass

    port = L.Builder().life_sig(on_sig).open(HOST_ADDR, 1, None)
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        invoke("life_sig", 0, {"v": 1})
    expect(any("without a loop" in str(x.message) for x in w), "async signal without a loop warns")
    port.close()

    loop.call_soon_threadsafe(loop.stop)
    t.join()
    loop.close()
    if failures:
        print(f"ext python wrapper: {failures} check(s) failed")
        return 1
    print("ext python wrapper: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
