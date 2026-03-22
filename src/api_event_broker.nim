## API EventBroker
## ---------------
## Generates a multi-thread capable EventBroker with delivery-thread-based
## event delivery for C/C++ consumers.
##
## When compiled with `-d:BrokerFfiApi`, EventBroker(API) generates:
## 1. All MT broker code (via generateMtEventBroker) — Nim threads with
##    chronos event loops can still use `listen()` / `emit()` normally.
## 2. C callback typedef matching the event's field signature
## 3. Compile-time type ID constant for the event
## 4. Per-type handler proc for register/unregister (with threadvar handles)
## 5. Per-type cleanup proc (calls dropAllListeners)
## 6. Exported `on<TypeName>(ctx, callback) -> uint64` — returns listener handle
## 7. Exported `off<TypeName>(ctx, handle)` — removes listener (0 = all)
## 8. C header declarations appended to the compile-time accumulator
## 9. **First expansion only:** shared `RegisterEventListenerResult` type +
##    MT RequestBroker infrastructure (one shared broker for all event types)
##
## Event delivery flow:
##   Nim emit → MT EventBroker cross-thread → delivery thread listener fires
##   → allocShared C strings → invoke C callback → freeShared C strings
##
## When compiled without `-d:BrokerFfiApi`, falls back to MT mode.

{.push raises: [].}

import std/[macros, strutils]
import chronos, chronicles
import results
import ./helper/broker_utils, ./broker_context, ./mt_event_broker, ./api_common
import ./mt_request_broker

export results, chronos, chronicles, broker_context, mt_event_broker, api_common
export mt_request_broker

# ---------------------------------------------------------------------------
# Shared RequestBroker AST builder
# ---------------------------------------------------------------------------

proc buildSharedBrokerAst(): NimNode {.compileTime.} =
  ## Constructs the AST for the shared RegisterEventListenerResult RequestBroker.
  ## This is called once (by the first EventBroker(API) expansion) and produces:
  ##   RequestBroker(mt):
  ##     type RegisterEventListenerResult = object
  ##       handle*: uint64
  ##       success*: bool
  ##     proc signature*(action: int32, eventTypeId: int32, callbackPtr: pointer):
  ##         Future[Result[RegisterEventListenerResult, string]] {.async.}
  ##
  ## We build the AST that parseSingleTypeDef + generateMtRequestBroker expect.

  let typeSection = newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef,
      ident("RegisterEventListenerResult"),
      newEmptyNode(),
      newTree(
        nnkObjectTy,
        newEmptyNode(),
        newEmptyNode(),
        newTree(
          nnkRecList,
          newTree(nnkIdentDefs, postfix(ident("handle"), "*"), ident("uint64"), newEmptyNode()),
          newTree(
            nnkIdentDefs, postfix(ident("success"), "*"), ident("bool"), newEmptyNode()
          ),
        ),
      ),
    ),
  )

  # Build signature proc
  let sigReturnType = newTree(
    nnkBracketExpr,
    ident("Future"),
    newTree(
      nnkBracketExpr,
      ident("Result"),
      ident("RegisterEventListenerResult"),
      ident("string"),
    ),
  )

  let sigFormalParams = newTree(
    nnkFormalParams,
    sigReturnType,
    newTree(nnkIdentDefs, ident("action"), ident("int32"), newEmptyNode()),
    newTree(nnkIdentDefs, ident("eventTypeId"), ident("int32"), newEmptyNode()),
    newTree(nnkIdentDefs, ident("callbackPtr"), ident("pointer"), newEmptyNode()),
  )

  let sigPragmas = newTree(nnkPragma, ident("async"))

  let sigProc = newTree(
    nnkProcDef,
    postfix(ident("signature"), "*"),
    newEmptyNode(),
    newEmptyNode(),
    sigFormalParams,
    sigPragmas,
    newEmptyNode(),
    newEmptyNode(), # empty body (signature only)
  )

  # Combine into the body that generateMtRequestBroker expects
  result = newStmtList(typeSection, sigProc)

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

  # Step 2: Generate all MT event broker code (Nim threads keep full listen/emit)
  result = newStmtList()
  result.add(generateMtEventBroker(body))

  # Step 3: Assign compile-time type ID
  # NOTE: Must modify gApiEventTypeCounter directly here (not via a helper proc)
  # because the Nim VM does not persist side effects from called compileTime procs.
  let typeId = gApiEventTypeCounter
  gApiEventTypeCounter = gApiEventTypeCounter + 1
  let typeIdConst = ident(typeDisplayName & "ApiTypeId")
  let typeIdLit = newLit(typeId)
  result.add(
    quote do:
      const `typeIdConst`* = `typeIdLit`
  )

  # Step 4: Generate C callback type
  let callbackTypeIdent = ident(typeDisplayName & "CCallback")
  let exportedCallbackIdent = postfix(copyNimTree(callbackTypeIdent), "*")

  if hasInlineFields:
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
    var callbackFormal = newTree(nnkFormalParams, newEmptyNode())
    let callbackPragmas = newTree(nnkPragma, ident("cdecl"))
    let callbackProcType = newTree(nnkProcTy, callbackFormal, callbackPragmas)
    result.add(
      newTree(
        nnkTypeSection,
        newTree(nnkTypeDef, exportedCallbackIdent, newEmptyNode(), callbackProcType),
      )
    )

  # Step 5: If first expansion, generate the shared RegisterEventListenerResult
  # RequestBroker (MT mode, internal — not exported to C)
  if not gApiSharedBrokerGenerated:
    gApiSharedBrokerGenerated = true
    let brokerAst = buildSharedBrokerAst()
    result.add(generateMtRequestBroker(brokerAst))

  # Step 6: Generate per-type handler proc
  # This proc handles register/unregister for this specific event type.
  # It stores listener handles in a threadvar (delivery thread only).
  let handlerProcName = "handle" & typeDisplayName & "Registration"
  let handlerProcIdent = ident(handlerProcName)
  let listenerHandleType = ident(typeDisplayName & "Listener")
  let listenerProcType = ident(typeDisplayName & "ListenerProc")

  # Build the handler proc — uses quote do with genSym'd identifiers
  block:
    let handlesIdent = ident("g" & typeDisplayName & "ApiListenerHandles")

    # Build wrapper lambda body: converts event fields to C types, calls callback
    let evtParam = genSym(nskParam, "evt")
    let cbLocal = genSym(nskLet, "cb")

    var preCallStmts = newStmtList()
    var callbackCallArgs: seq[NimNode] = @[]
    var postCallStmts = newStmtList()

    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fName = fieldNames[i]
        let fType = fieldTypes[i]
        if isCStringType(fType):
          let cVarIdent = genSym(nskLet, "c_" & $fName)
          preCallStmts.add(
            newTree(
              nnkLetSection,
              newTree(
                nnkIdentDefs,
                cVarIdent,
                newEmptyNode(),
                newCall(
                  ident("allocSharedCString"),
                  newDotExpr(evtParam, copyNimTree(fName)),
                ),
              ),
            )
          )
          callbackCallArgs.add(cVarIdent)
          postCallStmts.add(
            newCall(ident("freeSharedCString"), cVarIdent)
          )
        else:
          callbackCallArgs.add(
            newDotExpr(evtParam, copyNimTree(fName))
          )

    var cbInvocation = newCall(cbLocal)
    for arg in callbackCallArgs:
      cbInvocation.add(arg)

    result.add(
      quote do:
        var `handlesIdent` {.threadvar.}: seq[`listenerHandleType`]
    )

    result.add(
      quote do:
        proc `handlerProcIdent`(
            ctx: BrokerContext, action: int32, callbackPtr: pointer
        ): Future[Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
          case action
          of 0:
            # Register: wrap C callback in a listener proc, call listen()
            let `cbLocal` = cast[`callbackTypeIdent`](callbackPtr)
            let wrapper: `listenerProcType` = proc(
                `evtParam`: `typeIdent`
            ): Future[void] {.async: (raises: []).} =
              `preCallStmts`
              {.gcsafe.}:
                try:
                  `cbInvocation`
                except Exception:
                  discard
              `postCallStmts`

            let listenRes = `typeIdent`.listen(ctx, wrapper)
            if listenRes.isOk():
              `handlesIdent`.add(listenRes.get())
              return ok(RegisterEventListenerResult(
                handle: listenRes.get().id, success: true
              ))
            else:
              return err(listenRes.error())

          of 1:
            # Unregister by handle
            let targetId = cast[uint64](callbackPtr)
            for i in 0 ..< `handlesIdent`.len:
              if `handlesIdent`[i].id == targetId:
                `typeIdent`.dropListener(ctx, `handlesIdent`[i])
                `handlesIdent`.del(i)
                return ok(RegisterEventListenerResult(
                  handle: targetId, success: true
                ))
            return err("Handle not found")

          of 2:
            # Unregister all for this event type
            for h in `handlesIdent`:
              `typeIdent`.dropListener(ctx, h)
            `handlesIdent`.setLen(0)
            return ok(RegisterEventListenerResult(handle: 0, success: true))

          else:
            return err("Unknown action: " & $action)
    )

  # Step 7: Generate cleanup proc
  let cleanupProcName = "cleanup" & typeDisplayName & "Listeners"
  let cleanupProcIdent = ident(cleanupProcName)

  result.add(
    quote do:
      proc `cleanupProcIdent`(ctx: BrokerContext) =
        `typeIdent`.dropAllListeners(ctx)
  )

  # Step 8: Generate C-exported on<TypeName>(ctx, callback) -> uint64
  let regFuncName = "on" & typeDisplayName
  let regFuncIdent = ident(regFuncName)
  let regFuncNameLit = newLit(regFuncName)
  let callbackParamIdent = ident("callback")

  result.add(
    quote do:
      proc `regFuncIdent`(
          ctx: uint32, `callbackParamIdent`: `callbackTypeIdent`
      ): uint64 {.exportc: `regFuncNameLit`, cdecl, dynlib.} =
        let res = waitFor RegisterEventListenerResult.request(
          BrokerContext(ctx),
          0'i32,
          int32(`typeIdConst`),
          cast[pointer](`callbackParamIdent`),
        )
        if res.isOk():
          res.get().handle
        else:
          0'u64
  )

  # Step 9: Generate C-exported off<TypeName>(ctx, handle)
  let deregFuncName = "off" & typeDisplayName
  let deregFuncIdent = ident(deregFuncName)
  let deregFuncNameLit = newLit(deregFuncName)

  result.add(
    quote do:
      proc `deregFuncIdent`(
          ctx: uint32, handle: uint64
      ) {.exportc: `deregFuncNameLit`, cdecl, dynlib.} =
        if handle == 0'u64:
          # Remove all listeners for this event type
          discard waitFor RegisterEventListenerResult.request(
            BrokerContext(ctx), 2'i32, int32(`typeIdConst`), nil
          )
        else:
          # Remove specific listener by handle
          discard waitFor RegisterEventListenerResult.request(
            BrokerContext(ctx), 1'i32, int32(`typeIdConst`), cast[pointer](handle)
          )
  )

  # Step 10: Append header declarations

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

  # Registration function prototype: returns uint64_t (listener handle)
  let regProto = generateCFuncProto(
    regFuncName,
    "uint64_t",
    @[("ctx", "uint32_t"), ("callback", typeDisplayName & "CCallback")],
  )
  appendHeaderDecl(regProto)

  # Deregistration function prototype: takes handle (0 = remove all)
  let deregProto = generateCFuncProto(
    deregFuncName, "void", @[("ctx", "uint32_t"), ("handle", "uint64_t")]
  )
  appendHeaderDecl(deregProto)

  # C++ wrapper class methods
  let cppOnMethod =
    "uint64_t on" & typeDisplayName & "(" & typeDisplayName & "CCallback cb) { return ::" &
    regFuncName & "(ctx_, cb); }"
  gApiCppClassMethods.add(cppOnMethod)

  let cppOffMethod =
    "void off" & typeDisplayName & "(uint64_t handle = 0) { ::" & deregFuncName &
    "(ctx_, handle); }"
  gApiCppClassMethods.add(cppOffMethod)

  # Step 11: Append to compile-time accumulators
  gApiEventHandlerEntries.add((typeId, handlerProcName))
  gApiEventCleanupProcNames.add(cleanupProcName)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
