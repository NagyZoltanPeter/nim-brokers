## API FFI Mode
## ------------
## Compile-time resolution of the FFI surface generation strategy.
##
## Two strategies coexist:
##
## - `mfNative` — original per-type C exports with native Nim↔C type mapping.
##   This is what every existing FFI consumer uses today.
##
## - `mfCbor` — collapsed C ABI (one sync gate, one event subscribe pair,
##   alloc/dealloc, lifecycle, discovery) where every payload is CBOR-encoded.
##   Generated language wrappers (C++/Python/Rust) hide encode/decode entirely.
##
## Selection precedence (highest first):
##   1. `-d:BrokerFfiApiNative`  forces `mfNative`.
##   2. `-d:BrokerFfiApiCBOR`    forces `mfCbor`.
##   3. `ffiMode:` field on `registerBrokerLibrary`.
##   4. Default: `mfCbor` (the new strategy is the documented default).
##
## Setting both `-d:BrokerFfiApiNative` and `-d:BrokerFfiApiCBOR` is a fatal
## compile-time error.
##
## The plain `-d:BrokerFfiApi` flag still gates whether any FFI codegen runs at
## all; without it `registerBrokerLibrary` is a no-op (existing behaviour).

{.push raises: [].}

import std/[macros, strutils]

type BrokerFfiMode* = enum
  mfNative ## Native per-type C exports (original strategy).
  mfCbor ## CBOR-encoded buffer ABI (new strategy).

const
  brokerFfiApiCborForced* = defined(BrokerFfiApiCBOR)
  brokerFfiApiNativeForced* = defined(BrokerFfiApiNative)

when brokerFfiApiCborForced and brokerFfiApiNativeForced:
  {.
    fatal:
      "BrokerFfiApiCBOR and BrokerFfiApiNative are mutually exclusive. " &
      "Pick one (or neither and let `ffiMode:` decide)."
  .}

var gApiResolvedFfiMode* {.compileTime.}: BrokerFfiMode = mfCbor
  ## The resolved mode for the current library, set during
  ## `registerBrokerLibrary` expansion. Read by codegen modules to choose
  ## which surface to emit. Defaults to `mfCbor`; overwritten by
  ## `resolveFfiMode` once the library config has been parsed.

var gApiResolvedFfiModeSet* {.compileTime.}: bool = false
  ## Sentinel: has `resolveFfiMode` been called for the current library?

proc parseFfiModeLiteral*(s: string): BrokerFfiMode {.compileTime.} =
  ## Map an `ffiMode:` field value (string literal) to `BrokerFfiMode`.
  ## Raises a compile-time `error` for unknown values.
  case s.toLowerAscii()
  of "cbor":
    result = mfCbor
  of "native":
    result = mfNative
  else:
    error("ffiMode must be \"cbor\" or \"native\"; got \"" & s & "\"")

proc resolveFfiMode*(
    configMode: BrokerFfiMode, configModeExplicit: bool, libName: string
): BrokerFfiMode {.compileTime.} =
  ## Resolve the effective FFI mode following the precedence rules in the
  ## module docstring. `configModeExplicit` distinguishes "user wrote
  ## ffiMode: cbor" from "user wrote nothing, the default applies".
  when brokerFfiApiNativeForced:
    result = mfNative
  elif brokerFfiApiCborForced:
    result = mfCbor
  else:
    result = if configModeExplicit: configMode else: mfCbor

  gApiResolvedFfiMode = result
  gApiResolvedFfiModeSet = true

  when defined(brokerDebug):
    echo "[brokers/ffi] resolved mode for '", libName, "': ", result

{.pop.}
