#!/usr/bin/env python3
"""Test script for Python event callbacks — debugging rapid-fire SIGSEGV."""

import sys
import time
import os

# Add build dir to path so we can import mylib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "nimlib", "build"))

from mylib import Mylib, MylibError

def test_basic_requests():
    """Test that basic requests work."""
    print("=== Basic request test ===")
    with Mylib() as lib:
        result = lib.create_request("/tmp/test")
        print(f"  create_request: config_path={result.config_path}, initialized={result.initialized}")

        result = lib.add_device("sensor1", "temperature", "192.168.1.10")
        print(f"  add_device: device_id={result.device_id}, success={result.success}")

        result = lib.list_devices()
        print(f"  list_devices: {len(result.devices)} device(s)")
        for d in result.devices:
            print(f"    - {d.name} ({d.device_type}) @ {d.address}")

    print("  PASSED\n")

def test_single_event():
    """Test that a single event callback works."""
    print("=== Single event test ===")
    events_received = []

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def on_discovered(device_id, name, device_type, address):
            events_received.append((device_id, name, device_type, address))
            print(f"  [EVENT] DeviceDiscovered: id={device_id}, name={name}")

        handle = lib.on_device_discovered(on_discovered)
        print(f"  Registered listener, handle={handle}")

        # Add one device — should trigger event
        lib.add_device("sensor1", "temperature", "192.168.1.10")
        time.sleep(0.2)  # Give delivery thread time

        print(f"  Events received: {len(events_received)}")
        lib.off_device_discovered(handle)

    print("  PASSED\n")

def test_events_with_sleep():
    """Test multiple events with sleeps between calls."""
    print("=== Events with sleep test ===")
    events_received = []

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def on_discovered(device_id, name, device_type, address):
            events_received.append((device_id, name, device_type, address))
            print(f"  [EVENT] DeviceDiscovered: id={device_id}, name={name}")

        handle = lib.on_device_discovered(on_discovered)

        for i in range(5):
            lib.add_device(f"sensor{i}", "temperature", f"192.168.1.{10+i}")
            time.sleep(0.1)

        time.sleep(0.3)  # Final wait for delivery
        print(f"  Events received: {len(events_received)}")
        lib.off_device_discovered(handle)

    print("  PASSED\n")

def test_rapid_fire_events():
    """Test rapid-fire events WITHOUT sleeps — this is the crash scenario."""
    print("=== Rapid-fire event test ===")
    events_received = []

    with Mylib() as lib:
        lib.create_request("/tmp/test")

        def on_discovered(device_id, name, device_type, address):
            events_received.append((device_id, name, device_type, address))

        handle = lib.on_device_discovered(on_discovered)
        print(f"  Registered listener, handle={handle}")

        # Rapid-fire add_device calls — no sleep between them
        print("  Firing 10 rapid add_device calls...")
        for i in range(10):
            lib.add_device(f"sensor{i}", "temperature", f"192.168.1.{10+i}")

        time.sleep(0.5)  # Wait for all events to be delivered
        print(f"  Events received: {len(events_received)}")
        lib.off_device_discovered(handle)

    print("  PASSED\n")


if __name__ == "__main__":
    print(f"Python {sys.version}\n")

    test_basic_requests()
    test_single_event()
    test_events_with_sleep()

    print("--- Now testing rapid-fire (crash scenario) ---\n")
    test_rapid_fire_events()

    print("ALL TESTS PASSED")
