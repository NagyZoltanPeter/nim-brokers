#!/usr/bin/env python3
"""Replicate wrapper class logic in raw ctypes."""

import ctypes
import faulthandler
import sys
import time
import os

faulthandler.enable()

libpath = os.path.join(os.path.dirname(__file__), "..", "nimlib", "build", "libmylib.dylib")
_lib = ctypes.CDLL(libpath)

# Same as _setup_signatures
_lib.mylib_initialize.argtypes = []
_lib.mylib_initialize.restype = None
_lib.mylib_create.argtypes = []
_lib.mylib_create.restype = ctypes.c_uint32
_lib.mylib_shutdown.argtypes = [ctypes.c_uint32]
_lib.mylib_shutdown.restype = None
_lib.create_request_request_with_args.argtypes = [ctypes.c_uint32, ctypes.c_char_p]
# Skip restype for create request — we just call it
_lib.add_device_request_with_args.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
# Skip restype for add_device — we just call it

# Create CFUNCTYPE as instance attributes would be
_DeviceStatusChangedCCallback = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_char_p, ctypes.c_bool, ctypes.c_int64)
_lib.onDeviceStatusChanged.argtypes = [ctypes.c_uint32, _DeviceStatusChangedCCallback]
_lib.onDeviceStatusChanged.restype = ctypes.c_uint64
_lib.offDeviceStatusChanged.argtypes = [ctypes.c_uint32, ctypes.c_uint64]
_lib.offDeviceStatusChanged.restype = None

_DeviceDiscoveredCCallback = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p)
_lib.onDeviceDiscovered.argtypes = [ctypes.c_uint32, _DeviceDiscoveredCCallback]
_lib.onDeviceDiscovered.restype = ctypes.c_uint64
_lib.offDeviceDiscovered.argtypes = [ctypes.c_uint32, ctypes.c_uint64]
_lib.offDeviceDiscovered.restype = None

# Create context
_lib.mylib_initialize()
ctx = _lib.mylib_create()
time.sleep(0.2)

_lib.create_request_request_with_args(ctx, b"/tmp/test")
time.sleep(0.1)

# Create trampolines exactly like the wrapper class does
_cb_refs = {}

disc_count = [0]
def user_disc_cb(did, n, dt, a):
    disc_count[0] += 1

# Exact wrapper pattern for on_device_discovered
@_DeviceDiscoveredCCallback
def _disc_trampoline(device_id, name, device_type, address):
    user_disc_cb(
        device_id,
        name.decode("utf-8") if name else "",
        device_type.decode("utf-8") if device_type else "",
        address.decode("utf-8") if address else ""
    )

h1 = _lib.onDeviceDiscovered(ctx, _disc_trampoline)
print(f"Discovered handle: {h1}")
_cb_refs[h1] = _disc_trampoline

# Exact wrapper pattern for on_device_status_changed
@_DeviceStatusChangedCCallback
def _stat_trampoline(device_id, name, online, timestamp_ms):
    pass  # no-op

h2 = _lib.onDeviceStatusChanged(ctx, _stat_trampoline)
print(f"StatusChanged handle: {h2}")
_cb_refs[h2] = _stat_trampoline

# Fire events
print("Firing 15 events...")
for i in range(15):
    _lib.add_device_request_with_args(ctx, f"dev{i}".encode(), b"sensor", f"10.0.0.{i}".encode())

time.sleep(1.0)
print(f"Discovered: {disc_count[0]}")

_lib.offDeviceDiscovered(ctx, 0)
_lib.offDeviceStatusChanged(ctx, 0)
_lib.mylib_shutdown(ctx)
print("DONE — no crash!")
