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

    print(f"\n{'-' * 50}")
    if fail:
        print(f"FAILED: {fail} check(s) did not match", file=sys.stderr)
        return 1
    print("PASS  typemappingtestlib_cbor Python parity")
    return 0


if __name__ == "__main__":
    sys.exit(main())
