"""Python consumer for the hierlib interface-model FFI example.

Exercises the full surface generated from a main BrokerInterface(API) plus a
sub-interface (reduced-A): library lifecycle (create_context / shutdown),
requests (get_value / echo_len / initialize_request), a one-way signal
(nudge_signal -> NudgeSignal handler, observed via get_value), an event emitted
through the interface facade (fire_tick -> Tick -> on_tick callback), and a
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

    # One-way signal (fire-and-forget, no response): nudge the value. The handler
    # runs on the processing thread, so the mutation is observable through
    # get_value once delivered — poll for it (like the event below).
    lib.nudge_signal(by=10)
    deadline = time.time() + 2.0
    while int(lib.get_value().value) == 7 and time.time() < deadline:
        time.sleep(0.01)
    assert int(lib.get_value().value) == 17, ("signal delivery", lib.get_value())

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

    # Sub-interface one-way signal: routes to THIS widget instance by its ctx
    # (size 15 -> 20 -> area 400). Poll area for the async one-way delivery.
    widget.resize_signal(delta=5)
    sd = time.time() + 2.0
    while int(widget.area().value) == 225 and time.time() < sd:
        time.sleep(0.01)
    assert int(widget.area().value) == 400, ("widget signal", widget.area())

    # A second widget is independent (own instanceCtx, same library) — the
    # signal above did not touch it.
    with lib.make_widget(2).value as widget2:
        assert int(widget2.area().value) == 4, "widget2.area"

    widget.close()
    # Idempotent + post-release calls fail cleanly (ctx routed but no provider).
    widget.close()
    assert widget.area().is_err(), "area after release must error"

    # A5: a sub-instance the foreign side FORGETS to release. shutdown() must
    # tear the library context down cleanly anyway — the Nim instance lives on
    # the processing thread's heap and is reclaimed when that thread is joined
    # (no FFI-side ownership; GC owns instances). No crash/hang under refc/orc.
    leaked = lib.make_widget(9)
    assert leaked.is_ok() and leaked.value.area().value == 81, "leaked widget"
    # intentionally NOT closed.

    lib.shutdown()
    print("hierlib python example: OK")


if __name__ == "__main__":
    main()
