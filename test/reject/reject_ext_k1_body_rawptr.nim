# EXTAPI native import (K1) body form: raw pointer arguments in the broker
# signature are as unsafe outside `inplace` as in the short form (the call runs
# on a worker after a timed-out caller may have freed the memory). Rejected at
# compile time like the short form.
import chronos, results
import brokers/[request_broker, ext_plugin]

RequestBroker(EXTAPI[rawb], dynlib = "libnothing.so", dispatch = workers(2)):
  type RawB = object
    v*: int32

  proc c_fn(buf: ptr uint8, len: uint32): int32 {.importc, cdecl.}

  proc signature*(buf: ptr uint8, len: uint32): Future[Result[RawB, string]] {.async.} =
    return ok(RawB(v: c_fn(buf, len)))

registerExtPlugin(rawb)
