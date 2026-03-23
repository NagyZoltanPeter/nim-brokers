#!/usr/bin/env python3
"""Stress test for Python event callbacks — multiple listeners, rapid fire."""

import sys
import time
import os
import threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib, MylibError


def test_multiple_listeners():
    """Multiple listeners for the same event, rapid-fire."""
    print("=== Multiple listeners, rapid-fire ===")
    counts = [0, 0, 0]

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def make_cb(idx):
            def cb(device_id, name, device_type, address):
                counts[idx] += 1
            return cb

        handles = []
        for i in range(3):
            h = lib.on_device_discovered(make_cb(i))
            handles.append(h)
            print(f"  Listener {i}: handle={h}")

        for i in range(20):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(0.5)
        print(f"  Events per listener: {counts}")
        assert all(c == 20 for c in counts), f"Expected 20 each, got {counts}"

        # Remove one listener
        lib.off_device_discovered(handles[1])
        counts = [0, 0, 0]

        for i in range(10):
            lib.add_device(f"extra{i}", "actuator", f"10.0.1.{i}")

        time.sleep(0.5)
        print(f"  After removing listener 1: {counts}")
        assert counts[0] == 10 and counts[1] == 0 and counts[2] == 10

        # Remove all
        lib.off_device_discovered(0)

    print("  PASSED\n")


def test_both_event_types():
    """Subscribe to both event types simultaneously."""
    print("=== Both event types, rapid-fire ===")
    discovered = []
    status_changed = []

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def on_disc(device_id, name, device_type, address):
            discovered.append(device_id)

        def on_status(device_id, name, online, timestamp_ms):
            status_changed.append((device_id, online))

        h1 = lib.on_device_discovered(on_disc)
        h2 = lib.on_device_status_changed(on_status)

        for i in range(15):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

        time.sleep(0.5)
        print(f"  Discovered events: {len(discovered)}")
        print(f"  Status events: {len(status_changed)}")

        lib.off_device_discovered(h1)
        lib.off_device_status_changed(h2)

    print("  PASSED\n")


def test_repeated_init_shutdown():
    """Repeated create/shutdown cycles with events."""
    print("=== Repeated create/shutdown cycles ===")
    for cycle in range(5):
        events = []
        with Mylib() as lib:
            lib.create_request("/tmp/test")
            h = lib.on_device_discovered(lambda did, n, dt, a: events.append(did))
            for i in range(5):
                lib.add_device(f"c{cycle}d{i}", "sensor", f"10.0.{cycle}.{i}")
            time.sleep(0.3)
            lib.off_device_discovered(h)
        print(f"  Cycle {cycle}: {len(events)} events")
        assert len(events) == 5

    print("  PASSED\n")


if __name__ == "__main__":
    print(f"Python {sys.version}\n")
    test_multiple_listeners()
    test_both_event_types()
    test_repeated_init_shutdown()
    print("ALL STRESS TESTS PASSED")
