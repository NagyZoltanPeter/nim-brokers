# A provideIt body whose trailing statement is a void call (here: echo) must
# be a compile error — the `result = <expr>` pin forces the type checker to
# reject it instead of letting the provider silently answer err("").
import chronos
import brokers/request_broker

RequestBroker(sync):
  proc rejVoidTrailing(input: string, len: int): Result[seq[byte], string]

discard RejVoidTrailing.provideIt:
  echo "side effect only: ", input, " ", len
  # void trailing call -> must NOT compile
