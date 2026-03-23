#!/usr/bin/env python3
"""Minimal crash repro with faulthandler for native traces."""

import ctypes
import faulthandler
import sys
import time
import os

# Enable faulthandler for better crash diagnostics
faulthandler.enable()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))

# Load library manually to check callback pointer values
lib = ctypes.CDLL(os.path.join(os.path.dirname(__file__), "..", "nimlib", "build", "libmylib.dylib"))

# Setup
lib.mylib_initialize()
lib.mylib_create.restype = ctypes.c_uint32
ctx = lib.mylib_create()
print(f"ctx = {ctx}")
time.sleep(0.2)

# Create request
lib.create_request_request_with_args.argtypes = [ctypes.c_uint32, ctypes.c_char_p]
# Skip restype setup for simplicity — just check if callback works

# Define callback types
DiscCb = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p)
StatusCb = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_char_p, ctypes.c_bool, ctypes.c_int64)

# Setup on/off signatures
lib.onDeviceDiscovered.argtypes = [ctypes.c_uint32, DiscCb]
lib.onDeviceDiscovered.restype = ctypes.c_uint64
lib.offDeviceDiscovered.argtypes = [ctypes.c_uint32, ctypes.c_uint64]
lib.offDeviceDiscovered.restype = None

lib.onDeviceStatusChanged.argtypes = [ctypes.c_uint32, StatusCb]
lib.onDeviceStatusChanged.restype = ctypes.c_uint64
lib.offDeviceStatusChanged.argtypes = [ctypes.c_uint32, ctypes.c_uint64]
lib.offDeviceStatusChanged.restype = None

lib.add_device_request_with_args.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]

# Create callbacks
disc_count = [0]
stat_count = [0]

@DiscCb
def on_disc(did, name, dt, addr):
    disc_count[0] += 1

@StatusCb
def on_stat(did, name, online, ts):
    stat_count[0] += 1

# Store refs
_refs = [on_disc, on_stat]

print(f"disc callback ptr: {ctypes.cast(on_disc, ctypes.c_void_p).value:#x}")
print(f"stat callback ptr: {ctypes.cast(on_stat, ctypes.c_void_p).value:#x}")

# Configure the library
lib.create_request_request_with_args(ctx, b"/tmp/test")
time.sleep(0.1)

# Register DISCOVERED FIRST
print("\nRegistering DeviceDiscovered...")
h1 = lib.onDeviceDiscovered(ctx, on_disc)
print(f"  handle = {h1}")

# Register STATUS CHANGED SECOND
print("Registering DeviceStatusChanged...")
h2 = lib.onDeviceStatusChanged(ctx, on_stat)
print(f"  handle = {h2}")

# Fire events
print("\nFiring 15 add_device calls...")
for i in range(15):
    lib.add_device_request_with_args(ctx, f"dev{i}".encode(), b"sensor", f"10.0.0.{i}".encode())

time.sleep(1.0)
print(f"Discovered: {disc_count[0]}, Status: {stat_count[0]}")

lib.offDeviceDiscovered(ctx, 0)
lib.offDeviceStatusChanged(ctx, 0)

lib.mylib_shutdown.argtypes = [ctypes.c_uint32]
lib.mylib_shutdown(ctx)

print("\nDONE — no crash!")
