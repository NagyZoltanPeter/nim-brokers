## API FFI Mode (residual)
## -----------------------
## After Round 2 Part E (see `doc/CBOR_Refactoring_Round2.md`), the FFI
## strategy is no longer a runtime / compile-time choice — CBOR is the
## only supported transport. This module only carries the hard-error
## guard against `-d:BrokerFfiApiNative` so a stale build script cannot
## silently produce the wrong artifact.

when defined(BrokerFfiApiNative):
  {.
    fatal:
      "BrokerFfiApiNative was retired — the native FFI codegen surface no " &
      "longer exists. See doc/CBOR_Refactoring.md. Pass `-d:BrokerFfiApi` " &
      "(or, for one more release, `-d:BrokerFfiApiCBOR`) instead."
  .}
