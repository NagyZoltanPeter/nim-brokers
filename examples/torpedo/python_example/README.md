# Python TUI

Home of the first foreign consumer for the Torpedo Duel example.

Implemented in [main.py](main.py).

The Python app:

- create two independent `torpedolib` contexts
- subscribe to both event streams
- initialize and auto-place both fleets
- link each context to the other
- start the duel from one selected side
- observe `VolleyEvent` plus the higher-level status events
- render a text UI with boards and replay log

Run it from the repository root with:

```text
nimble runTorpedoExamplePy
```

For a faster development loop:

```text
python3 examples/torpedo/python_example/main.py --fast
```

You can choose the starting side with:

```text
python3 examples/torpedo/python_example/main.py --starter blue
```

Implementation details and runtime expectations are described in
[../DESIGN.md](../DESIGN.md).