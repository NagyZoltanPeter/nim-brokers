# Python TUI

Home of the first foreign consumer for the Torpedo Duel example.

Implemented in [main.py](main.py).

The Python app:

- create two independent `torpedolib` contexts
- subscribe to both event streams
- coordinate the turn loop between the two contexts
- inject pacing delays for a spectator-friendly match
- render a text UI with boards and replay log

Run it from the repository root with:

```text
nimble runTorpedoExamplePy
```

For a faster development loop:

```text
python3 examples/torpedo/python_example/main.py --fast
```

Implementation details and runtime expectations are described in
[../DESIGN.md](../DESIGN.md).