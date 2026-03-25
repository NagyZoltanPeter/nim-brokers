#!/usr/bin/env python3
"""Device Monitor — Python wrapper example.

Build from the repository root:
  nimble buildFfiExamplePy

Run from the repository root:
  nimble runFfiExamplePy
"""

from __future__ import annotations

import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "nimlib" / "build"))

from mylib import Mylib, MylibError


def main() -> int:
    print("=== Device Monitor — Python Wrapper Example ===\n")

    discovery_count = 0
    status_count = 0

    try:
        with Mylib() as lib:
            lib.createContext()
            if not lib:
                raise MylibError("createContext() returned success without a context")

            print(f"Library context: 0x{lib.ctx:08X}\n")

            print("--- Subscribing to events ---")

            def on_discovered(
                deviceId: int, name: str, deviceType: str, address: str
            ) -> None:
                nonlocal discovery_count
                discovery_count += 1
                print(
                    f'  >>> DeviceDiscovered #{discovery_count}: '
                    f'id={deviceId}  "{name}"  [{deviceType}]  {address}'
                )

            def on_status(
                deviceId: int, name: str, online: bool, timestampMs: int
            ) -> None:
                nonlocal status_count
                status_count += 1
                state = "ONLINE" if online else "OFFLINE"
                print(
                    f'  >>> DeviceStatusChanged #{status_count}: '
                    f'id={deviceId}  "{name}"  {state}  (ts={timestampMs})'
                )

            def on_status_logger(_: int, name: str, online: bool, __: int) -> None:
                print(f'  >>> [Logger] {name} is now {"UP" if online else "DOWN"}')

            h_disc = lib.onDeviceDiscovered(on_discovered)
            h_status = lib.onDeviceStatusChanged(on_status)
            h_status2 = lib.onDeviceStatusChanged(on_status_logger)

            print(
                f"  Handles: discovered={h_disc}  status={h_status}  status2={h_status2}\n"
            )

            print("--- Configuring library ---")
            initialize_result = lib.initializeRequest("/opt/devices.yaml")
            print(
                f"  config={initialize_result.configPath}  "
                f"initialized={'yes' if initialize_result.initialized else 'no'}\n"
            )

            print("--- Adding devices ---")
            fleet = [
                ("Core-Router", "router", "10.0.0.1"),
                ("Edge-Switch-A", "switch", "10.0.1.1"),
                ("Edge-Switch-B", "switch", "10.0.1.2"),
                ("AP-Floor-3", "ap", "10.0.2.10"),
                ("TempSensor-DC1", "sensor", "10.0.3.50"),
            ]

            ids: list[int] = []
            for name, deviceType, address in fleet:
                result = lib.addDevice(name, deviceType, address)
                ids.append(result.deviceId)
                print(f"  + {name} -> id={result.deviceId}")

            time.sleep(0.3)
            print()

            print(f"--- Device inventory ({len(ids)} added) ---")
            listed = lib.listDevices()
            print(f"  Count: {len(listed.devices)}")
            for index, device in enumerate(listed.devices):
                state = "online" if device.online else "offline"
                print(
                    f"  [{index}] id={device.deviceId:<3}  {device.name:<18}  "
                    f"type={device.deviceType:<10}  addr={device.address:<16}  {state}"
                )
            print()

            if len(ids) > 2:
                queryId = ids[2]
                print(f"--- Query device id={queryId} ---")
                device = lib.getDevice(queryId)
                print(
                    f'  name="{device.name}"  type="{device.deviceType}"  '
                    f'addr="{device.address}"  online={"yes" if device.online else "no"}'
                )
                print()

            print("--- Removing devices ---")
            for index in (0, 3):
                if index >= len(ids):
                    continue
                removed = lib.removeDevice(ids[index])
                print(
                    f"  Removed id={ids[index]}  success={'yes' if removed.success else 'no'}"
                )
            time.sleep(0.2)
            print()

            print("--- Removing first status listener (keeping logger) ---")
            lib.offDeviceStatusChanged(h_status)
            print(f"  Removed handle {h_status}\n")

            print("--- Removing one more device (only logger active) ---")
            if len(ids) > 1:
                removed = lib.removeDevice(ids[1])
                if removed.success:
                    print(f"  Removed id={ids[1]}")
            time.sleep(0.2)
            print()

            print("--- Remaining devices ---")
            listed = lib.listDevices()
            print(f"  Count: {len(listed.devices)}")
            for device in listed.devices:
                state = "online" if device.online else "offline"
                print(
                    f"  id={device.deviceId:<3}  {device.name:<18}  "
                    f"type={device.deviceType:<10}  addr={device.address:<16}  {state}"
                )
            print()

            print("--- Unsubscribing all ---")
            lib.offDeviceDiscovered()
            lib.offDeviceStatusChanged()
            print("  All event listeners removed.\n")

            print(f"  Total discovery events received: {discovery_count}")
            print(f"  Total status events received: {status_count}\n")

            print("--- Shutting down (context manager) ---")

        print("\n=== Python wrapper example complete ===")
        return 0
    except MylibError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
