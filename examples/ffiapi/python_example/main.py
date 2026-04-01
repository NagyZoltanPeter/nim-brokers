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

from mylib import AddDeviceSpec, DeviceStatus, Mylib, MylibError


def main() -> int:
    print("=== Device Monitor — Python Wrapper Example ===\n")

    discovery_count = 0
    status_count = 0
    batch_count = 0

    try:
        with Mylib() as lib:
            lib.createContext()
            if not lib:
                raise MylibError("createContext() returned success without a context")

            print(f"Library context: 0x{lib.ctx:08X}\n")

            print("--- Subscribing to events ---")

            def on_discovered(
                owner: Mylib,
                deviceId: int,
                name: str,
                deviceType: str,
                address: str,
            ) -> None:
                nonlocal discovery_count
                discovery_count += 1
                print(
                    f'  >>> DeviceDiscovered #{discovery_count}: '
                    f'ctx=0x{owner.ctx:08X}  id={deviceId}  "{name}"  [{deviceType}]  {address}'
                )

            def on_status(
                owner: Mylib,
                deviceId: int,
                name: str,
                online: bool,
                timestampMs: int,
            ) -> None:
                nonlocal status_count
                status_count += 1
                state = "ONLINE" if online else "OFFLINE"
                print(
                    f'  >>> DeviceStatusChanged #{status_count}: '
                    f'ctx=0x{owner.ctx:08X}  id={deviceId}  "{name}"  {state}  (ts={timestampMs})'
                )

            def on_status_logger(
                owner: Mylib, _: int, name: str, online: bool, __: int
            ) -> None:
                _ = owner
                print(f'  >>> [Logger] {name} is now {"UP" if online else "DOWN"}')

            alert_count = 0

            def on_batch(
                owner: Mylib,
                labels: list[str],
                device_ids: list[int],
                capabilities: list[int],
            ) -> None:
                nonlocal batch_count
                batch_count += 1
                print(
                    f"  >>> DeviceBatch #{batch_count}: "
                    f"ctx=0x{owner.ctx:08X}  count={len(labels)}"
                    f"  labels={labels}"
                    f"  ids={device_ids}"
                    f"  caps={capabilities}"
                )

            def on_alert(
                owner: Mylib,
                sensorId: int,
                deviceId: int,
                status: DeviceStatus,
                timestampMs: int,
            ) -> None:
                nonlocal alert_count
                alert_count += 1
                print(
                    f"  >>> SensorAlert #{alert_count}: "
                    f"sensorId={sensorId}  deviceId={deviceId}  status={status.name}  ts={timestampMs}"
                )

            h_disc = lib.onDeviceDiscovered(on_discovered)
            h_status = lib.onDeviceStatusChanged(on_status)
            h_status2 = lib.onDeviceStatusChanged(on_status_logger)
            h_alert = lib.onSensorAlert(on_alert)
            h_batch = lib.onDeviceBatch(on_batch)

            print(
                f"  Handles: discovered={h_disc}  status={h_status}"
                f"  status2={h_status2}  alert={h_alert}  batch={h_batch}\n"
            )

            print("--- Configuring library ---")
            initialize_result = lib.initializeRequest("/opt/devices.yaml")
            print(
                f"  config={initialize_result.configPath}  "
                f"initialized={'yes' if initialize_result.initialized else 'no'}\n"
            )

            print("--- Adding devices ---")
            fleet = [
                AddDeviceSpec("Core-Router", "router", "10.0.0.1"),
                AddDeviceSpec("Edge-Switch-A", "switch", "10.0.1.1"),
                AddDeviceSpec("Edge-Switch-B", "switch", "10.0.1.2"),
                AddDeviceSpec("AP-Floor-3", "ap", "10.0.2.10"),
                AddDeviceSpec("TempSensor-DC1", "sensor", "10.0.3.50"),
            ]

            added = lib.addDevice(fleet)
            ids = [device.deviceId for device in added.devices]
            for device in added.devices:
                print(f"  + {device.name} -> id={device.deviceId}")

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

            if ids:
                qid = ids[0]

                print(f"--- GetSensorData (seq[byte], DeviceStatus enum, SensorId distinct) id={qid} ---")
                sensor = lib.getSensorData(qid)
                print(
                    f"  sensorId={sensor.sensorId}  status={sensor.status.name}  "
                    f"rawData[{len(sensor.rawData)}]: {list(sensor.rawData[:4])}"
                )
                print()

                print(f"--- GetDeviceTags (seq[string]) id={qid} ---")
                tags = lib.getDeviceTags(qid)
                print(f"  tags={tags.tags}")
                print()

                print(f"--- GetDeviceCapabilities (array[4,int32], Timestamp distinct) id={qid} ---")
                caps = lib.getDeviceCapabilities(qid)
                print(
                    f"  capturedAt={caps.capturedAt}  capabilities={caps.capabilities}"
                )
                print()

                time.sleep(0.1)

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
            lib.offDeviceBatch(h_batch)
            print("  All event listeners removed.\n")

            print(f"  Total discovery events received: {discovery_count}")
            print(f"  Total status events received: {status_count}")
            print(f"  Total sensor alert events received: {alert_count}")
            print(f"  Total device batch events received: {batch_count}\n")

            print("--- Shutting down (context manager) ---")

        print("\n=== Python wrapper example complete ===")
        return 0
    except MylibError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
