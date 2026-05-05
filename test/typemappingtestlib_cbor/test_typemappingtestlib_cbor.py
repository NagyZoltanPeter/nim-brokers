#!/usr/bin/env python3
"""Python parity test for typemappingtestlib_cbor.

Drives every typed request method and event subscribe on the
generated wrapper, asserting that the round-trip values match the
provider-side computation. This is the Python counterpart to
test_typemappingtestlib_cbor.nim.

Invoked via the brokers.nimble `testTypeMapTestLibCborPy` task,
which first builds the library with ``-d:BrokerFfiApi
-d:BrokerFfiApiCBOR -d:BrokerFfiApiGenPy`` so the generated
``typemappingtestlib_cbor.py`` lands next to the shared object.
"""

from __future__ import annotations

import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
sys.path.insert(0, BUILD)

import typemappingtestlib_cbor as mod  # noqa: E402


def _wait(event: threading.Event, timeout: float = 1.0) -> bool:
    return event.wait(timeout=timeout)


def main() -> int:  # noqa: C901  — the matrix is the matrix
    fail = 0

    def check(name, expected, got):
        nonlocal fail
        if expected != got:
            print(f"FAIL {name}: expected {expected!r}, got {got!r}", file=sys.stderr)
            fail += 1
        else:
            print(f"OK   {name}")

    with mod.Lib() as lib:
        # ----- lifecycle / string param -----
        r = lib.initialize_request(label="hello")
        check("initialize_request.is_ok", True, r.is_ok())
        check("initialize_request.label", "hello", r.value.label)

        # ----- echo concatenates with stored label -----
        r = lib.echo_request(message="ping")
        check("echo_request.reply", "hello:ping", r.value.reply)

        # ----- primitive scalar request + matching event -----
        prim_done = threading.Event()
        prim_evt: dict = {}

        def on_prim(evt: mod.PrimScalarEvent) -> None:
            prim_evt["v"] = evt
            prim_done.set()

        h = lib.subscribe_prim_scalar_event(on_prim)
        assert h >= 2
        r = lib.prim_scalar_request(flag=True, i32=7, i64=1234567890123, f64=3.5)
        check("prim_scalar_request.flag", True, r.value.flag)
        check("prim_scalar_request.i64", 1234567890123, r.value.i64)
        check("prim_scalar_request.f64", 3.5, r.value.f64)
        assert _wait(prim_done), "prim_scalar_event not delivered"
        check("prim_scalar_event.i64", 1234567890123, prim_evt["v"].i64)
        lib.unsubscribe_prim_scalar_event(h)

        # ----- enum + distinct -----
        ts_done = threading.Event()
        ts_evt: dict = {}

        def on_ts(evt: mod.TypedScalarEvent) -> None:
            ts_evt["v"] = evt
            ts_done.set()

        h = lib.subscribe_typed_scalar_event(on_ts)
        r = lib.typed_scalar_request(priority=mod.Priority.pHigh, jobId=41)
        check("typed_scalar_request.priority", mod.Priority.pHigh, r.value.priority)
        check("typed_scalar_request.jobId", 41, r.value.jobId)
        check("typed_scalar_request.nextId", 42, r.value.nextId)
        assert _wait(ts_done)
        check("typed_scalar_event.ts", 410, ts_evt["v"].ts)
        lib.unsubscribe_typed_scalar_event(h)

        # ----- seq[byte] result -----
        r = lib.byte_seq_request(size=5)
        check("byte_seq_request.data", [0, 1, 2, 3, 4], r.value.data)

        # ----- seq[string] result + event -----
        ss_done = threading.Event()
        ss_evt: dict = {}

        def on_ss(evt: mod.StringSeqEvent) -> None:
            ss_evt["v"] = evt
            ss_done.set()

        h = lib.subscribe_string_seq_event(on_ss)
        r = lib.string_seq_request(prefix="x", n=3)
        check("string_seq_request.items", ["x-0", "x-1", "x-2"], r.value.items)
        assert _wait(ss_done)
        check("string_seq_event.items", ["x-0", "x-1", "x-2"], ss_evt["v"].items)
        lib.unsubscribe_string_seq_event(h)

        # ----- seq[int64] result + event -----
        ps_done = threading.Event()

        def on_ps(_evt: mod.PrimSeqEvent) -> None:
            ps_done.set()

        h = lib.subscribe_prim_seq_event(on_ps)
        r = lib.prim_seq_request(n=4)
        check("prim_seq_request.values", [0, 10, 20, 30], r.value.values)
        assert _wait(ps_done)
        lib.unsubscribe_prim_seq_event(h)

        # ----- array[4, int32] -----
        fa_done = threading.Event()

        def on_fa(_evt: mod.FixedArrayEvent) -> None:
            fa_done.set()

        h = lib.subscribe_fixed_array_event(on_fa)
        r = lib.fixed_array_request(seed=5)
        check("fixed_array_request.values", [5, 10, 15, 20], r.value.values)
        check("fixed_array_request.ts", 5, r.value.ts)
        assert _wait(fa_done)
        lib.unsubscribe_fixed_array_event(h)

        # ----- array[ConstArrayLen, int32] -----
        r = lib.const_array_request(seed=3)
        check("const_array_request.values", [3, 6, 9, 12, 15, 18], r.value.values)

        # ----- seq[Tag] result + tag_seq_event -----
        tag_done = threading.Event()
        tag_evt: dict = {}

        def on_tag(evt: mod.TagSeqEvent) -> None:
            tag_evt["v"] = evt
            tag_done.set()

        h = lib.subscribe_tag_seq_event(on_tag)
        r = lib.obj_seq_result_request(n=2)
        got_tags = [(t.key, t.value) for t in r.value.tags]
        check("obj_seq_result_request.tags",
              [("key-0", "val-0"), ("key-1", "val-1")], got_tags)
        assert _wait(tag_done)
        evt_tags = [(t.key, t.value) for t in tag_evt["v"].tags]
        check("tag_seq_event.tags",
              [("key-0", "val-0"), ("key-1", "val-1")], evt_tags)
        lib.unsubscribe_tag_seq_event(h)

        # ----- seq[Tag] INPUT param -----
        tags_in = [mod.Tag(key="alpha", value="1"), mod.Tag(key="beta", value="2")]
        r = lib.obj_seq_param_request(tags=tags_in)
        check("obj_seq_param_request.count", 2, r.value.count)
        check("obj_seq_param_request.first", "alpha", r.value.first)

        # ----- seq[string] INPUT param -----
        r = lib.seq_string_param_request(items=["a", "b", "c"])
        check("seq_string_param_request.count", 3, r.value.count)
        check("seq_string_param_request.joined", "a,b,c", r.value.joined)

        # ----- seq[int64] INPUT param -----
        r = lib.prim_seq_param_request(values=[1, 2, 3, 4])
        check("prim_seq_param_request.count", 4, r.value.count)
        check("prim_seq_param_request.total", 10, r.value.total)

        # ----- counter request emits counter_changed -----
        cc_done = threading.Event()
        cc_evt: dict = {}

        def on_cc(evt: mod.CounterChanged) -> None:
            cc_evt["v"] = evt
            cc_done.set()

        h = lib.subscribe_counter_changed(on_cc)
        r = lib.counter_request()
        check("counter_request.value", r.value.value, r.value.value)
        assert _wait(cc_done)
        check("counter_changed.value", r.value.value, cc_evt["v"].value)
        lib.unsubscribe_counter_changed(h)

        # ====================================================================
        # Round-trip matrix expansion (Phase 9A) — boundary / edge values
        # ====================================================================

        # bool false
        r = lib.prim_scalar_request(flag=False, i32=0, i64=0, f64=0.0)
        check("rt.bool_false.flag", False, r.value.flag)

        # int32 boundaries
        INT32_MIN, INT32_MAX = -(2 ** 31), (2 ** 31) - 1
        r = lib.prim_scalar_request(flag=False, i32=INT32_MIN, i64=0, f64=0.0)
        check("rt.int32_min.i32", INT32_MIN, r.value.i32)
        r = lib.prim_scalar_request(flag=False, i32=INT32_MAX, i64=0, f64=0.0)
        check("rt.int32_max.i32", INT32_MAX, r.value.i32)

        # int64 boundaries
        INT64_MIN, INT64_MAX = -(2 ** 63), (2 ** 63) - 1
        r = lib.prim_scalar_request(flag=False, i32=0, i64=INT64_MIN, f64=0.0)
        check("rt.int64_min.i64", INT64_MIN, r.value.i64)
        r = lib.prim_scalar_request(flag=False, i32=0, i64=INT64_MAX, f64=0.0)
        check("rt.int64_max.i64", INT64_MAX, r.value.i64)
        r = lib.prim_scalar_request(flag=False, i32=0, i64=-9_000_000_000_000, f64=0.0)
        check("rt.int64_neg.i64", -9_000_000_000_000, r.value.i64)

        # float64 fidelity
        pi = 3.141592653589793
        r = lib.prim_scalar_request(flag=False, i32=0, i64=0, f64=pi)
        check("rt.float64_pi.f64", pi, r.value.f64)

        # enum: every Priority value
        for p in (mod.Priority.pLow, mod.Priority.pMedium,
                  mod.Priority.pHigh, mod.Priority.pCritical):
            r = lib.typed_scalar_request(priority=p, jobId=1)
            check("rt.priority_roundtrip", int(p), int(r.value.priority))

        # distinct JobId boundaries
        r = lib.typed_scalar_request(priority=mod.Priority.pLow, jobId=0)
        check("rt.jobid_zero.jobId", 0, r.value.jobId)
        check("rt.jobid_zero.nextId", 1, r.value.nextId)
        r = lib.typed_scalar_request(priority=mod.Priority.pLow, jobId=INT32_MAX - 1)
        check("rt.jobid_big.nextId", INT32_MAX, r.value.nextId)

        # byte seq: empty, single, wrap-around
        r = lib.byte_seq_request(size=0)
        check("rt.byte_seq_empty.size", 0, len(r.value.data))
        r = lib.byte_seq_request(size=1)
        check("rt.byte_seq_single.value", 0, r.value.data[0])
        r = lib.byte_seq_request(size=260)
        check("rt.byte_seq_wrap.size", 260, len(r.value.data))
        check("rt.byte_seq_wrap[255]", 255, r.value.data[255])
        check("rt.byte_seq_wrap[256]", 0, r.value.data[256])

        # string seq result: empty, special chars
        r = lib.string_seq_request(prefix="x", n=0)
        check("rt.string_seq_empty.size", 0, len(r.value.items))
        r = lib.string_seq_request(prefix="a/b:c", n=2)
        check("rt.string_seq_special[0]", "a/b:c-0", r.value.items[0])

        # prim seq result: empty, single
        r = lib.prim_seq_request(n=0)
        check("rt.prim_seq_empty.size", 0, len(r.value.values))
        r = lib.prim_seq_request(n=1)
        check("rt.prim_seq_single.values", [0], r.value.values)

        # fixed array: seed=0, negative
        r = lib.fixed_array_request(seed=0)
        check("rt.fixed_array_zero.values", [0, 0, 0, 0], r.value.values)
        check("rt.fixed_array_zero.ts", 0, r.value.ts)
        r = lib.fixed_array_request(seed=-3)
        check("rt.fixed_array_neg.values", [-3, -6, -9, -12], r.value.values)

        # const array: seed=0, seed=1
        r = lib.const_array_request(seed=0)
        check("rt.const_array_zero.values", [0, 0, 0, 0, 0, 0], r.value.values)
        r = lib.const_array_request(seed=1)
        check("rt.const_array_one.values", [1, 2, 3, 4, 5, 6], r.value.values)

        # obj seq result: empty
        r = lib.obj_seq_result_request(n=0)
        check("rt.obj_seq_result_empty.size", 0, len(r.value.tags))

        # obj seq param: empty
        r = lib.obj_seq_param_request(tags=[])
        check("rt.obj_seq_param_empty.count", 0, r.value.count)
        check("rt.obj_seq_param_empty.first", "", r.value.first)

        # string seq param: empty, single, unicode
        r = lib.seq_string_param_request(items=[])
        check("rt.seq_string_param_empty.count", 0, r.value.count)
        r = lib.seq_string_param_request(items=["hello"])
        check("rt.seq_string_param_single.joined", "hello", r.value.joined)
        r = lib.seq_string_param_request(items=["héllo", "wörld"])
        check("rt.seq_string_param_unicode.joined", "héllo,wörld", r.value.joined)

        # prim seq param: empty, single, large
        r = lib.prim_seq_param_request(values=[])
        check("rt.prim_seq_param_empty.count", 0, r.value.count)
        check("rt.prim_seq_param_empty.total", 0, r.value.total)
        r = lib.prim_seq_param_request(values=[42])
        check("rt.prim_seq_param_single.total", 42, r.value.total)
        big = list(range(100))
        r = lib.prim_seq_param_request(values=big)
        check("rt.prim_seq_param_large.count", 100, r.value.count)
        check("rt.prim_seq_param_large.total", sum(big), r.value.total)

    # ========================================================================
    # Lifecycle parity (Phase 9B) — exercise edge cases on the C ABI
    # directly, since the Python Lib class is RAII-shaped.
    # ========================================================================
    import ctypes  # noqa: E402
    raw = mod._LIB

    # 1) create_and_shutdown — happy path via raw C ABI
    raw.typemappingtestlib_cbor_initialize()
    err_p = ctypes.c_char_p()
    ctx = raw.typemappingtestlib_cbor_createContext(ctypes.byref(err_p))
    check("lc.create_and_shutdown.ctx_nonzero", True, ctx != 0)
    st = raw.typemappingtestlib_cbor_shutdown(ctx)
    check("lc.create_and_shutdown.shutdown_ok", 0, st)

    # 2) RAII via context manager — reusing Lib() after a previous Lib
    #    closed must succeed (no global corruption).
    saved = None
    with mod.Lib() as scoped:
        check("lc.raii.scoped_isOk", True, scoped.context != 0)
        saved = scoped.context
    after = mod.Lib()
    try:
        check("lc.raii.after_scope_isOk", True, after.context != 0)
        check("lc.raii.distinct_ctx", True, after.context != saved)
    finally:
        after.close()

    # 3) double_shutdown_is_safe
    err_p = ctypes.c_char_p()
    c = raw.typemappingtestlib_cbor_createContext(ctypes.byref(err_p))
    s1 = raw.typemappingtestlib_cbor_shutdown(c)
    s2 = raw.typemappingtestlib_cbor_shutdown(c)
    check("lc.double_shutdown.first_ok", 0, s1)
    check("lc.double_shutdown.second_returns_neg1", -1, s2)

    # 4) shutdown_unknown_ctx_safe
    s = raw.typemappingtestlib_cbor_shutdown(0xDEADBEEF)
    check("lc.shutdown_unknown.returns_neg1", -1, s)

    # 5) call_with_invalid_ctx — must not succeed (either non-zero
    #    framework status, or status==0 with err envelope).
    import cbor2  # noqa: E402
    resp_buf = ctypes.c_void_p()
    resp_len = ctypes.c_int32()
    st = raw.typemappingtestlib_cbor_call(
        0, b"echo_request", None, 0, ctypes.byref(resp_buf), ctypes.byref(resp_len)
    )
    not_ok = st != 0
    if st == 0 and resp_buf and resp_len.value > 0:
        payload = ctypes.string_at(resp_buf, resp_len.value)
        try:
            env = cbor2.loads(payload)
            not_ok = isinstance(env, dict) and ("err" in env) and ("ok" not in env)
        except Exception:
            not_ok = True
    if resp_buf:
        raw.typemappingtestlib_cbor_freeBuffer(resp_buf)
    check("lc.call_with_zero_ctx.does_not_succeed", True, not_ok)

    # ========================================================================
    # Multi-context parity (Phase 9C)
    # ========================================================================

    # 1) independent counters
    with mod.Lib() as a, mod.Lib() as b:
        check("mc.counters.distinct_ctx", True, a.context != b.context)
        a.initialize_request(label="alpha")
        b.initialize_request(label="beta")
        for i in range(1, 4):
            check("mc.counters.a_increment", i, a.counter_request().value.value)
        for i in range(1, 3):
            check("mc.counters.b_increment", i, b.counter_request().value.value)
        check("mc.counters.a_continues", 4, a.counter_request().value.value)

    # 2) independent echo
    with mod.Lib() as a, mod.Lib() as b:
        a.initialize_request(label="one")
        b.initialize_request(label="two")
        check("mc.echo.a", "one:x", a.echo_request(message="x").value.reply)
        check("mc.echo.b", "two:x", b.echo_request(message="x").value.reply)

    # 3) independent events (no cross-delivery)
    with mod.Lib() as a, mod.Lib() as b:
        a_evts: list = []
        b_evts: list = []
        a_lock = threading.Lock()
        b_lock = threading.Lock()
        a_done = threading.Event()
        b_done = threading.Event()

        def on_a(e: mod.CounterChanged) -> None:
            with a_lock:
                a_evts.append(e.value)
                if len(a_evts) >= 2:
                    a_done.set()

        def on_b(e: mod.CounterChanged) -> None:
            with b_lock:
                b_evts.append(e.value)
                if len(b_evts) >= 1:
                    b_done.set()

        hA = a.subscribe_counter_changed(on_a)
        hB = b.subscribe_counter_changed(on_b)
        a.counter_request()
        a.counter_request()
        b.counter_request()
        assert _wait(a_done, 1.0)
        assert _wait(b_done, 1.0)
        with a_lock:
            check("mc.events.a_size", 2, len(a_evts))
            check("mc.events.a", [1, 2], a_evts)
        with b_lock:
            check("mc.events.b_size", 1, len(b_evts))
            check("mc.events.b", [1], b_evts)
        a.unsubscribe_counter_changed(hA)
        b.unsubscribe_counter_changed(hB)

    # 4) shutdown_one_does_not_affect_other
    b = mod.Lib()
    try:
        b.initialize_request(label="second")
        with mod.Lib() as a:
            a.initialize_request(label="first")
            check("mc.shutdown_one.a_works", "first:hello",
                  a.echo_request(message="hello").value.reply)
        # a is closed; b still works
        r = b.echo_request(message="still-alive")
        check("mc.shutdown_one.b_still_works", True, r.is_ok())
        check("mc.shutdown_one.b_reply", "second:still-alive", r.value.reply)
    finally:
        b.close()

    print(f"\n{'-' * 50}")
    if fail:
        print(f"FAILED: {fail} check(s) did not match", file=sys.stderr)
        return 1
    print("PASS  typemappingtestlib_cbor Python parity")
    return 0


if __name__ == "__main__":
    sys.exit(main())
