# EXTAPI native import (K1) short form: the single response field is the C
# return value, so it must be a C ABI type — a `seq[byte]` return is rejected
# at compile time (use the body form).
import chronos, results
import brokers/[request_broker, ext_plugin]

RequestBroker(
  EXTAPI[k1ret], importc = "c_fn", dynlib = "libnothing.so", dispatch = inplace
):
  type K1Ret = object
    data*: seq[byte]

  proc signature*(x: int32): Future[Result[K1Ret, string]] {.async.}

registerExtPlugin(k1ret)
