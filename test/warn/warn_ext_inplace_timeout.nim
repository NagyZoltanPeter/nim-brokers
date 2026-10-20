# EXTAPI: an `inplace` name runs synchronously on the caller's thread, so
# `requestTimeoutMs` has no effect on it. This compiles, with a warning.
import chronos, results
import brokers/[request_broker, ext_plugin]

RequestBroker(EXTAPI[warnp], dispatch = inplace, requestTimeoutMs = 500):
  type WarnP = object
    v*: int32

  proc signature*(x: int32): Future[Result[WarnP, string]] {.async.}

registerExtPlugin(warnp)
