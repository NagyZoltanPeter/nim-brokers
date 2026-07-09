#!/usr/bin/env python3
"""Device Monitor — Python wrapper example.

Demonstrates the generated Python wrapper API on the mylib library:

    Lib lifecycle:   Mylib() / create_context() / shutdown() / context manager
    Requests:        each returns Result[<TypeName>] — use .is_ok() / .value / .error
    Events:          on_<name>(callback) -> handle, off_<name>(handle = 0)
                     callback(lib, *unpacked_payload_fields)
    Enums:           Priority.pLow / DeviceStatus.dsOnline (Nim names)

The same shape works for native- and CBOR-mode builds of the library.
"""

import asyncio
import os
import sys
import time
from pathlib import Path

# MYLIB_BUILD_DIR (default `build`) names the subdirectory under
# `nimlib/` that holds the FFI library + generated Python wrapper. The
# default matches the `nimble buildFfiExample` output path.
ROOT = Path(__file__).resolve().parents[1]
_BUILD_DIR = os.environ.get("MYLIB_BUILD_DIR", "build")
sys.path.insert(0, str(ROOT / "nimlib" / _BUILD_DIR))

from mylib import ASYNC_QUEUE_DEPTH, AddDeviceSpec, Mylib  # noqa: E402


_EXPECTED_VERSION = "1.0.0"


def main() -> int:
    print("=== Device Monitor — Python Wrapper Example ===\n")

    actual_version = Mylib.version()
    print(f"mylib version: {actual_version}")
    assert actual_version == _EXPECTED_VERSION, (
        f"Mylib.version() mismatch: got {actual_version!r}, "
        f"expected {_EXPECTED_VERSION!r}"
    )

    discovery_count = 0
    status_count = 0
    alert_count = 0
    batch_count = 0

    with Mylib() as lib:
        init = lib.create_context()
        if not init.is_ok():
            print(f"FATAL: create_context: {init.error}", file=sys.stderr)
            return 1
        print(f"Library context: 0x{lib.ctx:08X}\n")

        print("--- Subscribing to events ---")

        def on_discovered(_owner, deviceId, name, deviceType, address):
            nonlocal discovery_count
            discovery_count += 1
            print(
                f'  >>> DeviceDiscovered #{discovery_count}: '
                f'id={deviceId} "{name}" [{deviceType}] {address}'
            )

        def on_status(_owner, deviceId, name, online, timestampMs):
            nonlocal status_count
            status_count += 1
            state = "ONLINE" if online else "OFFLINE"
            print(
                f'  >>> DeviceStatusChanged #{status_count}: '
                f'id={deviceId} "{name}" {state} (ts={timestampMs})'
            )

        def on_status_logger(_owner, _deviceId, name, online, _ts):
            print(f"  >>> [Logger] {name} is now {'UP' if online else 'DOWN'}")

        def on_alert(_owner, sensorId, deviceId, status, timestampMs):
            nonlocal alert_count
            alert_count += 1
            print(
                f"  >>> SensorAlert: sensorId={sensorId} deviceId={deviceId} "
                f"status={int(status)} ts={timestampMs}"
            )

        def on_batch(_owner, labels, deviceIds, capabilities):
            nonlocal batch_count
            batch_count += 1
            print(
                f"  >>> DeviceBatch #{batch_count}: {len(labels)} devices "
                f"labels={list(labels)} ids={list(deviceIds)} "
                f"capabilities={list(capabilities)}"
            )

        h_disc = lib.on_device_discovered(on_discovered)
        h_status = lib.on_device_status_changed(on_status)
        h_status2 = lib.on_device_status_changed(on_status_logger)
        h_alert = lib.on_sensor_alert(on_alert)
        h_batch = lib.on_device_batch(on_batch)
        print(
            f"  Handles: disc={h_disc} status={h_status} status2={h_status2} "
            f"alert={h_alert} batch={h_batch}\n"
        )

        print("--- Configuring library ---")
        ir = lib.initialize_request("/opt/devices.yaml")
        assert ir.is_ok(), ir.error
        print(
            f"  config={ir.value.configPath}  "
            f"initialized={'yes' if ir.value.initialized else 'no'}\n"
        )

        print("--- Adding devices ---")
        fleet = [
            AddDeviceSpec("Core-Router", "router", "10.0.0.1"),
            AddDeviceSpec("Edge-Switch-A", "switch", "10.0.1.1"),
            AddDeviceSpec("Edge-Switch-B", "switch", "10.0.1.2"),
            AddDeviceSpec("AP-Floor-3", "ap", "10.0.2.10"),
            AddDeviceSpec("TempSensor-DC1", "sensor", "10.0.3.50"),
        ]
        ar = lib.add_device(fleet)
        assert ar.is_ok(), ar.error
        ids = [d.deviceId for d in ar.value.devices]
        for d in ar.value.devices:
            print(f"  + {d.name} -> id={d.deviceId}")
        time.sleep(0.3)
        print()

        print(f"--- Device inventory ({len(ids)} added) ---")
        listed = lib.list_devices()
        assert listed.is_ok(), listed.error
        print(f"  Count: {len(listed.value.devices)}")
        for i, d in enumerate(listed.value.devices):
            state = "online" if d.online else "offline"
            print(
                f"  [{i}] id={d.deviceId:<3} {d.name:<18} "
                f"type={d.deviceType:<10} addr={d.address:<16} {state}"
            )
        print()

        # --- Async device queries (asyncio) ---------------------------
        # Each get_device_async returns a Result[GetDevice] resolved on the
        # library's delivery thread; asyncio.gather pipelines them.
        # Backpressure is transparent: an internal Semaphore(ASYNC_QUEUE_DEPTH)
        # makes calls past the window AWAIT a free slot instead of erroring —
        # gather over any number of calls just works (proved by the burst
        # below). `timeout` is asyncio-style seconds (None = lib default);
        # a library-side timeout raises TimeoutError, like asyncio.wait_for.
        print("--- Async device queries (asyncio) ---")
        print(f"  async window = {ASYNC_QUEUE_DEPTH} in-flight")

        async def _run_async() -> None:
            results = await asyncio.gather(
                *(lib.get_device_async(q, timeout=2.0) for q in ids)
            )
            for q, res in zip(ids, results):
                if res.is_ok():
                    state = "online" if res.value.online else "offline"
                    print(f'  [async] id={q} -> "{res.value.name}" ({state})')
                else:
                    print(f"  [async] id={q} -> error: {res.error}")

            # Burst PAST the window: 3x depth concurrent awaits. Without the
            # internal semaphore this would raise AsyncAgainError; with it the
            # excess calls simply wait for slots.
            burst = ASYNC_QUEUE_DEPTH * 3
            burst_ids = [ids[i % len(ids)] for i in range(burst)]
            burst_res = await asyncio.gather(
                *(lib.get_device_async(q) for q in burst_ids)
            )
            ok = sum(1 for r in burst_res if r.is_ok())
            print(f"  burst: {ok}/{burst} ok (window={ASYNC_QUEUE_DEPTH}, no EAGAIN)")

        asyncio.run(_run_async())
        print("  All async queries completed.")
        print()

        if len(ids) > 2:
            qid = ids[2]
            print(f"--- Query device id={qid} ---")
            r = lib.get_device(qid)
            assert r.is_ok(), r.error
            d = r.value
            print(
                f'  name="{d.name}" type="{d.deviceType}" addr="{d.address}" '
                f'online={"yes" if d.online else "no"}\n'
            )

        if ids:
            qid = ids[0]
            print(f"--- GetSensorData (seq[byte], DeviceStatus, SensorId) id={qid} ---")
            r = lib.get_sensor_data(qid)
            assert r.is_ok(), r.error
            s = r.value
            print(
                f"  sensorId={s.sensorId} status={s.status.name} "
                f"rawData[{len(s.rawData)}]: {list(s.rawData[:4])}\n"
            )

            print(f"--- GetDeviceTags (seq[string]) id={qid} ---")
            r = lib.get_device_tags(qid)
            assert r.is_ok(), r.error
            print(f"  tags={r.value.tags}\n")

            print(f"--- GetDeviceCapabilities (array[4,int32], Timestamp) id={qid} ---")
            r = lib.get_device_capabilities(qid)
            assert r.is_ok(), r.error
            print(f"  capturedAt={r.value.capturedAt} capabilities={r.value.capabilities}\n")
            time.sleep(0.1)

        print("--- Removing devices ---")
        for idx in (0, 3):
            if idx >= len(ids):
                continue
            r = lib.remove_device(ids[idx])
            assert r.is_ok(), r.error
            print(
                f"  Removed id={ids[idx]} success={'yes' if r.value.success else 'no'}"
            )
        time.sleep(0.2)
        print()

        print("--- Removing first status listener (keeping logger) ---")
        lib.off_device_status_changed(h_status)
        print(f"  Removed handle {h_status}\n")

        print("--- Removing one more device (only logger active) ---")
        if len(ids) > 1:
            r = lib.remove_device(ids[1])
            if r.is_ok() and r.value.success:
                print(f"  Removed id={ids[1]}")
        time.sleep(0.2)
        print()

        print("--- Remaining devices ---")
        listed = lib.list_devices()
        if listed.is_ok():
            print(f"  Count: {len(listed.value.devices)}")
            for d in listed.value.devices:
                state = "online" if d.online else "offline"
                print(
                    f"  id={d.deviceId:<3} {d.name:<18} "
                    f"type={d.deviceType:<10} addr={d.address:<16} {state}"
                )
        print()

        print("--- Firing IngestReading signals (one-way, slot-free) ---")
        lib.ingest_reading(42, 3.5)
        lib.ingest_reading(42, 7.25)
        time.sleep(0.05)  # let the async handler run on the processing thread
        rb = lib.last_reading()
        if not rb.is_ok():
            raise SystemExit(f"FATAL: last_reading: {rb.error()}")
        print(
            f"  LastReading: deviceId={rb.value.deviceId} "
            f"value={rb.value.value} count={rb.value.count}"
        )
        assert (
            rb.value.count == 2
            and rb.value.deviceId == 42
            and rb.value.value == 7.25
        ), "signal round-trip mismatch"
        print("  Signal round-trip verified.\n")

        print("--- Unsubscribing all ---")
        lib.off_device_discovered()
        lib.off_device_status_changed()
        lib.off_device_batch(h_batch)
        lib.off_sensor_alert(h_alert)
        print("  All event listeners removed.\n")
        print(f"  Total discovery events received: {discovery_count}")
        print(f"  Total status events received: {status_count}")
        print(f"  Total sensor alert events received: {alert_count}")
        print(f"  Total device batch events received: {batch_count}\n")

        print("--- Shutting down (context manager) ---")

    print("\n=== Python wrapper example complete ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
