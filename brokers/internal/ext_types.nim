## EXTAPI enums shared by the macro layer (ext_brokers, always imported with
## --threads:on) and the runtime (ext_runtime, -d:BrokerFfiApi only). Kept
## dependency-free so plain MT builds do not pull the EXTAPI runtime in.

type
  ExtDispatch* = enum
    edBridge
    edWorkers
    edInplace

  ExtNameKind* = enum
    enkRequest
    enkSignal
    enkEvent
