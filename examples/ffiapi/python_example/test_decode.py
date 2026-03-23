#!/usr/bin/env python3
"""Test if .decode() on c_char_p causes the crash."""

import ctypes
import faulthandler
import sys
import time
import os

faulthandler.enable()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))

lib = ctypes.CDLL(os.path.join(os.path.dirname(__file__), "..", "nimlib", "build", "libmylib.dylib"))

lib.mylib_initialize()
lib.mylib_init.restype = ctypes.c_uint32
ctx = lib.mylib_init()
time.sleep(0.2)

lib.init_request_request_with_args.argtypes = [ctypes.c_uint32, ctypes.c_char_p]

DiscCb = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p)
StatusCb = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_char_p, ctypes.c_bool, ctypes.c_int64)

lib.onDeviceDiscovered.argtypes = [ctypes.c_uint32, DiscCb]
lib.onDeviceDiscovered.restype = ctypes.c_uint64
lib.onDeviceStatusChanged.argtypes = [ctypes.c_uint32, StatusCb]
lib.onDeviceStatusChanged.restype = ctypes.c_uint64
lib.offDeviceDiscovered.argtypes = [ctypes.c_uint32, ctypes.c_uint64]
lib.offDeviceStatusChanged.argtypes = [ctypes.c_uint32, ctypes.c_uint64]
lib.add_device_request_with_args.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]

disc_count = [0]

# THIS is the trampoline style used by the wrapper — decodes strings
@DiscCb
def on_disc(did, name, dt, addr):
    n = name.decode("utf-8") if name else ""
    t = dt.decode("utf-8") if dt else ""
    a = addr.decode("utf-8") if addr else ""
    disc_count[0] += 1

@StatusCb
def on_stat(did, name, online, ts):
    pass

_refs = [on_disc, on_stat]

lib.init_request_request_with_args(ctx, b"/tmp/test")
time.sleep(0.1)

# Register DISCOVERED FIRST, then STATUS
h1 = lib.onDeviceDiscovered(ctx, on_disc)
h2 = lib.onDeviceStatusChanged(ctx, on_stat)
print(f"handles: disc={h1}, stat={h2}")

# Fire events
for i in range(15):
    lib.add_device_request_with_args(ctx, f"dev{i}".encode(), b"sensor", f"10.0.0.{i}".encode())

time.sleep(1.0)
print(f"Discovered: {disc_count[0]}")

lib.offDeviceDiscovered(ctx, 0)
lib.offDeviceStatusChanged(ctx, 0)
lib.mylib_shutdown.argtypes = [ctypes.c_uint32]
lib.mylib_shutdown(ctx)
print("DONE — no crash!")
