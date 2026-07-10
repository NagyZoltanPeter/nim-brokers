# A provideIt body ending in an `if` without `else` (only one path returns)
# must be a compile error — the missing branch would silently answer err("").
import chronos
import brokers/request_broker

RequestBroker(sync):
  proc rejPartialIf(input: string, len: int): Result[seq[byte], string]

discard RejPartialIf.provideIt:
  if len > 0:
    return ok(newSeq[byte](len))
  # missing else -> must NOT compile
