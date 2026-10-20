# EXTAPI: native C imports (`dynlib` without `importLib`) serve requests only;
# an event or signal cannot be imported from a plain C library. Rejected with
# a clear message instead of broken trampoline code.
import chronos, results
import brokers/[event_broker, ext_plugin]

EventBroker(EXTAPI[evd], dynlib = "libnothing.so"):
  type EvD = object
    v*: int32

registerExtPlugin(evd)
