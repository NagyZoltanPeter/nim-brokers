# EXTAPI: a plugin has at most 64 names (the provided-set bitmask width).
# registerExtPlugin knows the count at compile time and must reject 65 instead
# of failing every call at runtime with "plugin not registered".
import std/macros
import chronos, results
import brokers/[signal_broker, ext_plugin]

macro manySignals(n: static int): untyped =
  var src = ""
  for i in 0 ..< n:
    src.add(
      "SignalBroker(EXTAPI[big]):\n  type BigSig" & $i & " = object\n    v*: int32\n"
    )
  parseStmt(src)

manySignals(65)
registerExtPlugin(big)
