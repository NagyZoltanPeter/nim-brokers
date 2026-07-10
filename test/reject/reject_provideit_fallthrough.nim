# A provideIt body ending in a definitely-void statement (here: discard) must
# be a compile error — the provider would otherwise silently answer err("").
import chronos
import brokers/request_broker

RequestBroker(sync):
  proc rejFallthrough(input: string, len: int): Result[seq[byte], string]

discard RejFallthrough.provideIt:
  discard input
  # no return / result= / trailing expression -> must NOT compile
