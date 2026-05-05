#!/usr/bin/env python3
"""Example Python consumer of the CBOR-mode FFI library.

Mirrors examples/ffiapi_cbor/cpp_example/src/main.cpp: lifecycle, a
zero-arg request, an arg-based request, an event subscribe with a typed
handler, a Nim-side emit through the fire_device request, and an
unsubscribe.

Run via the bundled nimble task:

    nimble runFfiCborExamplePy

which builds the shared library + generated mylibcbor.py with
``-d:BrokerFfiApiGenPy`` and invokes this script through the project's
configured Python interpreter.
"""

from __future__ import annotations

import os
import sys
import threading
import time

# Find the generated wrapper next to the shared library.
HERE = os.path.dirname(os.path.abspath(__file__))
NIMLIB_BUILD = os.path.normpath(os.path.join(HERE, "..", "nimlib", "build"))
sys.path.insert(0, NIMLIB_BUILD)

import mylibcbor  # noqa: E402  — sys.path tweak above must run first


def main() -> int:
    with mylibcbor.Lib() as lib:
        # ----- Zero-arg request -----
        status = lib.get_status()
        if status.is_err():
            print(f"get_status failed: {status.error}", file=sys.stderr)
            return 2
        s = status.value
        print(
            f"[get_status] online={s.online} counter={s.counter} "
            f"label={s.label!r}"
        )

        # ----- Arg-based request -----
        sum_result = lib.add_numbers(40, 2)
        if sum_result.is_err():
            print(f"add_numbers failed: {sum_result.error}", file=sys.stderr)
            return 3
        print(f"[add_numbers] 40 + 2 = {sum_result.value.sum}")

        # ----- Event subscribe + emit + delivery -----
        delivered = threading.Event()
        captured: dict = {}

        def on_device_updated(evt: mylibcbor.DeviceUpdated) -> None:
            captured["deviceId"] = evt.deviceId
            captured["online"] = evt.online
            delivered.set()

        handle = lib.subscribe_device_updated(on_device_updated)
        if handle == 0:
            print("subscribe failed", file=sys.stderr)
            return 4
        print(f"[subscribe] device_updated handle={handle}")

        fired = lib.fire_device(0xC0FFEE, True)
        if fired.is_err():
            print(f"fire_device failed: {fired.error}", file=sys.stderr)
            return 5

        if not delivered.wait(timeout=0.5):
            print("event delivery timed out", file=sys.stderr)
            return 6
        print(
            f"[delivered] deviceId=0x{captured['deviceId']:x} "
            f"online={captured['online']}"
        )
        if captured["deviceId"] != 0xC0FFEE or captured["online"] is not True:
            print("delivered event did not match", file=sys.stderr)
            return 7

        unsub = lib.unsubscribe_device_updated(handle)
        print(f"[unsubscribe] status={unsub}")
        if unsub != 0:
            return 8

    return 0


if __name__ == "__main__":
    sys.exit(main())
