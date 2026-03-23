#!/usr/bin/env python3
"""Narrow down: which test transition causes the crash?"""

import sys, time, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


def ctx_with_3_listeners():
    """First stress test: 3 listeners, 20+10 events."""
    print("  ctx_with_3_listeners starting...")
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
        lib.off_device_discovered(handles[1])
        counts = [0, 0, 0]
        for i in range(10):
            lib.add_device(f"extra{i}", "actuator", f"10.0.1.{i}")
        time.sleep(0.5)
        lib.off_device_discovered(0)
    print(f"  ctx_with_3_listeners done: {counts}")


def ctx_simple():
    """Simple: 1 listener, 10 events."""
    print("  ctx_simple starting...")
    count = [0]
    with Mylib() as lib:
        lib.init_request("/tmp/test")
        h = lib.on_device_discovered(lambda did, n, dt, a: count.__setitem__(0, count[0]+1))
        for i in range(10):
            lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")
        time.sleep(0.3)
        lib.off_device_discovered(h)
    print(f"  ctx_simple done: {count[0]} events")


if __name__ == "__main__":
    print(f"Python {sys.version}\n")

    # Test: does running ctx_simple twice crash?
    print("--- Two simple contexts ---")
    ctx_simple()
    ctx_simple()
    print("OK\n")

    # Test: does running ctx_with_3_listeners twice crash?
    print("--- Two 3-listener contexts ---")
    ctx_with_3_listeners()
    print("  First done, starting second...")
    ctx_with_3_listeners()
    print("OK\n")

    print("ALL DONE")
