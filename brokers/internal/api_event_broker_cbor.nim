## API EventBroker — CBOR mode codegen
## ------------------------------------
## Generates the CBOR-mode surface for `EventBroker(API)` declarations.
##
## For each declaration this module emits:
##
## 1. The underlying multi-thread EventBroker (via `generateMtEventBroker`).
##    Internal cross-thread emit dispatch stays as typed `Channel[T]`
##    traffic; CBOR encoding only happens at the moment we hand the event
##    to a foreign C callback.
##
## 2. A compile-time entry in `gApiCborEventEntries` so the upcoming
##    `registerBrokerLibrary` CBOR backend can wire the event into the
##    library's subscribe surface and emit a per-event listener installer.
##
## Listener installation is intentionally NOT generated here — installers
## need access to the library's subscription map / lock / callback-type,
## which only exist at `registerBrokerLibrary` expansion time. We just
## record the event's wire name and Nim type identifier; the library macro
## materialises the installer with the right captures.
##
## Wire `eventName` is the snake_case form of the event's Nim type
## identifier — e.g. `DeviceUpdated` becomes `device_updated`.

{.push raises: [].}

import std/[macros, strutils]
import ./helper/broker_utils, ./mt_event_broker, ./api_common, ./api_schema
import ./api_request_broker_cbor # for registerCborObjectType
import ./api_type_resolver

export mt_event_broker, api_common

proc generateApiCborEventBrokerImpl(body: NimNode): NimNode =
  result = newStmtList()

  # 1. Emit the underlying MT event broker (single-thread emit/listen API
  #    visible to user code, MT-aware cross-thread dispatch under the hood).
  result.add(generateMtEventBroker(copyNimTree(body)))

  # 2. Parse the event type identifier and register the entry. Capture
  #    field info so wrapper codegen can emit typed structs for the
  #    payload.
  let parsed = parseSingleTypeDef(
    body, "EventBroker", allowRefToNonObject = true, collectFieldInfo = true
  )
  let typeIdent = parsed.typeIdent
  let typeName = sanitizeIdentName(typeIdent)
  let apiName = toSnakeCase(typeName)
  if parsed.hasInlineFields:
    registerCborObjectType(typeName, parsed.fieldNames, parsed.fieldTypes)
  registerCborEventEntry(apiName, typeName)

  when defined(brokerDebug):
    echo "[brokers/cbor] EventBroker(API) for '" & typeName & "' (eventName='" & apiName &
      "')"
    echo result.repr

{.pop.}

macro generateApiCborEventBrokerDeferred*(body: untyped): untyped =
  ## Typed-phase deferred entry point; populates the registry first.
  generateApiCborEventBrokerImpl(body)

{.push raises: [].}

proc generateApiCborEventBroker*(body: NimNode): NimNode =
  result = newStmtList()

  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  let sizeIdents = discoverArraySizeIdents(body)
  if sizeIdents.len > 0:
    result.add(emitArraySizeRegistrations(sizeIdents))

  result.add(newCall(ident("generateApiCborEventBrokerDeferred"), copyNimTree(body)))

{.pop.}
