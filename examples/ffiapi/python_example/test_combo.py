#!/usr/bin/env python3
"""Test specific combinations from the stress test."""

import sys, time, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


def test_A():
    """3 listeners, off, more events."""
    print("A: 3 listeners, off, more events")
    counts = [0, 0, 0]
    with Mylib() as lib:
        lib.create_request("/tmp/test")
        def make_cb(idx):
            def cb(did, n, dt, a): counts[idx] += 1
            return cb
        handles = [lib.on_device_discovered(make_cb(i)) for i in range(3)]
        for i in range(20): lib.add_device(f"d{i}", "s", f"1.0.0.{i}")
        time.sleep(0.5)
        lib.off_device_discovered(handles[1])
        counts = [0, 0, 0]
        for i in range(10): lib.add_device(f"e{i}", "a", f"1.0.1.{i}")
        time.sleep(0.5)
        lib.off_device_discovered(0)
    print(f"  A done: {counts}\n")


def test_B():
    """Both event types."""
    print("B: Both event types")
    disc, stat = [], []
    with Mylib() as lib:
        lib.create_request("/tmp/test")
        h1 = lib.on_device_discovered(lambda did, n, dt, a: disc.append(did))
        h2 = lib.on_device_status_changed(lambda did, n, online, ts: stat.append(did))
        for i in range(15): lib.add_device(f"d{i}", "s", f"1.0.0.{i}")
        time.sleep(0.5)
        print(f"  Disc={len(disc)}, Stat={len(stat)}")
        lib.off_device_discovered(h1)
        lib.off_device_status_changed(h2)
    print("  B done\n")


def test_C():
    """Repeated cycles."""
    print("C: 5 create/shutdown cycles")
    for c in range(5):
        evts = []
        with Mylib() as lib:
            lib.create_request("/tmp/test")
            h = lib.on_device_discovered(lambda did, n, dt, a: evts.append(did))
            for i in range(5): lib.add_device(f"c{c}d{i}", "s", f"1.{c}.0.{i}")
            time.sleep(0.3)
            lib.off_device_discovered(h)
        print(f"  Cycle {c}: {len(evts)}")
    print("  C done\n")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "AB"
    print(f"Running: {which}\n")
    if "A" in which: test_A()
    if "B" in which: test_B()
    if "C" in which: test_C()
    print("DONE")
