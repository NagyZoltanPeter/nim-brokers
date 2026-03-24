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
            print(f"Library context: 0x{lib.ctx:08X}\n")

            print("--- Subscribing to events ---")

            def on_discovered(
                device_id: int, name: str, device_type: str, address: str
            ) -> None:
                nonlocal discovery_count
                discovery_count += 1
                print(
                    f'  >>> DeviceDiscovered #{discovery_count}: '
                    f'id={device_id}  "{name}"  [{device_type}]  {address}'
                )

            def on_status(
                device_id: int, name: str, online: bool, timestamp_ms: int
            ) -> None:
                nonlocal status_count
                status_count += 1
                state = "ONLINE" if online else "OFFLINE"
                print(
                    f'  >>> DeviceStatusChanged #{status_count}: '
                    f'id={device_id}  "{name}"  {state}  (ts={timestamp_ms})'
                )

            def on_status_logger(_: int, name: str, online: bool, __: int) -> None:
                print(f'  >>> [Logger] {name} is now {"UP" if online else "DOWN"}')

            h_disc = lib.on_device_discovered(on_discovered)
            h_status = lib.on_device_status_changed(on_status)
            h_status2 = lib.on_device_status_changed(on_status_logger)

            print(
                f"  Handles: discovered={h_disc}  status={h_status}  status2={h_status2}\n"
            )

            print("--- Configuring library ---")
            initialize_result = lib.initialize_request("/opt/devices.yaml")
            print(
                f"  config={initialize_result.config_path}  "
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
            for name, device_type, address in fleet:
                result = lib.add_device(name, device_type, address)
                ids.append(result.device_id)
                print(f"  + {name} -> id={result.device_id}")

            time.sleep(0.3)
            print()

            print(f"--- Device inventory ({len(ids)} added) ---")
            listed = lib.list_devices()
            print(f"  Count: {len(listed.devices)}")
            for index, device in enumerate(listed.devices):
                state = "online" if device.online else "offline"
                print(
                    f"  [{index}] id={device.device_id:<3}  {device.name:<18}  "
                    f"type={device.device_type:<10}  addr={device.address:<16}  {state}"
                )
            print()

            if len(ids) > 2:
                query_id = ids[2]
                print(f"--- Query device id={query_id} ---")
                device = lib.get_device(query_id)
                print(
                    f'  name="{device.name}"  type="{device.device_type}"  '
                    f'addr="{device.address}"  online={"yes" if device.online else "no"}'
                )
                print()

            print("--- Removing devices ---")
            for index in (0, 3):
                if index >= len(ids):
                    continue
                removed = lib.remove_device(ids[index])
                print(
                    f"  Removed id={ids[index]}  success={'yes' if removed.success else 'no'}"
                )
            time.sleep(0.2)
            print()

            print("--- Removing first status listener (keeping logger) ---")
            lib.off_device_status_changed(h_status)
            print(f"  Removed handle {h_status}\n")

            print("--- Removing one more device (only logger active) ---")
            if len(ids) > 1:
                removed = lib.remove_device(ids[1])
                if removed.success:
                    print(f"  Removed id={ids[1]}")
            time.sleep(0.2)
            print()

            print("--- Remaining devices ---")
            listed = lib.list_devices()
            print(f"  Count: {len(listed.devices)}")
            for device in listed.devices:
                state = "online" if device.online else "offline"
                print(
                    f"  id={device.device_id:<3}  {device.name:<18}  "
                    f"type={device.device_type:<10}  addr={device.address:<16}  {state}"
                )
            print()

            print("--- Unsubscribing all ---")
            lib.off_device_discovered()
            lib.off_device_status_changed()
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
