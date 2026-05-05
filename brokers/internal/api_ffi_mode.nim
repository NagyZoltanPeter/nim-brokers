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

# `brokerFfiMode` is the FFI mode visible to all FFI codegen sites. Driven
# entirely by compile flags so it has a stable value before any macro
# expansion runs: per-broker macros (`RequestBroker(API)`,
# `EventBroker(API)`) expand *before* `registerBrokerLibrary` and therefore
# cannot consult a per-library `ffiMode:` field — the flag is the only
# persistent input across macro invocations. When neither force flag is set
# the default is `mfCbor` (the new strategy is the documented default — see
# plan §2). Setting `ffiMode:` on `registerBrokerLibrary` is then a
# *consistency check* against this constant, not an override.
const brokerFfiMode* {.used.}: BrokerFfiMode =
  when brokerFfiApiNativeForced: mfNative else: mfCbor

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
  ## Resolve the effective FFI mode and cross-check the optional `ffiMode:`
  ## field against the compile-flag-driven `brokerFfiMode` constant. A
  ## mismatch is rejected at compile time so users do not silently get the
  ## wrong codegen path.
  result = brokerFfiMode

  if configModeExplicit and configMode != result:
    let want =
      case result
      of mfCbor: "cbor (set -d:BrokerFfiApiCBOR or omit -d:BrokerFfiApiNative)"
      of mfNative: "native (set -d:BrokerFfiApiNative)"
    error(
      "registerBrokerLibrary: ffiMode for '" & libName & "' is " & $configMode &
        " but compile flags resolve to " & $result & ". Pick the matching switch: " &
        want & "."
    )

  gApiResolvedFfiMode = result
  gApiResolvedFfiModeSet = true

  when defined(brokerDebug):
    echo "[brokers/ffi] resolved mode for '", libName, "': ", result

{.pop.}
