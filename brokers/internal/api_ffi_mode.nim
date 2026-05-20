## API FFI Mode
## ------------
## Compile-time gate for the FFI surface. After the native codegen was
## retired (see `doc/CBOR_Refactoring.md`), CBOR is the only FFI
## strategy. The `BrokerFfiMode` enum is kept as a one-value enum so
## downstream call sites and the optional `ffiMode:` consistency check
## on `registerBrokerLibrary` keep compiling unchanged — collapsing it
## away is a follow-up task (see §10 of the plan).
##
## Either of `-d:BrokerFfiApi` or `-d:BrokerFfiApiCBOR` enables FFI
## codegen; without one of them `registerBrokerLibrary` is a no-op.
## `-d:BrokerFfiApiNative` is rejected as a hard compile error so a
## stale build script cannot silently produce the wrong artifact.

{.push raises: [].}

import std/[macros, strutils]

when defined(BrokerFfiApiNative):
  {.
    fatal:
      "BrokerFfiApiNative was retired — the native FFI codegen surface no " &
      "longer exists. See doc/CBOR_Refactoring.md. Pass `-d:BrokerFfiApiCBOR` " &
      "(or just `-d:BrokerFfiApi`) instead."
  .}

type BrokerFfiMode* = enum
  mfCbor ## CBOR-encoded buffer ABI (the only remaining strategy).

const
  brokerFfiApiCborForced* = defined(BrokerFfiApiCBOR)

# `brokerFfiMode` is the FFI mode visible to all FFI codegen sites.
# After the native retirement it is a constant, but the symbol stays
# so existing codegen call sites do not need rewriting.
const brokerFfiMode* {.used.}: BrokerFfiMode = mfCbor

var gApiResolvedFfiMode* {.compileTime.}: BrokerFfiMode = mfCbor
  ## The resolved mode for the current library. Always `mfCbor`; kept as
  ## a `var` so the legacy assignment in `resolveFfiMode` still compiles
  ## and so a future second mode (if one is ever reintroduced) can be
  ## wired back in without churning every read site.

var gApiResolvedFfiModeSet* {.compileTime.}: bool = false
  ## Sentinel: has `resolveFfiMode` been called for the current library?

proc parseFfiModeLiteral*(s: string): BrokerFfiMode {.compileTime.} =
  ## Map an `ffiMode:` field value (string literal) to `BrokerFfiMode`.
  ## Only `"cbor"` is accepted; `"native"` is rejected with a pointer to
  ## the refactoring doc.
  case s.toLowerAscii()
  of "cbor":
    result = mfCbor
  of "native":
    error(
      "ffiMode: \"native\" is no longer supported — the native FFI codegen " &
        "surface was retired. See doc/CBOR_Refactoring.md."
    )
  else:
    error("ffiMode must be \"cbor\"; got \"" & s & "\"")

proc resolveFfiMode*(
    configMode: BrokerFfiMode, configModeExplicit: bool, libName: string
): BrokerFfiMode {.compileTime.} =
  ## Consistency check on the optional `ffiMode:` field. Always returns
  ## `mfCbor`; rejects any explicit mismatch.
  result = brokerFfiMode

  if configModeExplicit and configMode != result:
    error(
      "registerBrokerLibrary: ffiMode for '" & libName & "' is " & $configMode &
        " but only " & $result & " is supported. Remove the `ffiMode:` field " &
        "or set it to \"cbor\"."
    )

  gApiResolvedFfiMode = result
  gApiResolvedFfiModeSet = true

  when defined(brokerDebug):
    echo "[brokers/ffi] resolved mode for '", libName, "': ", result

{.pop.}
