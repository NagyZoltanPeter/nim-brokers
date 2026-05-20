#!/usr/bin/env python3
"""Unified Python parity test for typemappingtestlib (native + CBOR).

Drives the same generated Python wrapper API on both the native FFI
build and the CBOR FFI build. Selection is by environment:

    TYPEMAP_BUILD_DIR=build       # default — native FFI wrapper
    TYPEMAP_BUILD_DIR=build_cbor  # CBOR-mode wrapper

Both wrappers expose:
    class Typemappingtestlib:
        def create_context() -> Result[None]
        def valid_context() -> bool
        def __bool__() -> bool
        def shutdown() -> None
        ctx -> int                    (property)
    Result[T]: .is_ok() / .is_err() / .value / .error / bool(r)
    Priority(IntEnum): pLow / pMedium / pHigh / pCritical

Per-request methods return Result[<TypeName>]; per-event methods follow
on_<name>(callback) -> int  /  off_<name>(handle = 0) -> None where the
callback receives (lib_instance, *unpacked_payload_fields).
"""

from __future__ import annotations

import os
import sys
import threading
import time
import unittest
from pathlib import Path

_BUILD_DIR_NAME = os.environ.get("TYPEMAP_BUILD_DIR", "build")
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE / _BUILD_DIR_NAME))

from typemappingtestlib import (  # noqa: E402
    Priority,
    Result,
    Tag,
    Typemappingtestlib,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _wait_for(predicate, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


def _make_lib() -> Typemappingtestlib:
    """Construct + create_context, asserting success."""
    lib = Typemappingtestlib()
    init = lib.create_context()
    assert init.is_ok(), f"create_context failed: {init.error}"
    return lib


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


class TestLifecycle(unittest.TestCase):
    def test_create_and_shutdown(self):
        lib = Typemappingtestlib()
        self.assertFalse(lib)
        self.assertEqual(lib.ctx, 0)
        r = lib.create_context()
        self.assertTrue(r.is_ok(), r.error)
        self.assertTrue(lib)
        self.assertNotEqual(lib.ctx, 0)
        lib.shutdown()
        self.assertFalse(lib)

    def test_context_manager(self):
        with Typemappingtestlib() as lib:
            self.assertTrue(lib.create_context().is_ok())
            self.assertTrue(lib)
        self.assertFalse(lib)

    def test_double_shutdown_is_safe(self):
        lib = _make_lib()
        lib.shutdown()
        lib.shutdown()  # second call is a no-op

    def test_double_create_returns_err(self):
        lib = _make_lib()
        try:
            r = lib.create_context()
            self.assertTrue(r.is_err())
            self.assertIn("already", r.error.lower())
        finally:
            lib.shutdown()

    def test_request_without_context_returns_err(self):
        lib = Typemappingtestlib()
        try:
            r = lib.echo_request("hi")
            self.assertTrue(r.is_err())
        finally:
            lib.shutdown()


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------


class TestRequests(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_initialize_request(self):
        r = self.lib.initialize_request("ctx-A")
        self.assertTrue(r.is_ok(), r.error)
        self.assertEqual(r.value.label, "ctx-A")

    def test_echo_request(self):
        self.lib.initialize_request("ctx-A")
        r = self.lib.echo_request("hello")
        self.assertTrue(r.is_ok(), r.error)
        self.assertEqual(r.value.reply, "ctx-A:hello")

    def test_counter_increments(self):
        for expected in range(1, 4):
            r = self.lib.counter_request()
            self.assertTrue(r.is_ok())
            self.assertEqual(r.value.value, expected)

    def test_multiple_echo(self):
        self.lib.initialize_request("multi")
        for i in range(5):
            r = self.lib.echo_request(f"m-{i}")
            self.assertTrue(r.is_ok())
            self.assertEqual(r.value.reply, f"multi:m-{i}")

    def test_dual_sig_zero(self):
        r = self.lib.dual_sig_request_zero()
        self.assertTrue(r.is_ok(), r.error)
        self.assertEqual(r.value.label, "zero")
        self.assertEqual(r.value.counter, 0)

    def test_dual_sig_with_label(self):
        r = self.lib.dual_sig_request_with_label("hello", 7)
        self.assertTrue(r.is_ok(), r.error)
        self.assertEqual(r.value.label, "hello")
        self.assertEqual(r.value.counter, 7)


# ---------------------------------------------------------------------------
# Primitive (non-object) broker types
# ---------------------------------------------------------------------------


class TestPrimitiveBrokerTypes(unittest.TestCase):
    """IntResultRequest = int32 and SimpleIntEvent = int64 — broker types
    that are bare primitives rather than objects. The native wrapper exposes
    the result as a dataclass with a single `value` field and the event
    callback as a bare scalar. CBOR-mode codegen for these patterns is not
    yet implemented, so the wrapper omits the method/handler there."""

    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_int_result_request(self):
        if not hasattr(self.lib, "int_result_request"):
            self.skipTest("primitive request result not yet emitted in CBOR build")
        r = self.lib.int_result_request(21)
        self.assertTrue(r.is_ok(), r.error)
        # Native mode: IntResultRequest is a dataclass with a `value` field.
        # CBOR mode: IntResultRequest is the bare `int` alias.
        actual = r.value.value if hasattr(r.value, "value") else r.value
        self.assertEqual(actual, 42)  # provider returns value * 2

    def test_simple_int_event(self):
        if not hasattr(self.lib, "on_simple_int_event"):
            self.skipTest("primitive event payload not yet emitted in CBOR build")
        received = []
        ev = threading.Event()

        def cb(_lib, value):
            received.append(value)
            ev.set()

        h = self.lib.on_simple_int_event(cb)
        self.assertNotEqual(h, 0)
        self.lib.int_result_request(5)  # provider emits SimpleIntEvent(value * 10)
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(received, [50])
        self.lib.off_simple_int_event(h)


# ---------------------------------------------------------------------------
# Void (payload-less) broker types
# ---------------------------------------------------------------------------


class TestVoidBrokerTypes(unittest.TestCase):
    """VoidActionRequest (`type X = void`) and VoidPing (a `void` event).
    The request carries only an ok/err signal; the event callback receives
    no payload argument."""

    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_void_action_request(self):
        ok = self.lib.void_action_request("go")
        self.assertTrue(ok.is_ok(), ok.error)

        bad = self.lib.void_action_request("")  # provider rejects empty label
        self.assertTrue(bad.is_err())

    def test_void_ping_event(self):
        received = []
        ev = threading.Event()

        def cb(_lib):
            received.append(1)
            ev.set()

        h = self.lib.on_void_ping(cb)
        self.assertNotEqual(h, 0)

        self.lib.void_action_request("trigger")  # provider emits VoidPing
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(received, [1])

        self.lib.off_void_ping(h)


# ---------------------------------------------------------------------------
# Scalar types
# ---------------------------------------------------------------------------


class TestScalarTypes(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_bool_true(self):
        r = self.lib.prim_scalar_request(True, 1, 2, 3.5)
        self.assertTrue(r.is_ok())
        self.assertTrue(r.value.flag)

    def test_bool_false(self):
        r = self.lib.prim_scalar_request(False, 0, 0, 0.0)
        self.assertTrue(r.is_ok())
        self.assertFalse(r.value.flag)

    def test_int32_roundtrip(self):
        for v in (-(2**31), 0, 2**31 - 1):
            r = self.lib.prim_scalar_request(False, v, 0, 0.0)
            self.assertTrue(r.is_ok())
            self.assertEqual(r.value.i32, v)

    def test_int64_roundtrip(self):
        for v in (-(2**63), 0, 2**63 - 1, -9_000_000_000_000):
            r = self.lib.prim_scalar_request(False, 0, v, 0.0)
            self.assertTrue(r.is_ok())
            self.assertEqual(r.value.i64, v)

    def test_float64_pi_bits(self):
        pi = 3.141592653589793
        r = self.lib.prim_scalar_request(False, 0, 0, pi)
        self.assertTrue(r.is_ok())
        self.assertAlmostEqual(r.value.f64, pi, places=15)


# ---------------------------------------------------------------------------
# Enum + distinct
# ---------------------------------------------------------------------------


class TestEnumDistinct(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_all_priority_values(self):
        for p in (Priority.pLow, Priority.pMedium, Priority.pHigh, Priority.pCritical):
            r = self.lib.typed_scalar_request(p, 1)
            self.assertTrue(r.is_ok())
            self.assertEqual(r.value.priority, p)

    def test_jobid_zero(self):
        r = self.lib.typed_scalar_request(Priority.pMedium, 0)
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.jobId, 0)
        self.assertEqual(r.value.nextId, 1)

    def test_jobid_max_minus_one(self):
        # rt.jobid_big.nextId — INT32_MAX-1 wraps to INT32_MAX, no overflow
        r = self.lib.typed_scalar_request(Priority.pLow, 2**31 - 2)
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.jobId, 2**31 - 2)
        self.assertEqual(r.value.nextId, 2**31 - 1)


# ---------------------------------------------------------------------------
# Container types — request results
# ---------------------------------------------------------------------------


class TestSeqByte(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_empty(self):
        r = self.lib.byte_seq_request(0)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.data), [])

    def test_length(self):
        r = self.lib.byte_seq_request(5)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.data), [0, 1, 2, 3, 4])

    def test_wrap_around(self):
        r = self.lib.byte_seq_request(260)
        self.assertTrue(r.is_ok())
        data = list(r.value.data)
        self.assertEqual(len(data), 260)
        self.assertEqual(data[0], 0)
        self.assertEqual(data[255], 255)
        self.assertEqual(data[256], 0)

    def test_large(self):
        # rt.byte_seq_large — exercises CBOR multi-byte length encoding
        r = self.lib.byte_seq_request(4096)
        self.assertTrue(r.is_ok())
        self.assertEqual(len(list(r.value.data)), 4096)


class TestSeqString(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_empty_result(self):
        r = self.lib.string_seq_request("x", 0)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.items), [])

    def test_count(self):
        r = self.lib.string_seq_request("x", 3)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.items), ["x-0", "x-1", "x-2"])

    def test_special_chars(self):
        r = self.lib.string_seq_request("a/b:c", 2)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.items), ["a/b:c-0", "a/b:c-1"])

    def test_param_empty(self):
        r = self.lib.seq_string_param_request([])
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.count, 0)

    def test_param_unicode(self):
        r = self.lib.seq_string_param_request(["héllo", "wörld"])
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.count, 2)
        self.assertEqual(r.value.joined, "héllo,wörld")


class TestSeqPrim(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_empty(self):
        r = self.lib.prim_seq_request(0)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [])

    def test_values(self):
        r = self.lib.prim_seq_request(4)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [0, 10, 20, 30])

    def test_param_sum(self):
        r = self.lib.prim_seq_param_request([1, 2, 3, 4])
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.count, 4)
        self.assertEqual(r.value.total, 10)


class TestArrays(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_fixed_array(self):
        r = self.lib.fixed_array_request(5)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [5, 10, 15, 20])
        self.assertEqual(r.value.ts, 5)

    def test_fixed_array_zero(self):
        r = self.lib.fixed_array_request(0)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [0, 0, 0, 0])

    def test_fixed_array_negative(self):
        r = self.lib.fixed_array_request(-3)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [-3, -6, -9, -12])

    def test_const_array(self):
        r = self.lib.const_array_request(3)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [3, 6, 9, 12, 15, 18])

    def test_const_array_zero(self):
        r = self.lib.const_array_request(0)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.values), [0] * 6)


class TestSeqObject(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_seq_tag_result(self):
        r = self.lib.obj_seq_result_request(2)
        self.assertTrue(r.is_ok())
        tags = list(r.value.tags)
        self.assertEqual(len(tags), 2)
        self.assertEqual(tags[0].key, "key-0")
        self.assertEqual(tags[1].value, "val-1")

    def test_seq_tag_empty(self):
        r = self.lib.obj_seq_result_request(0)
        self.assertTrue(r.is_ok())
        self.assertEqual(list(r.value.tags), [])

    def test_seq_tag_param(self):
        tags_in = [Tag(key="alpha", value="1"), Tag(key="beta", value="2")]
        r = self.lib.obj_seq_param_request(tags_in)
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.count, 2)
        self.assertEqual(r.value.first, "alpha")

    def test_obj_as_param(self):
        # Object-as-request-param probe. The broker is gated to CBOR mode
        # in the Nim source — native C/C++/Python/Rust all fail for this
        # pattern (see doc/TYPESUPPORT.md, Section 2). We only assert when
        # running against the CBOR build.
        if _BUILD_DIR_NAME != "build_cbor":
            self.skipTest("obj_param_request only registered in CBOR build")
        r = self.lib.obj_param_request(Tag(key="k", value="v"))
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.summary, "k=v")

    def test_opt_scalar_present(self):
        # Native + CBOR Option[int32] probe (Phase E1).
        r = self.lib.opt_scalar_request(True)
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.value, 42)

    def test_opt_scalar_absent(self):
        r = self.lib.opt_scalar_request(False)
        self.assertTrue(r.is_ok())
        self.assertIsNone(r.value.value)

    def test_opt_string_present(self):
        # Phase E2a — Option[string]. Native + CBOR.
        r = self.lib.opt_string_request(True)
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.value, "hello")

    def test_opt_string_absent(self):
        r = self.lib.opt_string_request(False)
        self.assertTrue(r.is_ok())
        self.assertIsNone(r.value.value)

    def test_opt_obj_present(self):
        # Phase E3 — Option[Tag]. Native + CBOR.
        r = self.lib.opt_obj_request(True)
        self.assertTrue(r.is_ok())
        self.assertIsNotNone(r.value.value)
        self.assertEqual(r.value.value.key, "ok")
        self.assertEqual(r.value.value.value, "yes")

    def test_opt_obj_absent(self):
        r = self.lib.opt_obj_request(False)
        self.assertTrue(r.is_ok())
        self.assertIsNone(r.value.value)

    def test_opt_seq_present(self):
        # Option[seq[byte]] — native E2b + CBOR.
        r = self.lib.opt_seq_request(True)
        self.assertTrue(r.is_ok())
        v = r.value.value
        self.assertIsNotNone(v)
        # CBOR wrapper maps `seq[byte]` (incl. nested in Option) to bytes;
        # native ctypes wrapper materialises into a list[int]. Both are
        # acceptable — assert content equivalence.
        self.assertEqual(bytes(v) if isinstance(v, list) else v, bytes([1, 2, 3, 4]))

    def test_opt_seq_absent(self):
        r = self.lib.opt_seq_request(False)
        self.assertTrue(r.is_ok())
        self.assertIsNone(r.value.value)

    def test_bytes_echo_request_roundtrip(self):
        # Inbound `seq[byte]` byte-string probe — cbor2 encodes Python
        # `bytes` as CBOR byte string (major type 2), which the Nim
        # provider expects. CBOR-only.
        if _BUILD_DIR_NAME != "build_cbor":
            self.skipTest("bytes_echo_request only registered in CBOR build")
        r = self.lib.bytes_echo_request(bytes([10, 20, 30, 40, 50]))
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.length, 5)
        self.assertEqual(r.value.first, 10)
        self.assertEqual(r.value.last, 50)

    def test_bytes_echo_request_empty(self):
        if _BUILD_DIR_NAME != "build_cbor":
            self.skipTest("bytes_echo_request only registered in CBOR build")
        r = self.lib.bytes_echo_request(b"")
        self.assertTrue(r.is_ok())
        self.assertEqual(r.value.length, 0)
        self.assertEqual(r.value.first, -1)
        self.assertEqual(r.value.last, -1)

    def test_scan_request_forward(self):
        if _BUILD_DIR_NAME != "build_cbor":
            self.skipTest("scan_request only registered in CBOR build")
        from typemappingtestlib import KeyRange
        kr = KeyRange(startKey="lo", stopKey="hi")
        r = self.lib.scan_request("scan", kr, False)
        self.assertTrue(r.is_ok())
        self.assertEqual(len(r.value.rows), 3)
        self.assertEqual(r.value.rows[0].key, "0:lo")
        self.assertEqual(r.value.rows[2].key, "2:lo")
        self.assertEqual(r.value.rows[0].payload, "scan-row-0:hi")

    def test_scan_request_reverse(self):
        if _BUILD_DIR_NAME != "build_cbor":
            self.skipTest("scan_request only registered in CBOR build")
        from typemappingtestlib import KeyRange
        kr = KeyRange(startKey="lo", stopKey="hi")
        r = self.lib.scan_request("scan", kr, True)
        self.assertTrue(r.is_ok())
        self.assertEqual(len(r.value.rows), 3)
        self.assertEqual(r.value.rows[0].key, "2:lo")
        self.assertEqual(r.value.rows[2].key, "0:lo")


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------


class TestEvents(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_counter_changed(self):
        received = []
        ev = threading.Event()

        def cb(_lib, value):
            received.append(value)
            ev.set()

        h = self.lib.on_counter_changed(cb)
        self.assertNotEqual(h, 0)
        self.lib.counter_request()
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(received, [1])
        self.lib.off_counter_changed(h)

    def test_off_stops_delivery(self):
        count = [0]

        def cb(_lib, _value):
            count[0] += 1

        h = self.lib.on_counter_changed(cb)
        self.lib.counter_request()
        _wait_for(lambda: count[0] >= 1)
        self.lib.off_counter_changed(h)
        before = count[0]
        self.lib.counter_request()
        time.sleep(0.1)
        self.assertEqual(count[0], before)

    def test_prim_scalar_event(self):
        captured = {}
        ev = threading.Event()

        def cb(_lib, flag, i32, i64, f64):
            captured["flag"] = flag
            captured["i32"] = i32
            captured["i64"] = i64
            captured["f64"] = f64
            ev.set()

        h = self.lib.on_prim_scalar_event(cb)
        self.lib.prim_scalar_request(True, 7, 1234567890123, 3.5)
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(captured["i64"], 1234567890123)
        self.assertEqual(captured["f64"], 3.5)
        self.lib.off_prim_scalar_event(h)

    def test_typed_scalar_event(self):
        captured = {}
        ev = threading.Event()

        def cb(_lib, priority, jobId, ts):
            captured["priority"] = priority
            captured["jobId"] = jobId
            captured["ts"] = ts
            ev.set()

        h = self.lib.on_typed_scalar_event(cb)
        self.lib.typed_scalar_request(Priority.pHigh, 41)
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(captured["priority"], Priority.pHigh)
        self.assertEqual(captured["ts"], 410)
        self.lib.off_typed_scalar_event(h)

    def test_string_seq_event(self):
        captured = {}
        ev = threading.Event()

        def cb(_lib, items):
            captured["items"] = list(items)
            ev.set()

        h = self.lib.on_string_seq_event(cb)
        self.lib.string_seq_request("x", 3)
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(captured["items"], ["x-0", "x-1", "x-2"])
        self.lib.off_string_seq_event(h)

    def test_fixed_array_event(self):
        captured = {}
        ev = threading.Event()

        def cb(_lib, values):
            captured["values"] = list(values)
            ev.set()

        h = self.lib.on_fixed_array_event(cb)
        self.lib.fixed_array_request(5)
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(captured["values"], [5, 10, 15, 20])
        self.lib.off_fixed_array_event(h)

    def test_tag_seq_event(self):
        captured = []
        ev = threading.Event()

        def cb(_lib, tags):
            captured.extend((t.key, t.value) for t in tags)
            ev.set()

        h = self.lib.on_tag_seq_event(cb)
        self.lib.obj_seq_result_request(2)
        self.assertTrue(ev.wait(1.0))
        self.assertEqual(captured, [("key-0", "val-0"), ("key-1", "val-1")])
        self.lib.off_tag_seq_event(h)


# ---------------------------------------------------------------------------
# Multi-listener
# ---------------------------------------------------------------------------


class TestMultipleListeners(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()

    def tearDown(self):
        self.lib.shutdown()

    def test_two_listeners_both_receive(self):
        s1, s2 = [], []
        l1 = threading.Lock()
        l2 = threading.Lock()

        def cb1(_lib, _value):
            with l1:
                s1.append(_value)

        def cb2(_lib, _value):
            with l2:
                s2.append(_value)

        h1 = self.lib.on_counter_changed(cb1)
        h2 = self.lib.on_counter_changed(cb2)
        self.lib.counter_request()
        _wait_for(lambda: len(s1) >= 1 and len(s2) >= 1)
        self.assertEqual(s1, [1])
        self.assertEqual(s2, [1])
        self.lib.off_counter_changed(h1)
        self.lib.off_counter_changed(h2)

    def test_remove_one_keeps_other(self):
        s1, s2 = [], []
        l1, l2 = threading.Lock(), threading.Lock()

        def cb1(_lib, v):
            with l1:
                s1.append(v)

        def cb2(_lib, v):
            with l2:
                s2.append(v)

        h1 = self.lib.on_counter_changed(cb1)
        h2 = self.lib.on_counter_changed(cb2)
        self.lib.counter_request()
        _wait_for(lambda: len(s1) >= 1 and len(s2) >= 1)
        self.lib.off_counter_changed(h1)
        self.lib.counter_request()
        _wait_for(lambda: len(s2) >= 2)
        time.sleep(0.05)
        self.assertEqual(len(s1), 1)
        self.assertEqual(len(s2), 2)
        self.lib.off_counter_changed(h2)


# ---------------------------------------------------------------------------
# Multi-context
# ---------------------------------------------------------------------------


class TestMultiContext(unittest.TestCase):
    def test_independent_counters(self):
        a = _make_lib()
        b = _make_lib()
        try:
            self.assertNotEqual(a.ctx, b.ctx)
            a.initialize_request("alpha")
            b.initialize_request("beta")
            for i in range(1, 4):
                self.assertEqual(a.counter_request().value.value, i)
            for i in range(1, 3):
                self.assertEqual(b.counter_request().value.value, i)
            self.assertEqual(a.counter_request().value.value, 4)
        finally:
            a.shutdown()
            b.shutdown()

    def test_independent_echo(self):
        a = _make_lib()
        b = _make_lib()
        try:
            a.initialize_request("one")
            b.initialize_request("two")
            self.assertEqual(a.echo_request("x").value.reply, "one:x")
            self.assertEqual(b.echo_request("x").value.reply, "two:x")
        finally:
            a.shutdown()
            b.shutdown()


# ---------------------------------------------------------------------------
# Foreign-thread stress (light) — exercise ctypes callback handoff
# ---------------------------------------------------------------------------


class TestForeignThreadStress(unittest.TestCase):
    def setUp(self):
        self.lib = _make_lib()
        self.lib.initialize_request("stress")

    def tearDown(self):
        self.lib.shutdown()

    def test_concurrent_echo(self):
        threads = 4
        iters = 10
        failures = []

        def run(t):
            for i in range(iters):
                r = self.lib.echo_request(f"t{t}-i{i}")
                if not r.is_ok() or not r.value.reply.startswith("stress:"):
                    failures.append(r.error or "bad reply")

        ts = [threading.Thread(target=run, args=(i,)) for i in range(threads)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(failures, [])

    def test_concurrent_seq_object(self):
        threads = 4
        iters = 10
        failures = []

        def run(_):
            for _i in range(iters):
                r = self.lib.obj_seq_result_request(5)
                if not r.is_ok() or len(list(r.value.tags)) != 5:
                    failures.append("bad seq[Tag] count")

        ts = [threading.Thread(target=run, args=(i,)) for i in range(threads)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(failures, [])


# ---------------------------------------------------------------------------
# Listener correctness — seq[object] callback memory safety
# ---------------------------------------------------------------------------


class TestSeqObjectEventMemorySafety(unittest.TestCase):
    def test_callback_data_correctness(self):
        lib = _make_lib()
        try:
            received = []
            lock = threading.Lock()

            def cb(_lib, tags):
                snap = [(t.key, t.value) for t in tags]
                with lock:
                    received.append(snap)

            h = lib.on_tag_seq_event(cb)
            self.assertNotEqual(h, 0)
            for n in (3, 5, 0):
                lib.obj_seq_result_request(n)
            _wait_for(lambda: len(received) >= 3)
            self.assertEqual(len(received), 3)
            self.assertEqual(len(received[0]), 3)
            self.assertEqual(received[0][0], ("key-0", "val-0"))
            self.assertEqual(len(received[1]), 5)
            self.assertEqual(received[1][4], ("key-4", "val-4"))
            self.assertEqual(received[2], [])
            lib.off_tag_seq_event(h)
        finally:
            lib.shutdown()

    def test_rapid_fire_no_leak(self):
        lib = _make_lib()
        try:
            count = [0]
            lock = threading.Lock()

            def cb(_lib, _tags):
                with lock:
                    count[0] += 1

            h = lib.on_tag_seq_event(cb)
            iterations = 50
            for _ in range(iterations):
                lib.obj_seq_result_request(10)
            _wait_for(lambda: count[0] >= iterations, timeout=10.0)
            self.assertEqual(count[0], iterations)
            lib.off_tag_seq_event(h)
        finally:
            lib.shutdown()


if __name__ == "__main__":
    unittest.main(verbosity=2)
