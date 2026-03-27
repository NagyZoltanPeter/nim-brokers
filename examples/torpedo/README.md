# Torpedo Duel

Torpedo Duel is a richer Broker FFI API example for `nim-brokers`.

It demonstrates one Nim shared library hosting two independent library
contexts that are linked together at runtime. After setup, the two captains
play each other directly through broker events while a foreign Python app only
observes and renders the match.

## What It Demonstrates

- one shared library with multiple active contexts
- request brokers used for setup, linking, start, and public state queries
- an API event broker used both as the internal duel protocol and as the
  foreign observable event stream
- hidden authoritative game state staying inside Nim
- a foreign app acting as bootstrapper and spectator instead of the game engine
- deterministic runs through explicit seeds
- human-followable pacing controlled from the Nim backend

## Current Runtime Model

1. Python creates two `torpedolib` contexts.
2. Each context is initialized and auto-places its own fleet.
3. Python links each context to the other by passing the raw `BrokerContext`
   handle through `LinkOpponentRequest`.
4. Python subscribes to the exported events from both contexts.
5. Python starts one side with `StartGameRequest`.
6. After that, the captains exchange volleys autonomously inside the Nim
   library until one side loses.

## Build And Run

From the repository root:

```text
nimble buildTorpedoExamplePy
nimble runTorpedoExamplePy
```

For a faster run during development:

```text
python3 examples/torpedo/python_example/main.py --fast
```

You can also choose the opening player:

```text
python3 examples/torpedo/python_example/main.py --starter blue
```

## Layout

- `nimlib/` — Nim shared library backend and generated wrapper output
- `python_example/` — Python text UI observer and bootstrap app
- `cpp_example/` — reserved for a future C++ observer example
- `DESIGN.md` — detailed architecture and control-flow notes

See `DESIGN.md` for the full interaction model and API sketch.