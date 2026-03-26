#!/usr/bin/env python3
"""Tests for generated Python wrapper — context separation, requests, events, lifecycle.

Build the test library first:
    nimble buildPyTestLib

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

from pytestlib import Pytestlib, PytestlibError


class TestLifecycle(unittest.TestCase):
    """Validate correct initialize and teardown."""

    def test_create_and_shutdown(self):
        lib = Pytestlib()
        self.assertFalse(lib)
        lib.createContext()
        self.assertTrue(lib)
        self.assertNotEqual(lib.ctx, 0)
        lib.shutdown()
        self.assertFalse(lib)

    def test_context_manager(self):
        with Pytestlib() as lib:
            lib.createContext()
            self.assertTrue(lib)
            self.assertNotEqual(lib.ctx, 0)
        # After context manager exit, should be shut down
        self.assertFalse(lib)

    def test_double_shutdown_is_safe(self):
        lib = Pytestlib()
        lib.createContext()
        lib.shutdown()
        lib.shutdown()  # Should not raise

    def test_double_create_raises(self):
        with Pytestlib() as lib:
            lib.createContext()
            with self.assertRaises(PytestlibError):
                lib.createContext()

    def test_request_without_context_raises(self):
        lib = Pytestlib()
        with self.assertRaises(PytestlibError):
            lib.echoRequest("hello")


class TestRequests(unittest.TestCase):
    """Issue multiple requests and validate results."""

    def setUp(self):
        self.lib = Pytestlib()
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
        self.lib = Pytestlib()
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

        deadline = time.monotonic() + 2.0
        while len(received) < 3 and time.monotonic() < deadline:
            time.sleep(0.05)

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

        deadline = time.monotonic() + 2.0
        while len(received) < 1 and time.monotonic() < deadline:
            time.sleep(0.05)

        self.lib.offCounterChanged(handle)
        count_after_off = len(received)

        self.lib.counterRequest()
        time.sleep(0.3)

        # No new events after off
        self.assertEqual(len(received), count_after_off)


class TestContextSeparation(unittest.TestCase):
    """Validate that two library instances have independent state."""

    def test_independent_counters(self):
        with Pytestlib() as lib1, Pytestlib() as lib2:
            lib1.createContext()
            lib2.createContext()
            self.assertNotEqual(lib1.ctx, lib2.ctx)

            lib1.initializeRequest("alpha")
            lib2.initializeRequest("beta")

            # Increment lib1 counter 3 times
            for i in range(1, 4):
                res = lib1.counterRequest()
                self.assertEqual(res.value, i)

            # Increment lib2 counter 2 times — independent
            for i in range(1, 3):
                res = lib2.counterRequest()
                self.assertEqual(res.value, i)

            # lib1 counter continues at 4, not affected by lib2
            res = lib1.counterRequest()
            self.assertEqual(res.value, 4)

    def test_independent_echo(self):
        with Pytestlib() as lib1, Pytestlib() as lib2:
            lib1.createContext()
            lib2.createContext()

            lib1.initializeRequest("one")
            lib2.initializeRequest("two")

            self.assertEqual(lib1.echoRequest("x").reply, "one:x")
            self.assertEqual(lib2.echoRequest("x").reply, "two:x")

    def test_independent_events(self):
        events1: list[int] = []
        events2: list[int] = []

        with Pytestlib() as lib1, Pytestlib() as lib2:
            lib1.createContext()
            lib2.createContext()

            h1 = lib1.onCounterChanged(lambda owner, v: events1.append(v))
            h2 = lib2.onCounterChanged(lambda owner, v: events2.append(v))

            lib1.counterRequest()  # lib1 counter -> 1
            lib1.counterRequest()  # lib1 counter -> 2
            lib2.counterRequest()  # lib2 counter -> 1

            deadline = time.monotonic() + 2.0
            while (len(events1) < 2 or len(events2) < 1) and time.monotonic() < deadline:
                time.sleep(0.05)

            self.assertEqual(events1, [1, 2])
            self.assertEqual(events2, [1])

            lib1.offCounterChanged(h1)
            lib2.offCounterChanged(h2)

    def test_shutdown_one_does_not_affect_other(self):
        lib1 = Pytestlib()
        lib2 = Pytestlib()
        lib1.createContext()
        lib2.createContext()

        lib1.initializeRequest("first")
        lib2.initializeRequest("second")

        lib1.shutdown()

        # lib2 should still work
        res = lib2.echoRequest("still-alive")
        self.assertEqual(res.reply, "second:still-alive")

        lib2.shutdown()


if __name__ == "__main__":
    unittest.main()
