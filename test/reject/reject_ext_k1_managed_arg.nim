# EXTAPI native import (K1) short form: a `string` argument would be handed to
# the `cdecl` C prototype as a Nim string (refc / ORC layouts differ, never a
# C `char*`). It must be rejected at compile time (use `cstring` or the body
# form).
import chronos, results
import brokers/[request_broker, ext_plugin]

RequestBroker(
  EXTAPI[k1arg], importc = "c_fn", dynlib = "libnothing.so", dispatch = inplace
):
  type K1Arg = object
    v*: int32

  proc signature*(name: string): Future[Result[K1Arg, string]] {.async.}

registerExtPlugin(k1arg)
