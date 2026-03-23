#!/usr/bin/env python3
"""Debug: use wrapper class but print cb pointer values."""

import ctypes
import faulthandler
import sys
import time
import os

faulthandler.enable()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib

lib = Mylib()
print(f"ctx = {lib.ctx}")
lib.init_request("/tmp/test")

# Print the CFUNCTYPE classes
print(f"DiscCCallback type: {lib._DeviceDiscoveredCCallback}")
print(f"StatCCallback type: {lib._DeviceStatusChangedCCallback}")

# Register discovered first
disc_count = [0]
h1 = lib.on_device_discovered(lambda did, n, dt, a: disc_count.__setitem__(0, disc_count[0]+1))
print(f"Discovered handle: {h1}")

# Print the stored callback
cb1 = lib._cb_refs.get(h1)
print(f"Stored cb1: {cb1}")
print(f"cb1 ptr: {ctypes.cast(cb1, ctypes.c_void_p).value:#x}" if cb1 else "None")

# Register status changed
stat_count = [0]
h2 = lib.on_device_status_changed(lambda did, n, o, ts: stat_count.__setitem__(0, stat_count[0]+1))
print(f"StatusChanged handle: {h2}")

cb2 = lib._cb_refs.get(h2)
print(f"Stored cb2: {cb2}")
print(f"cb2 ptr: {ctypes.cast(cb2, ctypes.c_void_p).value:#x}" if cb2 else "None")

# Check if h1 and h2 collide
print(f"\nh1={h1}, h2={h2}, h1==h2: {h1==h2}")
print(f"cb_refs keys: {list(lib._cb_refs.keys())}")
print(f"cb_refs values: {list(lib._cb_refs.values())}")

# If h1 == h2, the second registration overwrites the first in _cb_refs!
if h1 == h2:
    print("\n*** HANDLE COLLISION! h1 and h2 have the same handle value!")
    print("*** The first callback ref was overwritten in _cb_refs!")
    print("*** This means the first CFUNCTYPE object may be garbage collected!")

# Fire events
print("\nFiring 5 events...")
for i in range(5):
    lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

time.sleep(1.0)
print(f"Discovered: {disc_count[0]}, Status: {stat_count[0]}")

lib.shutdown()
print("DONE")
