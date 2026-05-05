#!/usr/bin/env python3
"""Tests for generated Python wrapper — covers every Nim→C→Python type mapping.

Type mapping coverage:
  Scalars:    bool, int32, int64, float64, string  (request params + result fields)
  Enum:       Priority                             (request param, result field, event field)
  Distinct:   JobId (int32), Timestamp (int64)     (request param, result field, event field)
  seq result: seq[byte], seq[string], seq[int64], seq[Tag]
  seq params: seq[Tag] (seq[object]), seq[string], seq[int64]
  array:      array[4, int32], array[ConstArrayLen, int32] (result field, event field)
  Events:     all of the above in callback fields

Build the test library first:
    nimble buildTypeMapTestLib

Run:
    nimble testPy
"""

from __future__ import annotations

import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "build"))

from typemappingtestlib import (
    Priority,
    Typemappingtestlib as Lib,
    TypemappingtestlibError as LibError,
    Tag,
)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def wait_for(lst: list, count: int, timeout: float = 2.0) -> None:
    """Poll until lst has at least `count` items or timeout expires."""
    deadline = time.monotonic() + timeout
    while len(lst) < count and time.monotonic() < deadline:
        time.sleep(0.05)


# ---------------------------------------------------------------------------
# Original tests (unchanged)
# ---------------------------------------------------------------------------


class TestLifecycle(unittest.TestCase):
    """Validate correct initialize and teardown."""

    def test_create_and_shutdown(self):
        lib = Lib()
        self.assertFalse(lib)
        lib.createContext()
        self.assertTrue(lib)
        self.assertNotEqual(lib.ctx, 0)
        lib.shutdown()
        self.assertFalse(lib)

    def test_context_manager(self):
        with Lib() as lib:
            lib.createContext()
            self.assertTrue(lib)
            self.assertNotEqual(lib.ctx, 0)
        self.assertFalse(lib)

    def test_double_shutdown_is_safe(self):
        lib = Lib()
        lib.createContext()
        lib.shutdown()
        lib.shutdown()  # Should not raise

    def test_double_create_raises(self):
        with Lib() as lib:
            lib.createContext()
            with self.assertRaises(LibError):
                lib.createContext()

    def test_request_without_context_raises(self):
        lib = Lib()
        with self.assertRaises(LibError):
            lib.echoRequest("hello")


class TestRequests(unittest.TestCase):
    """Issue multiple requests and validate results."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_initialize_request(self):
        res = self.lib.initializeRequest("test-label")
        self.assertEqual(res.label, "test-label")

    def test_echo_request(self):
        self.lib.initializeRequest("ctx-A")
        res = self.lib.echoRequest("hello")
        self.assertEqual(res.reply, "ctx-A:hello")

    def test_counter_request_increments(self):
        for expected in range(1, 4):
            res = self.lib.counterRequest()
            self.assertEqual(res.value, expected)

    def test_multiple_echo_requests(self):
        self.lib.initializeRequest("multi")
        for i in range(5):
            res = self.lib.echoRequest(f"msg-{i}")
            self.assertEqual(res.reply, f"multi:msg-{i}")


class TestEvents(unittest.TestCase):
    """Consume events from the library."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_counter_changed_event(self):
        received: list[tuple[int, int]] = []
        handle = self.lib.onCounterChanged(
            lambda owner, value: received.append((owner.ctx, value))
        )
        self.assertGreater(handle, 0)

        self.lib.counterRequest()
        self.lib.counterRequest()
        self.lib.counterRequest()

        wait_for(received, 3)

        self.assertEqual(len(received), 3)
        self.assertEqual([v for _, v in received], [1, 2, 3])
        for ctx, _ in received:
            self.assertEqual(ctx, self.lib.ctx)

        self.lib.offCounterChanged(handle)

    def test_off_stops_delivery(self):
        received: list[int] = []
        handle = self.lib.onCounterChanged(
            lambda owner, value: received.append(value)
        )
        self.lib.counterRequest()
        wait_for(received, 1)

        self.lib.offCounterChanged(handle)
        count_after_off = len(received)

        self.lib.counterRequest()
        time.sleep(0.3)

        self.assertEqual(len(received), count_after_off)


class TestContextSeparation(unittest.TestCase):
    """Validate that two library instances have independent state."""

    def tearDown(self) -> None:
        # Allow the Nim runtime to fully tear down threads from multi-context
        # tests before the next test creates new contexts. In --mm:refc builds
        # the GC needs a brief window to process pending finalizers.
        time.sleep(0.05)

    def test_independent_counters(self):
        with Lib() as lib1, Lib() as lib2:
            lib1.createContext()
            lib2.createContext()
            self.assertNotEqual(lib1.ctx, lib2.ctx)

            lib1.initializeRequest("alpha")
            lib2.initializeRequest("beta")

            for i in range(1, 4):
                res = lib1.counterRequest()
                self.assertEqual(res.value, i)

            for i in range(1, 3):
                res = lib2.counterRequest()
                self.assertEqual(res.value, i)

            res = lib1.counterRequest()
            self.assertEqual(res.value, 4)

    def test_independent_echo(self):
        with Lib() as lib1, Lib() as lib2:
            lib1.createContext()
            lib2.createContext()

            lib1.initializeRequest("one")
            lib2.initializeRequest("two")

            self.assertEqual(lib1.echoRequest("x").reply, "one:x")
            self.assertEqual(lib2.echoRequest("x").reply, "two:x")

    def test_independent_events(self):
        events1: list[int] = []
        events2: list[int] = []

        with Lib() as lib1, Lib() as lib2:
            lib1.createContext()
            lib2.createContext()

            h1 = lib1.onCounterChanged(lambda owner, v: events1.append(v))
            h2 = lib2.onCounterChanged(lambda owner, v: events2.append(v))

            lib1.counterRequest()
            lib1.counterRequest()
            lib2.counterRequest()

            deadline = time.monotonic() + 2.0
            while (len(events1) < 2 or len(events2) < 1) and time.monotonic() < deadline:
                time.sleep(0.05)

            self.assertEqual(events1, [1, 2])
            self.assertEqual(events2, [1])

            lib1.offCounterChanged(h1)
            lib2.offCounterChanged(h2)

    def test_shutdown_one_does_not_affect_other(self):
        lib1 = Lib()
        lib2 = Lib()
        lib1.createContext()
        lib2.createContext()

        lib1.initializeRequest("first")
        lib2.initializeRequest("second")

        lib1.shutdown()

        res = lib2.echoRequest("still-alive")
        self.assertEqual(res.reply, "second:still-alive")

        lib2.shutdown()


# ---------------------------------------------------------------------------
# Scalar primitive types: bool, int32, int64, float64
# ---------------------------------------------------------------------------


class TestScalarTypes(unittest.TestCase):
    """PrimScalarRequest + PrimScalarEvent: bool, int32, int64, float64 roundtrip."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_bool_true(self):
        res = self.lib.primScalarRequest(True, 0, 0, 0.0)
        self.assertIs(res.flag, True)

    def test_bool_false(self):
        res = self.lib.primScalarRequest(False, 0, 0, 0.0)
        self.assertIs(res.flag, False)

    def test_int32_roundtrip(self):
        res = self.lib.primScalarRequest(False, -2147483648, 0, 0.0)
        self.assertEqual(res.i32, -2147483648)  # INT32_MIN

        res = self.lib.primScalarRequest(False, 2147483647, 0, 0.0)
        self.assertEqual(res.i32, 2147483647)  # INT32_MAX

    def test_int64_roundtrip(self):
        big = 9_000_000_000_000
        res = self.lib.primScalarRequest(False, 0, big, 0.0)
        self.assertEqual(res.i64, big)

    def test_float64_roundtrip(self):
        res = self.lib.primScalarRequest(False, 0, 0, 3.141592653589793)
        self.assertEqual(res.f64, 3.141592653589793)

    def test_all_fields_roundtrip(self):
        res = self.lib.primScalarRequest(True, 42, 1_000_000_000, 2.718)
        self.assertIs(res.flag, True)
        self.assertEqual(res.i32, 42)
        self.assertEqual(res.i64, 1_000_000_000)
        self.assertAlmostEqual(res.f64, 2.718, places=12)

    def test_prim_scalar_event(self):
        evts: list[tuple] = []
        handle = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: evts.append((flag, i32, i64, f64))
        )

        self.lib.primScalarRequest(True, 7, 777777, 1.5)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        flag, i32, i64, f64 = evts[0]
        self.assertIs(flag, True)
        self.assertEqual(i32, 7)
        self.assertEqual(i64, 777777)
        self.assertAlmostEqual(f64, 1.5, places=12)

        self.lib.offPrimScalarEvent(handle)

    def test_prim_scalar_event_false_flag(self):
        evts: list[bool] = []
        handle = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: evts.append(flag)
        )

        self.lib.primScalarRequest(False, 0, 0, 0.0)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertIs(evts[0], False)

        self.lib.offPrimScalarEvent(handle)


# ---------------------------------------------------------------------------
# Enum (Priority) + Distinct (JobId, Timestamp)
# ---------------------------------------------------------------------------


class TestEnumDistinctTypes(unittest.TestCase):
    """TypedScalarRequest + TypedScalarEvent: enum (Priority) and distinct (JobId, Timestamp)."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_enum_roundtrip_low(self):
        res = self.lib.typedScalarRequest(Priority.PRIORITY_P_LOW, 10)
        self.assertEqual(res.priority, Priority.PRIORITY_P_LOW)
        self.assertEqual(int(res.priority), 0)

    def test_enum_roundtrip_high(self):
        res = self.lib.typedScalarRequest(Priority.PRIORITY_P_HIGH, 1)
        self.assertEqual(res.priority, Priority.PRIORITY_P_HIGH)
        self.assertEqual(int(res.priority), 2)

    def test_enum_roundtrip_critical(self):
        res = self.lib.typedScalarRequest(Priority.PRIORITY_P_CRITICAL, 1)
        self.assertEqual(int(res.priority), 3)

    def test_distinct_jobid_echoed(self):
        res = self.lib.typedScalarRequest(Priority.PRIORITY_P_LOW, 5)
        self.assertEqual(res.jobId, 5)

    def test_distinct_jobid_next(self):
        # Provider returns nextId = jobId + 1
        res = self.lib.typedScalarRequest(Priority.PRIORITY_P_LOW, 5)
        self.assertEqual(res.nextId, 6)

    def test_distinct_jobid_zero(self):
        res = self.lib.typedScalarRequest(Priority.PRIORITY_P_MEDIUM, 0)
        self.assertEqual(res.jobId, 0)
        self.assertEqual(res.nextId, 1)

    def test_all_priority_values(self):
        priorities = [
            Priority.PRIORITY_P_LOW,
            Priority.PRIORITY_P_MEDIUM,
            Priority.PRIORITY_P_HIGH,
            Priority.PRIORITY_P_CRITICAL,
        ]
        for p in priorities:
            res = self.lib.typedScalarRequest(p, 1)
            self.assertEqual(res.priority, p)

    def test_typed_scalar_event_enum(self):
        evts: list[tuple] = []
        handle = self.lib.onTypedScalarEvent(
            lambda owner, priority, job_id, ts: evts.append((priority, job_id, ts))
        )

        self.lib.typedScalarRequest(Priority.PRIORITY_P_HIGH, 7)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        priority, job_id, ts = evts[0]
        # priority is wrapped in Priority IntEnum by the trampoline
        self.assertEqual(priority, Priority.PRIORITY_P_HIGH)
        self.assertEqual(int(priority), 2)
        # job_id is a plain int (JobId = int alias)
        self.assertEqual(job_id, 7)
        # ts = int64(jobId) * 10 as computed by provider
        self.assertEqual(ts, 70)

        self.lib.offTypedScalarEvent(handle)

    def test_typed_scalar_event_distinct_timestamp(self):
        evts: list[int] = []
        handle = self.lib.onTypedScalarEvent(
            lambda owner, priority, job_id, ts: evts.append(ts)
        )

        # Provider: ts = Timestamp(int64(jobId) * 10)
        self.lib.typedScalarRequest(Priority.PRIORITY_P_LOW, 3)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], 30)  # 3 * 10

        self.lib.offTypedScalarEvent(handle)

    def test_fixedarray_result_contains_timestamp(self):
        # Timestamp in result field: ts = Timestamp(seed)
        res = self.lib.fixedArrayRequest(99)
        self.assertEqual(res.ts, 99)


# ---------------------------------------------------------------------------
# seq[byte] result
# ---------------------------------------------------------------------------


class TestSeqByteResult(unittest.TestCase):
    """ByteSeqRequest: seq[byte] result field."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_empty_seq_byte(self):
        res = self.lib.byteSeqRequest(0)
        self.assertEqual(res.data, [])

    def test_seq_byte_length(self):
        res = self.lib.byteSeqRequest(8)
        self.assertEqual(len(res.data), 8)

    def test_seq_byte_values(self):
        # Provider: data[i] = i mod 256
        res = self.lib.byteSeqRequest(5)
        self.assertEqual(res.data, [0, 1, 2, 3, 4])

    def test_seq_byte_wrap_around(self):
        res = self.lib.byteSeqRequest(260)
        self.assertEqual(len(res.data), 260)
        self.assertEqual(res.data[0], 0)
        self.assertEqual(res.data[255], 255)
        self.assertEqual(res.data[256], 0)  # wraps at 256

    def test_seq_byte_single_element(self):
        res = self.lib.byteSeqRequest(1)
        self.assertEqual(res.data, [0])

    def test_seq_byte_large(self):
        res = self.lib.byteSeqRequest(100)
        self.assertEqual(len(res.data), 100)
        for i, v in enumerate(res.data):
            self.assertEqual(v, i % 256)


# ---------------------------------------------------------------------------
# seq[string] result + seq[string] input param
# ---------------------------------------------------------------------------


class TestSeqStringTypes(unittest.TestCase):
    """StringSeqRequest (result) + SeqStringParamRequest (input param) + StringSeqEvent."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    # --- seq[string] as result ---

    def test_empty_seq_string_result(self):
        res = self.lib.stringSeqRequest("x", 0)
        self.assertEqual(res.items, [])

    def test_seq_string_result_count(self):
        res = self.lib.stringSeqRequest("item", 4)
        self.assertEqual(len(res.items), 4)

    def test_seq_string_result_values(self):
        res = self.lib.stringSeqRequest("tag", 3)
        self.assertEqual(res.items, ["tag-0", "tag-1", "tag-2"])

    def test_seq_string_result_with_special_chars(self):
        res = self.lib.stringSeqRequest("a/b:c", 2)
        self.assertEqual(res.items, ["a/b:c-0", "a/b:c-1"])

    # --- seq[string] as input param ---

    def test_seq_string_param_empty(self):
        res = self.lib.seqStringParamRequest([])
        self.assertEqual(res.count, 0)
        self.assertEqual(res.joined, "")

    def test_seq_string_param_single(self):
        res = self.lib.seqStringParamRequest(["hello"])
        self.assertEqual(res.count, 1)
        self.assertEqual(res.joined, "hello")

    def test_seq_string_param_multiple(self):
        res = self.lib.seqStringParamRequest(["alpha", "beta", "gamma"])
        self.assertEqual(res.count, 3)
        self.assertEqual(res.joined, "alpha,beta,gamma")

    def test_seq_string_param_unicode(self):
        res = self.lib.seqStringParamRequest(["héllo", "wörld"])
        self.assertEqual(res.count, 2)
        self.assertEqual(res.joined, "héllo,wörld")

    # --- StringSeqEvent: seq[string] in event callback field ---

    def test_string_seq_event(self):
        evts: list[list[str]] = []
        handle = self.lib.onStringSeqEvent(
            lambda owner, items: evts.append(list(items))
        )

        self.lib.stringSeqRequest("ev", 3)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], ["ev-0", "ev-1", "ev-2"])

        self.lib.offStringSeqEvent(handle)

    def test_string_seq_event_empty(self):
        evts: list[list[str]] = []
        handle = self.lib.onStringSeqEvent(
            lambda owner, items: evts.append(list(items))
        )

        self.lib.stringSeqRequest("x", 0)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], [])

        self.lib.offStringSeqEvent(handle)


# ---------------------------------------------------------------------------
# seq[primitive] (seq[int64]) result + input param
# ---------------------------------------------------------------------------


class TestSeqPrimTypes(unittest.TestCase):
    """PrimSeqRequest (result) + PrimSeqParamRequest (input param) + PrimSeqEvent."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    # --- seq[int64] as result ---

    def test_empty_prim_seq_result(self):
        res = self.lib.primSeqRequest(0)
        self.assertEqual(res.values, [])

    def test_prim_seq_result_length(self):
        res = self.lib.primSeqRequest(5)
        self.assertEqual(len(res.values), 5)

    def test_prim_seq_result_values(self):
        # Provider: values[i] = i * 10
        res = self.lib.primSeqRequest(4)
        self.assertEqual(res.values, [0, 10, 20, 30])

    def test_prim_seq_result_large_int64(self):
        res = self.lib.primSeqRequest(3)
        self.assertEqual(res.values[2], 20)  # 2 * 10

    # --- seq[int64] as input param ---

    def test_prim_seq_param_empty(self):
        res = self.lib.primSeqParamRequest([])
        self.assertEqual(res.count, 0)
        self.assertEqual(res.total, 0)

    def test_prim_seq_param_single(self):
        res = self.lib.primSeqParamRequest([42])
        self.assertEqual(res.count, 1)
        self.assertEqual(res.total, 42)

    def test_prim_seq_param_sum(self):
        res = self.lib.primSeqParamRequest([1, 2, 3, 4, 5])
        self.assertEqual(res.count, 5)
        self.assertEqual(res.total, 15)

    def test_prim_seq_param_large_values(self):
        big = 1_000_000_000_000
        res = self.lib.primSeqParamRequest([big, big])
        self.assertEqual(res.count, 2)
        self.assertEqual(res.total, 2 * big)

    # --- PrimSeqEvent: seq[int64] in event callback field ---

    def test_prim_seq_event(self):
        evts: list[list[int]] = []
        handle = self.lib.onPrimSeqEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.primSeqRequest(3)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], [0, 10, 20])

        self.lib.offPrimSeqEvent(handle)

    def test_prim_seq_event_empty(self):
        evts: list[list[int]] = []
        handle = self.lib.onPrimSeqEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.primSeqRequest(0)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], [])

        self.lib.offPrimSeqEvent(handle)


# ---------------------------------------------------------------------------
# array[N, T] result + event
# ---------------------------------------------------------------------------


class TestFixedArrayTypes(unittest.TestCase):
    """FixedArrayRequest (result) + FixedArrayEvent: array[4, int32]."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_array_result_values(self):
        # Provider: [seed, seed*2, seed*3, seed*4]
        res = self.lib.fixedArrayRequest(5)
        self.assertEqual(res.values, [5, 10, 15, 20])

    def test_array_result_length(self):
        res = self.lib.fixedArrayRequest(1)
        self.assertEqual(len(res.values), 4)

    def test_array_result_seed_zero(self):
        res = self.lib.fixedArrayRequest(0)
        self.assertEqual(res.values, [0, 0, 0, 0])

    def test_array_result_negative_seed(self):
        res = self.lib.fixedArrayRequest(-3)
        self.assertEqual(res.values, [-3, -6, -9, -12])

    def test_array_result_timestamp(self):
        # Provider: ts = Timestamp(seed)
        res = self.lib.fixedArrayRequest(42)
        self.assertEqual(res.ts, 42)

    def test_fixed_array_event(self):
        evts: list[list[int]] = []
        handle = self.lib.onFixedArrayEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.fixedArrayRequest(3)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], [3, 6, 9, 12])
        self.assertEqual(len(evts[0]), 4)

        self.lib.offFixedArrayEvent(handle)

    def test_fixed_array_event_zero_seed(self):
        evts: list[list[int]] = []
        handle = self.lib.onFixedArrayEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.fixedArrayRequest(0)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], [0, 0, 0, 0])

        self.lib.offFixedArrayEvent(handle)

    def test_fixed_array_multiple_requests(self):
        evts: list[list[int]] = []
        handle = self.lib.onFixedArrayEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.fixedArrayRequest(1)
        self.lib.fixedArrayRequest(2)
        wait_for(evts, 2)

        self.assertEqual(len(evts), 2)
        self.assertEqual(evts[0], [1, 2, 3, 4])
        self.assertEqual(evts[1], [2, 4, 6, 8])

        self.lib.offFixedArrayEvent(handle)


# ---------------------------------------------------------------------------
# seq[object] — Tag — input param and result
# ---------------------------------------------------------------------------


class TestSeqObjectTypes(unittest.TestCase):
    """ObjSeqParamRequest (input) + ObjSeqResultRequest (result): seq[Tag]."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    # --- seq[Tag] as input param ---

    def test_obj_seq_param_empty(self):
        res = self.lib.objSeqParamRequest([])
        self.assertEqual(res.count, 0)
        self.assertEqual(res.first, "")

    def test_obj_seq_param_single(self):
        tags = [Tag(key="mykey", value="myval")]
        res = self.lib.objSeqParamRequest(tags)
        self.assertEqual(res.count, 1)
        self.assertEqual(res.first, "mykey")

    def test_obj_seq_param_multiple(self):
        tags = [
            Tag(key="first", value="1"),
            Tag(key="second", value="2"),
            Tag(key="third", value="3"),
        ]
        res = self.lib.objSeqParamRequest(tags)
        self.assertEqual(res.count, 3)
        self.assertEqual(res.first, "first")

    def test_obj_seq_param_string_encoding(self):
        # Verify string fields within objects survive the C ABI round-trip
        tags = [Tag(key="key with spaces", value="value/path")]
        res = self.lib.objSeqParamRequest(tags)
        self.assertEqual(res.count, 1)
        self.assertEqual(res.first, "key with spaces")

    # --- seq[Tag] as result ---

    def test_obj_seq_result_empty(self):
        res = self.lib.objSeqResultRequest(0)
        self.assertEqual(res.tags, [])

    def test_obj_seq_result_length(self):
        res = self.lib.objSeqResultRequest(4)
        self.assertEqual(len(res.tags), 4)

    def test_obj_seq_result_keys(self):
        res = self.lib.objSeqResultRequest(3)
        keys = [t.key for t in res.tags]
        self.assertEqual(keys, ["key-0", "key-1", "key-2"])

    def test_obj_seq_result_values(self):
        res = self.lib.objSeqResultRequest(3)
        vals = [t.value for t in res.tags]
        self.assertEqual(vals, ["val-0", "val-1", "val-2"])

    def test_obj_seq_result_tag_type(self):
        res = self.lib.objSeqResultRequest(2)
        for tag in res.tags:
            self.assertTrue(hasattr(tag, "key"))
            self.assertTrue(hasattr(tag, "value"))
            self.assertIsInstance(tag.key, str)
            self.assertIsInstance(tag.value, str)

    def test_obj_seq_roundtrip(self):
        # Generate tags via result, then pass them back as input
        gen = self.lib.objSeqResultRequest(3)
        tags_in = gen.tags

        # Now use them as input: only 'key' and 'value' matter, Tag is a dataclass
        res = self.lib.objSeqParamRequest(tags_in)
        self.assertEqual(res.count, 3)
        self.assertEqual(res.first, "key-0")


# ---------------------------------------------------------------------------
# array[ConstArrayLen, int32] — const-defined size
# ---------------------------------------------------------------------------


class TestConstArraySize(unittest.TestCase):
    """ConstArrayRequest + ConstArrayEvent: array size given by a Nim const (ConstArrayLen=6).

    This exercises the arrayNodeSize nnkSym path in api_codegen_c.nim.
    """

    ARRAY_LEN = 6

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_const_array_result_length(self):
        res = self.lib.constArrayRequest(1)
        self.assertEqual(len(res.values), self.ARRAY_LEN)

    def test_const_array_result_values(self):
        # Provider: values[i] = seed * (i + 1)
        res = self.lib.constArrayRequest(3)
        self.assertEqual(res.values, [3, 6, 9, 12, 15, 18])

    def test_const_array_result_zero_seed(self):
        res = self.lib.constArrayRequest(0)
        self.assertEqual(res.values, [0, 0, 0, 0, 0, 0])

    def test_const_array_result_negative_seed(self):
        res = self.lib.constArrayRequest(-2)
        self.assertEqual(res.values, [-2, -4, -6, -8, -10, -12])

    def test_const_array_event_values(self):
        evts: list[list[int]] = []
        handle = self.lib.onConstArrayEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.constArrayRequest(2)
        wait_for(evts, 1)

        self.assertEqual(len(evts), 1)
        self.assertEqual(evts[0], [2, 4, 6, 8, 10, 12])

        self.lib.offConstArrayEvent(handle)

    def test_const_array_event_length(self):
        evts: list[list[int]] = []
        handle = self.lib.onConstArrayEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.constArrayRequest(1)
        wait_for(evts, 1)

        self.assertEqual(len(evts[0]), self.ARRAY_LEN)

        self.lib.offConstArrayEvent(handle)

    def test_const_array_event_zero_seed(self):
        evts: list[list[int]] = []
        handle = self.lib.onConstArrayEvent(
            lambda owner, values: evts.append(list(values))
        )

        self.lib.constArrayRequest(0)
        wait_for(evts, 1)

        self.assertEqual(evts[0], [0, 0, 0, 0, 0, 0])

        self.lib.offConstArrayEvent(handle)


# ---------------------------------------------------------------------------
# Multi-event stress: multiple listeners, multiple event types
# ---------------------------------------------------------------------------


class TestMultipleEventListeners(unittest.TestCase):
    """Register multiple callbacks for the same event; verify all fire."""

    def setUp(self):
        self.lib = Lib()
        self.lib.createContext()

    def tearDown(self):
        self.lib.shutdown()

    def test_two_scalar_event_listeners(self):
        evts1: list[int] = []
        evts2: list[int] = []

        h1 = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: evts1.append(i32)
        )
        h2 = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: evts2.append(i32)
        )

        self.lib.primScalarRequest(False, 99, 0, 0.0)
        wait_for(evts1, 1)
        wait_for(evts2, 1)

        self.assertEqual(evts1, [99])
        self.assertEqual(evts2, [99])

        self.lib.offPrimScalarEvent(h1)
        self.lib.offPrimScalarEvent(h2)

    def test_remove_one_listener_keeps_other(self):
        evts1: list[int] = []
        evts2: list[int] = []

        h1 = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: evts1.append(i32)
        )
        h2 = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: evts2.append(i32)
        )

        self.lib.primScalarRequest(False, 1, 0, 0.0)
        wait_for(evts1, 1)
        wait_for(evts2, 1)
        self.assertEqual(len(evts1), 1)
        self.assertEqual(len(evts2), 1)

        self.lib.offPrimScalarEvent(h1)

        self.lib.primScalarRequest(False, 2, 0, 0.0)
        wait_for(evts2, 2)
        time.sleep(0.1)

        # h1 was removed — evts1 stays at 1
        self.assertEqual(len(evts1), 1)
        self.assertEqual(len(evts2), 2)
        self.assertEqual(evts2[1], 2)

        self.lib.offPrimScalarEvent(h2)

    def test_concurrent_event_types(self):
        """Fire requests that emit different event types; verify each fires independently."""
        scalar_evts: list[int] = []
        array_evts: list[list[int]] = []
        string_evts: list[list[str]] = []

        hs = self.lib.onPrimScalarEvent(
            lambda owner, flag, i32, i64, f64: scalar_evts.append(i32)
        )
        ha = self.lib.onFixedArrayEvent(
            lambda owner, values: array_evts.append(list(values))
        )
        hst = self.lib.onStringSeqEvent(
            lambda owner, items: string_evts.append(list(items))
        )

        self.lib.primScalarRequest(False, 55, 0, 0.0)
        self.lib.fixedArrayRequest(4)
        self.lib.stringSeqRequest("z", 2)

        wait_for(scalar_evts, 1)
        wait_for(array_evts, 1)
        wait_for(string_evts, 1)

        self.assertEqual(scalar_evts, [55])
        self.assertEqual(array_evts, [[4, 8, 12, 16]])
        self.assertEqual(string_evts, [["z-0", "z-1"]])

        self.lib.offPrimScalarEvent(hs)
        self.lib.offFixedArrayEvent(ha)
        self.lib.offStringSeqEvent(hst)


if __name__ == "__main__":
    unittest.main()
