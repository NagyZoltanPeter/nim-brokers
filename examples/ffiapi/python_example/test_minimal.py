#!/usr/bin/env python3
"""Minimal reproduction — isolate the crash."""

import sys
import time
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


def test_single_listener_many_events():
    """Single listener, many rapid events — no off() call."""
    print("=== Single listener, 50 rapid events ===")
    count = [0]

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def on_disc(device_id, name, device_type, address):
            count[0] += 1

        h = lib.on_device_discovered(on_disc)

        for i in range(50):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(1.0)
        print(f"  Events: {count[0]}")
    print("  PASSED\n")


def test_three_listeners_many_events():
    """Three listeners, many rapid events — no off() call."""
    print("=== 3 listeners, 30 rapid events ===")
    counts = [0, 0, 0]

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def make_cb(idx):
            def cb(did, n, dt, a):
                counts[idx] += 1
            return cb

        handles = []
        for i in range(3):
            handles.append(lib.on_device_discovered(make_cb(i)))

        for i in range(30):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(1.0)
        print(f"  Events per listener: {counts}")
    print("  PASSED\n")


def test_off_then_more_events():
    """Register, fire events, off(), fire more events."""
    print("=== off() then more events ===")
    counts = [0, 0, 0]

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def make_cb(idx):
            def cb(did, n, dt, a):
                counts[idx] += 1
            return cb

        handles = []
        for i in range(3):
            handles.append(lib.on_device_discovered(make_cb(i)))

        for i in range(10):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(0.5)
        print(f"  Before off: {counts}")

        # Remove middle listener
        lib.off_device_discovered(handles[1])
        time.sleep(0.1)  # small gap

        counts = [0, 0, 0]
        for i in range(10):
            lib.add_device(f"extra{i}", "actuator", f"10.0.1.{i}")

        time.sleep(0.5)
        print(f"  After off: {counts}")
    print("  PASSED\n")


if __name__ == "__main__":
    print(f"Python {sys.version}\n")
    test_single_listener_many_events()
    test_three_listeners_many_events()
    test_off_then_more_events()
    print("ALL PASSED")
