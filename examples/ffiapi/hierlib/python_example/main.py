"""Python consumer for the hierlib interface-model FFI example.

Exercises the full surface generated from a single main BrokerInterface(API):
library lifecycle (create_context / shutdown), requests (get_value / echo_len /
initialize_request), and an event emitted through the interface facade
(fire_tick -> Tick -> on_tick callback).
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "nimlib", "build")
sys.path.insert(0, BUILD)

import hierlib  # noqa: E402


def main() -> None:
    print("hierlib version:", hierlib.Hierlib.version())

    lib = hierlib.Hierlib()
    r = lib.create_context()
    assert r.is_ok(), ("create_context", r)

    assert lib.initialize_request("cfg").is_ok(), "initialize_request"
    assert int(lib.get_value().value) == 7, "get_value"
    assert int(lib.echo_len("abcd").value) == 4, "echo_len"

    received = []
    handle = lib.on_tick(lambda owner, n: received.append(int(n)))
    assert handle != 0, "on_tick handle"

    assert int(lib.fire_tick(99).value) == 99, "fire_tick"

    deadline = time.time() + 2.0
    while not received and time.time() < deadline:
        time.sleep(0.01)
    assert received == [99], ("event delivery", received)

    lib.off_tick(handle)
    lib.shutdown()
    print("hierlib python example: OK")


if __name__ == "__main__":
    main()
