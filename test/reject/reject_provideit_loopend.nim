# A provideIt body ending in a loop without any prior terminal statement must
# be a compile error — the provider would otherwise silently answer err("").
import chronos
import brokers/request_broker

RequestBroker(sync):
  proc rejLoopEnd(input: string, len: int): Result[seq[byte], string]

discard RejLoopEnd.provideIt:
  var acc: seq[byte]
  for i in 0 ..< len:
    acc.add(byte(input[i]))
  # forgot `ok(acc)` -> must NOT compile
