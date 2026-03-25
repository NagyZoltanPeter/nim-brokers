# torpedolib

Home of the Nim shared library backend for Torpedo Duel.

Implemented in [torpedolib.nim](torpedolib.nim).

The backend currently provides:

- one independent captain runtime per library context
- deterministic fleet placement from a seed
- simple AI target selection (`hunt`, `random`, `sweep`)
- backend pacing through `turnDelayMs`
- request brokers for initialization, fleet placement, opponent linking, duel
  start, shutdown, and public board queries
- event brokers for remarks, board changes, shot results, match end, and the
  shared `VolleyEvent` protocol
- native peer listeners that let two contexts exchange volleys autonomously

In the current design, Python does not relay turns. It only bootstraps the two
contexts and observes the match while the captains play each other inside Nim.

Architecture details remain documented in [../DESIGN.md](../DESIGN.md).