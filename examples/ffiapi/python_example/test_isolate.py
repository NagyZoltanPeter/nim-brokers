#!/usr/bin/env python3
"""Isolate which stress test function crashes."""

import sys
import time
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


def test_off_no_sleep():
    """Replicate stress test: off() then immediate add_device calls (no sleep)."""
    print("=== off() then immediate events (no sleep) ===")
    counts = [0, 0, 0]

    with Mylib() as lib:
        lib.init_request("/tmp/test")

        def make_cb(idx):
            def cb(did, n, dt, a):
                counts[idx] += 1
            return cb

        handles = []
        for i in range(3):
            handles.append(lib.on_device_discovered(make_cb(i)))

        for i in range(20):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(0.5)
        print(f"  Before off: {counts}")

        # Remove one listener — NO sleep after
        lib.off_device_discovered(handles[1])
        counts = [0, 0, 0]

        for i in range(10):
            lib.add_device(f"extra{i}", "actuator", f"10.0.1.{i}")

        time.sleep(0.5)
        print(f"  After off: {counts}")

        # Remove all — NO sleep after
        lib.off_device_discovered(0)

    print("  PASSED\n")


def test_multiple_contexts():
    """Multiple Mylib instances sequentially."""
    print("=== Multiple sequential contexts ===")
    for cycle in range(5):
        events = []
        with Mylib() as lib:
            lib.init_request("/tmp/test")
            h = lib.on_device_discovered(lambda did, n, dt, a: events.append(did))
            for i in range(10):
                lib.add_device(f"c{cycle}d{i}", "sensor", f"10.0.{cycle}.{i}")
            time.sleep(0.3)
            lib.off_device_discovered(h)
        print(f"  Cycle {cycle}: {len(events)} events")

    print("  PASSED\n")


def test_both_event_types():
    """Subscribe to both event types."""
    print("=== Both event types ===")
    discovered = []
    status_changed = []

    with Mylib() as lib:
        lib.init_request("/tmp/test")

        def on_disc(did, n, dt, a):
            discovered.append(did)

        def on_status(did, n, online, ts):
            status_changed.append((did, online))

        h1 = lib.on_device_discovered(on_disc)
        h2 = lib.on_device_status_changed(on_status)

        for i in range(15):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(0.5)
        print(f"  Discovered: {len(discovered)}, Status: {len(status_changed)}")

        lib.off_device_discovered(h1)
        lib.off_device_status_changed(h2)

    print("  PASSED\n")


if __name__ == "__main__":
    print(f"Python {sys.version}\n")

    which = sys.argv[1] if len(sys.argv) > 1 else "all"

    if which in ("1", "off", "all"):
        test_off_no_sleep()
    if which in ("2", "ctx", "all"):
        test_multiple_contexts()
    if which in ("3", "both", "all"):
        test_both_event_types()

    print("DONE")
