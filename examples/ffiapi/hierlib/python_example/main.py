"""Python consumer for the hierlib interface-model FFI example.

Exercises the full surface generated from a main BrokerInterface(API) plus a
sub-interface (reduced-A): library lifecycle (create_context / shutdown),
requests (get_value / echo_len / initialize_request), an event emitted through
the interface facade (fire_tick -> Tick -> on_tick callback), and a
create-instance request (make_widget -> Widget) whose typed sub-wrapper routes
its own calls (area / scale) and is released via close().
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

    # reduced-A: create a sub-interface instance, call its own methods (which
    # route to the same processing thread via shared classCtx), then release it.
    wr = lib.make_widget(5)
    assert wr.is_ok(), ("make_widget", wr)
    widget = wr.value
    assert widget.ctx != 0, "widget ctx"
    assert int(widget.area().value) == 25, ("widget.area", widget.area())
    assert int(widget.scale(3).value) == 15, "widget.scale"
    assert int(widget.area().value) == 225, "widget.area after scale"

    # A second widget is independent (own instanceCtx, same library).
    with lib.make_widget(2).value as widget2:
        assert int(widget2.area().value) == 4, "widget2.area"

    widget.close()
    # Idempotent + post-release calls fail cleanly (ctx routed but no provider).
    widget.close()
    assert widget.area().is_err(), "area after release must error"

    lib.shutdown()
    print("hierlib python example: OK")


if __name__ == "__main__":
    main()
