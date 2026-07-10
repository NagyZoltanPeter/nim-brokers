# A MultiRequestBroker provideIt body that could silently fall through to
# err("") must be a compile error, exactly as for RequestBroker — the
# `providerBody` checker is shared across both macros.
import chronos
import brokers/multi_request_broker

MultiRequestBroker:
  type RejMulti = object
    v*: int

  proc signatureFetch*(n: int): Future[Result[RejMulti, string]] {.async.}

discard RejMulti.provideIt:
  echo "side effect only: ", n
  # void trailing call, no return / result= / Result expr -> must NOT compile
