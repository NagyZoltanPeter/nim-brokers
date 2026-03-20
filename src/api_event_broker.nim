## API EventBroker
## ---------------
## Generates a multi-thread capable EventBroker with additional FFI glue code
## for exposing event listener registration as C-callable exported functions.
##
## When compiled with `-d:BrokerFfiApi`, EventBroker(API) generates:
## 1. All MT broker code (via generateMtEventBroker)
## 2. C callback typedef matching the event's field signature
## 3. Exported C registration function: on<TypeName>(ctx, callback)
## 4. Exported C deregistration function: off<TypeName>(ctx)
## 5. C header declarations appended to the compile-time accumulator
##
## When compiled without `-d:BrokerFfiApi`, falls back to MT mode.

{.push raises: [].}

import std/[macros, strutils]
import chronos, chronicles
import results
import ./helper/broker_utils, ./broker_context, ./mt_event_broker, ./api_common

export results, chronos, chronicles, broker_context, mt_event_broker, api_common

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateApiEventBroker*(body: NimNode): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "EventBroker mode: API"

  # Step 1: Parse type definition with field info
  let parsed = parseSingleTypeDef(body, "EventBroker", collectFieldInfo = true)
  let typeIdent = parsed.typeIdent
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields

  let typeDisplayName = sanitizeIdentName(typeIdent)
  let snakeName = toSnakeCase(typeDisplayName)

  # Step 2: Generate all MT event broker code
  result = newStmtList()
  result.add(generateMtEventBroker(body))

  # Step 3: Generate C callback type
  # The callback receives C-compatible versions of the event fields.
  let callbackTypeIdent = ident(typeDisplayName & "CCallback")
  let exportedCallbackIdent = postfix(copyNimTree(callbackTypeIdent), "*")

  if hasInlineFields:
    # Build callback proc type: proc(field1: cType1, field2: cType2, ...) {.cdecl.}
    var callbackFormal = newTree(nnkFormalParams, newEmptyNode())
    for i in 0 ..< fieldNames.len:
      let cFieldType = toCFieldType(fieldTypes[i])
      callbackFormal.add(
        newTree(nnkIdentDefs, copyNimTree(fieldNames[i]), cFieldType, newEmptyNode())
      )
    let callbackPragmas = newTree(nnkPragma, ident("cdecl"))
    let callbackProcType = newTree(nnkProcTy, callbackFormal, callbackPragmas)

    result.add(
      newTree(
        nnkTypeSection,
        newTree(nnkTypeDef, exportedCallbackIdent, newEmptyNode(), callbackProcType),
      )
    )
  else:
    # No fields — callback takes no arguments
    var callbackFormal = newTree(nnkFormalParams, newEmptyNode())
    let callbackPragmas = newTree(nnkPragma, ident("cdecl"))
    let callbackProcType = newTree(nnkProcTy, callbackFormal, callbackPragmas)

    result.add(
      newTree(
        nnkTypeSection,
        newTree(nnkTypeDef, exportedCallbackIdent, newEmptyNode(), callbackProcType),
      )
    )

  # Step 4: Generate registration function on<TypeName>(ctx, callback)
  let regFuncName = "on" & typeDisplayName
  let regFuncIdent = ident(regFuncName)
  let regFuncNameLit = newLit(regFuncName)

  # Build the wrapper handler that converts Nim event to C callback args
  let eventIdent = ident("event")
  let callbackParamIdent = ident("callback")
  var callbackCallArgs: seq[NimNode] = @[]
  var preCallStmts = newStmtList()
  var postCallStmts = newStmtList()

  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = fieldNames[i]
      let fType = fieldTypes[i]
      if isCStringType(fType):
        let cVarIdent = ident("c_" & $fName)
        preCallStmts.add(
          quote do:
            let `cVarIdent` = allocCStringCopy(`eventIdent`.`fName`)
        )
        callbackCallArgs.add(cVarIdent)
        postCallStmts.add(
          quote do:
            freeCString(`cVarIdent`)
        )
      else:
        callbackCallArgs.add(
          quote do:
            `eventIdent`.`fName`
        )

  var callbackInvocation = newCall(callbackParamIdent)
  for arg in callbackCallArgs:
    callbackInvocation.add(arg)

  # Wrap callback invocation in try/except for raises:[] compatibility
  var wrappedCall = newStmtList()
  wrappedCall.add(preCallStmts)
  wrappedCall.add(callbackInvocation)
  wrappedCall.add(postCallStmts)

  var handlerBody = newStmtList()
  handlerBody.add(
    quote do:
      {.gcsafe.}:
        try:
          `wrappedCall`
        except Exception:
          discard
  )

  # Handler proc type ref from MT broker
  let handlerProcIdent = ident(typeDisplayName & "ListenerProc")

  result.add(
    quote do:
      proc `regFuncIdent`(
          ctx: uint32, `callbackParamIdent`: `callbackTypeIdent`
      ) {.exportc: `regFuncNameLit`, cdecl, dynlib.} =
        let brokerCtx = BrokerContext(ctx)
        let handler: `handlerProcIdent` = proc(
            `eventIdent`: `typeIdent`
        ): Future[void] {.async: (raises: []).} =
          `handlerBody`
        discard `typeIdent`.listen(brokerCtx, handler)

  )

  # Step 5: Generate deregistration function off<TypeName>(ctx)
  let deregFuncName = "off" & typeDisplayName
  let deregFuncIdent = ident(deregFuncName)
  let deregFuncNameLit = newLit(deregFuncName)

  result.add(
    quote do:
      proc `deregFuncIdent`(
          ctx: uint32
      ) {.exportc: `deregFuncNameLit`, cdecl, dynlib.} =
        let brokerCtx = BrokerContext(ctx)
        `typeIdent`.dropAllListeners(brokerCtx)

  )

  # Step 6: Append header declarations

  # C callback typedef
  var callbackHeaderParams: seq[string] = @[]
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let cType = nimTypeToCInput(fieldTypes[i])
      callbackHeaderParams.add(cType & " " & $fieldNames[i])

  var callbackTypedef = "typedef void (*" & callbackTypeIdent.repr & ")("
  if callbackHeaderParams.len == 0:
    callbackTypedef.add("void")
  else:
    callbackTypedef.add(callbackHeaderParams.join(", "))
  callbackTypedef.add(");\n")
  appendHeaderDecl(callbackTypedef)

  # Registration function prototype
  let regProto = generateCFuncProto(
    regFuncName,
    "void",
    @[("ctx", "uint32_t"), ("callback", typeDisplayName & "CCallback")],
  )
  appendHeaderDecl(regProto)

  # Deregistration function prototype
  let deregProto = generateCFuncProto(deregFuncName, "void", @[("ctx", "uint32_t")])
  appendHeaderDecl(deregProto)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
