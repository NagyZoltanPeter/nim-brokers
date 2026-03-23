#!/usr/bin/env python3
"""Test wrapper class directly — narrow down what causes crash."""

import faulthandler
import sys
import time
import os

faulthandler.enable()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))
from mylib import Mylib


# Test 1: wrapper class, discovered first, simple callback (no decode)
print("Test 1: wrapper class, discovered first, counter-only callbacks")
disc = [0]
stat = [0]

lib = Mylib()
lib.init_request("/tmp/test")

# These callbacks don't decode strings — they use the wrapper's trampoline though
h1 = lib.on_device_discovered(lambda did, n, dt, a: disc.__setitem__(0, disc[0]+1))
h2 = lib.on_device_status_changed(lambda did, n, online, ts: stat.__setitem__(0, stat[0]+1))

for i in range(15):
    lib.add_device(f"dev{i}", "sensor", f"10.0.0.{i}")

time.sleep(1.0)
print(f"  disc={disc[0]}, stat={stat[0]}")
lib.shutdown()
print("  PASSED\n")
