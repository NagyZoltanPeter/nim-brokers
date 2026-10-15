# EXTAPI native import (K1) short form: a raw pointer argument handed to C is
# only valid for the synchronous `inplace` call — under `workers(n)` the C
# function would run on another thread after a timed-out caller may already
# have freed the memory. registerExtPlugin must reject it at compile time.
import chronos, results
import brokers/[request_broker, ext_plugin]

RequestBroker(
  EXTAPI[rawp], importc = "c_fn", dynlib = "libnothing.so", dispatch = workers(2)
):
  type RawP = object
    v*: int32

  proc signature*(buf: ptr uint8, len: uint32): Future[Result[RawP, string]] {.async.}

registerExtPlugin(rawp)
