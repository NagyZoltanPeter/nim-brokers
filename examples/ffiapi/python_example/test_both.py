#!/usr/bin/env python3
"""Isolate: does subscribing to DeviceStatusChanged alone crash?"""

import sys, time, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


def test_status_only():
    """Subscribe to DeviceStatusChanged only, rapid events that don't trigger it."""
    print("=== DeviceStatusChanged only (no events fire) ===")
    status = []
    with Mylib() as lib:
        lib.init_request("/tmp/test")
        h = lib.on_device_status_changed(lambda did, n, online, ts: status.append(did))
        for i in range(20):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")
        time.sleep(0.5)
        print(f"  Status events: {len(status)} (expected 0)")
        lib.off_device_status_changed(h)
    print("  PASSED\n")


def test_discovered_after_status_registered():
    """Register StatusChanged first, then DeviceDiscovered, fire events."""
    print("=== StatusChanged first, then Discovered ===")
    discovered = []
    with Mylib() as lib:
        lib.init_request("/tmp/test")
        h1 = lib.on_device_status_changed(lambda did, n, online, ts: None)
        h2 = lib.on_device_discovered(lambda did, n, dt, a: discovered.append(did))
        for i in range(20):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")
        time.sleep(0.5)
        print(f"  Discovered: {len(discovered)}")
        lib.off_device_status_changed(h1)
        lib.off_device_discovered(h2)
    print("  PASSED\n")


def test_discovered_only_baseline():
    """DeviceDiscovered only — same count as combined test."""
    print("=== DeviceDiscovered only (baseline) ===")
    discovered = []
    with Mylib() as lib:
        lib.init_request("/tmp/test")
        h = lib.on_device_discovered(lambda did, n, dt, a: discovered.append(did))
        for i in range(20):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")
        time.sleep(0.5)
        print(f"  Discovered: {len(discovered)}")
        lib.off_device_discovered(h)
    print("  PASSED\n")


if __name__ == "__main__":
    print(f"Python {sys.version}\n")
    which = sys.argv[1] if len(sys.argv) > 1 else "all"

    if which in ("1", "all"):
        test_status_only()
    if which in ("2", "all"):
        test_discovered_after_status_registered()
    if which in ("3", "all"):
        test_discovered_only_baseline()

    print("DONE")
