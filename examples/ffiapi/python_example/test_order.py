#!/usr/bin/env python3
"""Does registration ORDER matter?"""

import sys, time, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


def test_status_first():
    """Register StatusChanged FIRST, then Discovered."""
    print("=== StatusChanged first ===")
    disc = []
    with Mylib() as lib:
        lib.init_request("/tmp/test")
        h1 = lib.on_device_status_changed(lambda did, n, o, ts: None)
        h2 = lib.on_device_discovered(lambda did, n, dt, a: disc.append(did))
        for i in range(15):
            lib.add_device(f"d{i}", "s", f"1.0.0.{i}")
        time.sleep(0.5)
        print(f"  Discovered: {len(disc)}")
        lib.off_device_status_changed(h1)
        lib.off_device_discovered(h2)
    print("  PASSED\n")


def test_discovered_first():
    """Register Discovered FIRST, then StatusChanged."""
    print("=== Discovered first ===")
    disc = []
    with Mylib() as lib:
        lib.init_request("/tmp/test")
        h1 = lib.on_device_discovered(lambda did, n, dt, a: disc.append(did))
        h2 = lib.on_device_status_changed(lambda did, n, o, ts: None)
        for i in range(15):
            lib.add_device(f"d{i}", "s", f"1.0.0.{i}")
        time.sleep(0.5)
        print(f"  Discovered: {len(disc)}")
        lib.off_device_discovered(h1)
        lib.off_device_status_changed(h2)
    print("  PASSED\n")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    if which in ("1", "status", "both"):
        test_status_first()
    if which in ("2", "disc", "both"):
        test_discovered_first()
    print("DONE")
