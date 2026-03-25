# torpedolib

Home of the Nim shared library backend for Torpedo Duel.

Implemented in [torpedolib.nim](torpedolib.nim).

The backend currently provides:

- one independent captain runtime per library context
- deterministic fleet placement from a seed
- simple AI target selection (`hunt`, `random`, `sweep`)
- request brokers for initialization, fleet placement, shot planning, shot
  resolution, and public board queries
- event brokers for remarks, board changes, shot results, and match end

Architecture details remain documented in [../DESIGN.md](../DESIGN.md).