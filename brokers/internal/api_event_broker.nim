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
import ./helper/broker_utils, ../broker_context, ./mt_event_broker, ./api_common
import ./mt_request_broker
import ./api_type_resolver

export results, chronos, chronicles, broker_context, mt_event_broker, api_common
export mt_request_broker, api_type_resolver

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
  ##     proc signature*(
  ##         action: int32,
  ##         eventTypeId: int32,
  ##         callbackPtr: pointer,
  ##         userData: pointer,
  ##         listenerHandle: uint64,
  ##     ):
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
          newTree(
            nnkIdentDefs, postfix(ident("handle"), "*"), ident("uint64"), newEmptyNode()
          ),
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
    newTree(nnkIdentDefs, ident("userData"), ident("pointer"), newEmptyNode()),
    newTree(nnkIdentDefs, ident("listenerHandle"), ident("uint64"), newEmptyNode()),
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

proc generateApiEventBrokerImpl(body: NimNode): NimNode =
  ## Core codegen for API event broker. Called from `generateApiEventBrokerDeferred`
  ## AFTER external types have been auto-registered.
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

  # ---------------------------------------------------------------------------
  # Type classification helpers
  # ---------------------------------------------------------------------------

  proc isSeqOfStringNode(fType: NimNode): bool {.compileTime.} =
    if isSeqType(fType):
      let elem = seqItemTypeName(fType).toLowerAscii()
      return elem in ["string", "cstring"]
    false

  proc isSeqOfPrimitiveNode(fType: NimNode): bool {.compileTime.} =
    if isSeqType(fType):
      return isNimPrimitive(seqItemTypeName(fType))
    false

  # ---------------------------------------------------------------------------
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
  # seq[T] and array[N,T] fields each expand to two callback params (ptr + count).
  # Enum fields map to cint.
  let callbackTypeIdent = ident(typeDisplayName & "CCallback")
  let exportedCallbackIdent = postfix(copyNimTree(callbackTypeIdent), "*")

  block:
    var callbackFormal = newTree(nnkFormalParams, newEmptyNode())
    callbackFormal.add(
      newTree(nnkIdentDefs, ident("ctx"), ident("uint32"), newEmptyNode())
    )
    callbackFormal.add(
      newTree(nnkIdentDefs, ident("userData"), ident("pointer"), newEmptyNode())
    )
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fType = fieldTypes[i]
        if isSeqType(fType) or isArrayTypeNode(fType):
          # Two params: typed pointer + cint count
          # Use concrete pointer type to match the C header typedef
          let elemPtrType = block:
            if isSeqOfStringNode(fType):
              ident("cstring")
            elif isSeqOfPrimitiveNode(fType) or isArrayTypeNode(fType):
              let elemName =
                if isArrayTypeNode(fType):
                  arrayNodeElemName(fType)
                else:
                  seqItemTypeName(fType)
              toCFieldType(ident(elemName))
            elif isSeqType(fType):
              let itemTypeName = seqItemTypeName(fType)
              ident(itemTypeName & "CItem")
            else:
              ident("pointer")
          let ptrType = newTree(nnkPtrTy, elemPtrType)
          callbackFormal.add(
            newTree(nnkIdentDefs, copyNimTree(fieldNames[i]), ptrType, newEmptyNode())
          )
          callbackFormal.add(
            newTree(
              nnkIdentDefs,
              ident($fieldNames[i] & "_count"),
              ident("cint"),
              newEmptyNode(),
            )
          )
        elif isEnumRegistered($fType):
          callbackFormal.add(
            newTree(
              nnkIdentDefs,
              copyNimTree(fieldNames[i]),
              copyNimTree(fType),
              newEmptyNode(),
            )
          )
        else:
          let cFieldType = toCFieldType(fType)
          callbackFormal.add(
            newTree(
              nnkIdentDefs, copyNimTree(fieldNames[i]), cFieldType, newEmptyNode()
            )
          )
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
    #
    # Memory model for event callbacks
    # ---------------------------------
    # The generated async wrapper proc runs on the delivery thread. For each
    # event emission it performs three phases, driven by the code below:
    #
    # 1. preCallStmts  — allocate and populate shared-heap buffers for every
    #    field type that cannot be passed by value across the C ABI:
    #      string       → allocCStringCopy()  (NUL-terminated copy on shared heap)
    #      seq[string]  → allocShared(n * sizeof(cstring)) + per-element copies
    #      seq[prim]    → allocShared(n * sizeof(primType)) + element copy loop
    #      seq[object]  → allocShared(n * sizeof(CItem)) + encode loop
    #      array[N, T]  → allocShared(N * sizeof(elemType)) + element copy loop
    #    Scalars (int, bool, enum, distinct) need no allocation — passed by value.
    #
    # 2. cbInvocation  — the C callback is called with the raw pointers and counts.
    #    The callback runs synchronously inside the try block. Any exception thrown
    #    by the callback is caught and discarded so it cannot escape the C ABI.
    #    All pointers are valid for exactly the duration of this call.
    #
    # 3. postCallStmts — free every shared-heap buffer allocated in step 1, in the
    #    same order:
    #      string       → freeSharedCString()
    #      seq[string]  → freeCString() each element, then deallocShared(array)
    #      seq[prim]    → deallocShared(array)   (no per-element cleanup)
    #      seq[object]  → deallocShared(array)   (CItem fields are value-copied)
    #      array[N, T]  → deallocShared(array)   (always allocated, never nil)
    #    postCallStmts runs unconditionally after the callback returns, whether
    #    or not the callback threw. The foreign caller must not retain the pointers
    #    after the callback returns — they are freed immediately.
    let evtParam = genSym(nskParam, "evt")
    let cbLocal = genSym(nskLet, "cb")
    let userDataLocal = genSym(nskLet, "userData")
    let ctxValueLocal = genSym(nskLet, "ctxValue")

    var preCallStmts = newStmtList()
    var callbackCallArgs: seq[NimNode] = @[ctxValueLocal, userDataLocal]
    var postCallStmts = newStmtList()

    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fName = fieldNames[i]
        let fType = fieldTypes[i]
        if isCStringType(fType):
          # string: allocate a NUL-terminated copy on the shared heap, pass as
          # const char*, free with freeSharedCString after the callback returns.
          let cVarIdent = genSym(nskLet, "c_" & $fName)
          preCallStmts.add(
            newTree(
              nnkLetSection,
              newTree(
                nnkIdentDefs,
                cVarIdent,
                newEmptyNode(),
                newCall(
                  ident("allocSharedCString"), newDotExpr(evtParam, copyNimTree(fName))
                ),
              ),
            )
          )
          callbackCallArgs.add(cVarIdent)
          postCallStmts.add(newCall(ident("freeSharedCString"), cVarIdent))
        elif isSeqType(fType):
          # seq[T]: allocate a contiguous shared-heap array, pass pointer+count,
          # free after the callback returns. Three sub-cases:
          let ptrVarIdent = genSym(nskLet, "ptr_" & $fName)
          let countVarIdent = genSym(nskLet, "n_" & $fName)
          let elemName = seqItemTypeName(fType)
          var seqPtrCastType: NimNode
          if isSeqOfStringNode(fType):
            # seq[string]: allocShared(n * sizeof(cstring)) for the pointer array,
            # then allocCStringCopy per element. On free: freeCString each element
            # first, then deallocShared the outer array.
            seqPtrCastType = newTree(nnkPtrTy, ident("cstring"))
            preCallStmts.add(
              quote do:
                let `countVarIdent` = cint(`evtParam`.`fName`.len)
                let `ptrVarIdent` =
                  if `countVarIdent` > 0:
                    let arr = cast[ptr UncheckedArray[cstring]](allocShared(
                      int(`countVarIdent`) * sizeof(cstring)
                    ))
                    for ii in 0 ..< int(`countVarIdent`):
                      arr[ii] = allocCStringCopy(`evtParam`.`fName`[ii])
                    cast[pointer](arr)
                  else:
                    nil
            )
            postCallStmts.add(
              quote do:
                if not `ptrVarIdent`.isNil:
                  let arr = cast[ptr UncheckedArray[cstring]](`ptrVarIdent`)
                  for ii in 0 ..< int(`countVarIdent`):
                    if not arr[ii].isNil:
                      freeCString(arr[ii])
                  deallocShared(`ptrVarIdent`)
            )
          elif isNimPrimitive(elemName):
            # seq[primitive]: allocShared(n * sizeof(T)) + element copy. On free:
            # deallocShared only — no per-element cleanup needed for value types.
            let primCNimType = toCFieldType(ident(elemName))
            seqPtrCastType = newTree(nnkPtrTy, primCNimType)
            preCallStmts.add(
              quote do:
                let `countVarIdent` = cint(`evtParam`.`fName`.len)
                let `ptrVarIdent` =
                  if `countVarIdent` > 0:
                    let arr = cast[ptr UncheckedArray[`primCNimType`]](allocShared(
                      int(`countVarIdent`) * sizeof(`primCNimType`)
                    ))
                    for ii in 0 ..< int(`countVarIdent`):
                      arr[ii] = `primCNimType`(`evtParam`.`fName`[ii])
                    cast[pointer](arr)
                  else:
                    nil
            )
            postCallStmts.add(
              quote do:
                if not `ptrVarIdent`.isNil:
                  deallocShared(`ptrVarIdent`)
            )
          else:
            # seq[object]: allocShared(n * sizeof(CItem)) + encode each element.
            # On free: deallocShared only — string fields inside CItem are not
            # separately heap-allocated for event callbacks (unlike CResult structs).
            let cItemIdent = ident(elemName & "CItem")
            seqPtrCastType = newTree(nnkPtrTy, cItemIdent)
            let encodeFuncIdent = ident("encode" & elemName & "ToCItem")
            preCallStmts.add(
              quote do:
                let `countVarIdent` = cint(`evtParam`.`fName`.len)
                let `ptrVarIdent` =
                  if `countVarIdent` > 0:
                    let arr = cast[ptr UncheckedArray[`cItemIdent`]](allocShared(
                      int(`countVarIdent`) * sizeof(`cItemIdent`)
                    ))
                    for ii in 0 ..< int(`countVarIdent`):
                      arr[ii] = `encodeFuncIdent`(`evtParam`.`fName`[ii])
                    cast[pointer](arr)
                  else:
                    nil
            )
            postCallStmts.add(
              quote do:
                if not `ptrVarIdent`.isNil:
                  deallocShared(`ptrVarIdent`)
            )
          callbackCallArgs.add(newTree(nnkCast, seqPtrCastType, ptrVarIdent))
          callbackCallArgs.add(countVarIdent)
        elif isArrayTypeNode(fType):
          # array[N, T]: allocShared(N * sizeof(T)) + element copy, pass as
          # const T* + int32_t count (same layout as seq[primitive] at the C ABI).
          # The allocation is always non-nil (N is a compile-time constant > 0).
          # On free: deallocShared unconditionally — no nil check needed.
          let n = arrayNodeSize(fType)
          let elemName = arrayNodeElemName(fType)
          let ptrVarIdent = genSym(nskLet, "ptr_" & $fName)
          let countLit = newLit(cint(n))
          let primCNimType = toCFieldType(ident(elemName))
          preCallStmts.add(
            quote do:
              let `ptrVarIdent` = block:
                let arr = cast[ptr UncheckedArray[`primCNimType`]](allocShared(
                  `n` * sizeof(`primCNimType`)
                ))
                for ii in 0 ..< `n`:
                  arr[ii] = `primCNimType`(`evtParam`.`fName`[ii])
                cast[pointer](arr)
          )
          postCallStmts.add(
            quote do:
              deallocShared(`ptrVarIdent`)
          )
          callbackCallArgs.add(
            newTree(nnkCast, newTree(nnkPtrTy, primCNimType), ptrVarIdent)
          )
          callbackCallArgs.add(countLit)
        elif isEnumRegistered($fType):
          # Enum: pass the enum value directly — callbackFormal now uses the
          # actual enum type (copyNimTree(fType)), so no cint conversion needed.
          callbackCallArgs.add(newDotExpr(evtParam, copyNimTree(fName)))
        elif isAliasOrDistinctRegistered($fType):
          # Alias/distinct: cast to underlying C field type
          let cFieldType = toCFieldType(fType)
          callbackCallArgs.add(
            newTree(nnkCast, cFieldType, newDotExpr(evtParam, copyNimTree(fName)))
          )
        else:
          callbackCallArgs.add(newDotExpr(evtParam, copyNimTree(fName)))

    var cbInvocation = newCall(cbLocal)
    for arg in callbackCallArgs:
      cbInvocation.add(arg)

    let registerHelperIdent = ident("register" & typeDisplayName & "Callback")
    let unregisterHelperIdent = ident("unregister" & typeDisplayName & "Callback")
    let unregisterAllHelperIdent =
      ident("unregisterAll" & typeDisplayName & "Callbacks")

    result.add(
      quote do:
        var `handlesIdent` {.threadvar.}: seq[`listenerHandleType`]
    )

    # Non-async helper for registration — closures capture from a normal
    # stack frame, not from an async Future's environment (which can be freed).
    result.add(
      quote do:
        proc `registerHelperIdent`(
            ctx: BrokerContext, callbackPtr: pointer, userData: pointer
        ): Result[RegisterEventListenerResult, string] =
          let `cbLocal` = cast[`callbackTypeIdent`](callbackPtr)
          let `userDataLocal` = userData
          let `ctxValueLocal` = uint32(ctx)
          let wrapper: `listenerProcType` = proc(
              `evtParam`: `typeIdent`
          ): Future[void] {.async: (raises: []).} =
            when defined(brokerDebug):
              debugEcho "[API-EVENT] Entering wrapper, cb isNil=", `cbLocal`.isNil()
            `preCallStmts`
            when defined(brokerDebug):
              debugEcho "[API-EVENT] post-alloc, calling cb"
            {.gcsafe.}:
              try:
                `cbInvocation`
              except Exception:
                when defined(brokerDebug):
                  debugEcho "[API-EVENT] Callback exception: ", getCurrentExceptionMsg()
                discard
            when defined(brokerDebug):
              debugEcho "[API-EVENT] cb done, freeing"
            `postCallStmts`

          let listenRes = `typeIdent`.listen(ctx, wrapper)
          if listenRes.isOk():
            `handlesIdent`.add(listenRes.get())
            return
              ok(RegisterEventListenerResult(handle: listenRes.get().id, success: true))
          else:
            return err(listenRes.error())

        proc `unregisterHelperIdent`(
            ctx: BrokerContext, targetId: uint64
        ): Result[RegisterEventListenerResult, string] =
          for i in 0 ..< `handlesIdent`.len:
            if `handlesIdent`[i].id == targetId:
              `typeIdent`.dropListener(ctx, `handlesIdent`[i])
              `handlesIdent`.del(i)
              return ok(RegisterEventListenerResult(handle: targetId, success: true))
          return err("Handle not found")

        proc `unregisterAllHelperIdent`(
            ctx: BrokerContext
        ): Result[RegisterEventListenerResult, string] =
          for h in `handlesIdent`:
            `typeIdent`.dropListener(ctx, h)
          `handlesIdent`.setLen(0)
          return ok(RegisterEventListenerResult(handle: 0'u64, success: true))

    )

    result.add(
      quote do:
        proc `handlerProcIdent`(
            ctx: BrokerContext,
            action: int32,
            callbackPtr: pointer,
            userData: pointer,
            listenerHandle: uint64,
        ): Future[Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
          case action
          of 0:
            return `registerHelperIdent`(ctx, callbackPtr, userData)
          of 1:
            return `unregisterHelperIdent`(ctx, listenerHandle)
          of 2:
            return `unregisterAllHelperIdent`(ctx)
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
  let publicRegFuncName = apiPublicCName(regFuncName)
  let regFuncIdent = ident(regFuncName)
  let regFuncNameLit = newLit(regFuncName)
  let callbackParamIdent = ident("callback")

  result.add(
    quote do:
      proc `regFuncIdent`(
          ctx: uint32, `callbackParamIdent`: `callbackTypeIdent`, userData: pointer
      ): uint64 {.exportc: `regFuncNameLit`, cdecl, dynlib.} =
        let res = waitFor RegisterEventListenerResult.request(
          BrokerContext(ctx),
          0'i32,
          int32(`typeIdConst`),
          cast[pointer](`callbackParamIdent`),
          userData,
          0'u64,
        )
        if res.isOk():
          res.get().handle
        else:
          0'u64

  )

  # Step 9: Generate C-exported off<TypeName>(ctx, handle)
  let deregFuncName = "off" & typeDisplayName
  let publicDeregFuncName = apiPublicCName(deregFuncName)
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
            BrokerContext(ctx), 2'i32, int32(`typeIdConst`), nil, nil, 0'u64
          )
        else:
          # Remove specific listener by handle
          discard waitFor RegisterEventListenerResult.request(
            BrokerContext(ctx), 1'i32, int32(`typeIdConst`), nil, nil, handle
          )

  )

  # Step 10: Append header declarations

  # C callback typedef
  var callbackHeaderParams: seq[string] = @[]
  callbackHeaderParams.add("uint32_t ctx")
  callbackHeaderParams.add("void* userData")
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = $fieldNames[i]
      let fType = fieldTypes[i]
      if isSeqOfStringNode(fType):
        callbackHeaderParams.add("const char** " & fName)
        callbackHeaderParams.add("int32_t " & fName & "_count")
      elif isSeqOfPrimitiveNode(fType):
        let elemCType = nimTypeToCSuffix(ident(seqItemTypeName(fType)))
        callbackHeaderParams.add("const " & elemCType & "* " & fName)
        callbackHeaderParams.add("int32_t " & fName & "_count")
      elif isSeqType(fType):
        let itemTypeName = seqItemTypeName(fType)
        callbackHeaderParams.add(itemTypeName & "CItem* " & fName)
        callbackHeaderParams.add("int32_t " & fName & "_count")
      elif isArrayTypeNode(fType):
        let elemCType = nimTypeToCSuffix(ident(arrayNodeElemName(fType)))
        callbackHeaderParams.add("const " & elemCType & "* " & fName)
        callbackHeaderParams.add("int32_t " & fName & "_count")
      else:
        let cType = nimTypeToCInput(fType)
        callbackHeaderParams.add(cType & " " & fName)

  var callbackTypedef = "typedef void (*" & callbackTypeIdent.repr & ")("
  if callbackHeaderParams.len == 0:
    callbackTypedef.add("void")
  else:
    callbackTypedef.add(callbackHeaderParams.join(", "))
  callbackTypedef.add(");\n")
  appendHeaderDecl(callbackTypedef)

  # Registration function prototype: returns uint64_t (listener handle)
  let regProto = generateCFuncProto(
    publicRegFuncName,
    "uint64_t",
    @[
      ("ctx", "uint32_t"),
      ("callback", typeDisplayName & "CCallback"),
      ("userData", "void*"),
    ],
  )
  appendHeaderDecl(regProto)
  registerApiCExportWrapper(
    regFuncName,
    regFuncName,
    "uint64",
    @[
      ("ctx", "uint32"),
      ("callback", typeDisplayName & "CCallback"),
      ("userData", "pointer"),
    ],
  )

  # Deregistration function prototype: takes handle (0 = remove all)
  let deregProto = generateCFuncProto(
    publicDeregFuncName, "void", @[("ctx", "uint32_t"), ("handle", "uint64_t")]
  )
  appendHeaderDecl(deregProto)
  registerApiCExportWrapper(
    deregFuncName, deregFuncName, "void", @[("ctx", "uint32"), ("handle", "uint64")]
  )

  # C++ wrapper: instance-owned dispatcher with owner-aware callbacks.
  if not gApiCppEventSupportGenerated:
    gApiCppEventSupportGenerated = true
    gApiCppPreamble.add(
      """
template <typename Owner, typename Traits, typename... CArgs>
class EventDispatcher {
public:
    using Callback = typename Traits::template Callback<Owner>;
    using CCallback = typename Traits::CCallback;

    explicit EventDispatcher(Owner& owner) noexcept
        : owner_(&owner) {}

    EventDispatcher(const EventDispatcher&) = delete;
    EventDispatcher& operator=(const EventDispatcher&) = delete;
    EventDispatcher(EventDispatcher&&) = delete;
    EventDispatcher& operator=(EventDispatcher&&) = delete;

    ~EventDispatcher() {
        clear();
    }

    uint64_t add(Callback fn) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);

        if (!owner_ || owner_->ctx() == 0 || !fn) {
            return 0;
        }

        if (nativeHandle_ == 0) {
            nativeHandle_ = Traits::registerWithC(
                owner_->ctx(),
                &EventDispatcher::trampoline,
                static_cast<void*>(this)
            );
            if (nativeHandle_ == 0) {
                return 0;
            }
        }

        const uint64_t localHandle = nextLocalHandle_++;
        try {
            callbacks_.emplace(localHandle, std::move(fn));
            return localHandle;
        } catch (...) {
            if (callbacks_.empty() && nativeHandle_ != 0) {
                Traits::unregisterWithC(owner_->ctx(), nativeHandle_);
                nativeHandle_ = 0;
            }
            return 0;
        }
    }

    void remove(uint64_t localHandle) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);

        callbacks_.erase(localHandle);
        if (callbacks_.empty() && nativeHandle_ != 0) {
            if (owner_ && owner_->ctx() != 0) {
                Traits::unregisterWithC(owner_->ctx(), nativeHandle_);
            }
            nativeHandle_ = 0;
        }
    }

    void clear() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);

        callbacks_.clear();
        if (nativeHandle_ != 0) {
            if (owner_ && owner_->ctx() != 0) {
                Traits::unregisterWithC(owner_->ctx(), nativeHandle_);
            }
            nativeHandle_ = 0;
        }
    }

private:
    static void trampoline(uint32_t ctx, void* userData, CArgs... args) noexcept {
        auto* self = static_cast<EventDispatcher*>(userData);
        if (!self) {
            return;
        }
        self->deliver(ctx, args...);
    }

    void deliver(uint32_t ctx, CArgs... args) noexcept {
        std::vector<Callback> snapshot;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!owner_ || ctx != owner_->ctx()) {
                return;
            }

            try {
                snapshot.reserve(callbacks_.size());
                for (const auto& [id, fn] : callbacks_) {
                    if (fn) {
                        snapshot.push_back(fn);
                    }
                }
            } catch (...) {
                return;
            }
        }

        for (const auto& fn : snapshot) {
            Traits::invoke(fn, *owner_, args...);
        }
    }

    Owner* owner_ = nullptr;
    std::mutex mutex_;
    std::unordered_map<uint64_t, Callback> callbacks_;
    uint64_t nativeHandle_ = 0;
    uint64_t nextLocalHandle_ = 1;
};
"""
    )

  var cppCbParams: seq[string] = @[("Owner& owner")]
  var cppCbSummaryParams: seq[string] = @[("owner")]
  var cTrampolineParams: seq[string] = @[]
  var traitInvokeArgs: seq[string] = @["owner"]
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = $fieldNames[i]
      let fType = fieldTypes[i]
      if isSeqOfStringNode(fType):
        # C++ callback sees std::span<const char*>
        cppCbParams.add("std::span<const char*> " & fName)
        cppCbSummaryParams.add(fName)
        cTrampolineParams.add("const char** " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        traitInvokeArgs.add(
          "std::span<const char*>(" & fName & ", " & fName & "_count)"
        )
      elif isSeqOfPrimitiveNode(fType):
        let elemName = seqItemTypeName(fType)
        let cppElemType = nimTypeToCpp(ident(elemName))
        let cElemType = nimTypeToCSuffix(ident(elemName))
        cppCbParams.add("std::span<const " & cppElemType & "> " & fName)
        cppCbSummaryParams.add(fName)
        cTrampolineParams.add("const " & cElemType & "* " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        traitInvokeArgs.add(
          "std::span<const " & cppElemType & ">(" & fName & ", " & fName & "_count)"
        )
      elif isSeqType(fType):
        let itemTypeName = seqItemTypeName(fType)
        cppCbParams.add("std::span<const " & itemTypeName & "CItem> " & fName)
        cppCbSummaryParams.add(fName)
        cTrampolineParams.add(itemTypeName & "CItem* " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        traitInvokeArgs.add(
          "std::span<const " & itemTypeName & "CItem>(" & fName & ", " & fName &
            "_count)"
        )
      elif isArrayTypeNode(fType):
        let elemName = arrayNodeElemName(fType)
        let cppElemType = nimTypeToCpp(ident(elemName))
        let cElemType = nimTypeToCSuffix(ident(elemName))
        cppCbParams.add("std::span<const " & cppElemType & "> " & fName)
        cppCbSummaryParams.add(fName)
        cTrampolineParams.add("const " & cElemType & "* " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        traitInvokeArgs.add(
          "std::span<const " & cppElemType & ">(" & fName & ", " & fName & "_count)"
        )
      elif isEnumRegistered($fType):
        let enumTypeName = $fType
        cppCbParams.add(enumTypeName & " " & fName)
        cppCbSummaryParams.add(fName)
        cTrampolineParams.add(enumTypeName & " " & fName)
        traitInvokeArgs.add(fName)
      else:
        let cbType = nimTypeToCppCallbackParam(fType)
        let cType = nimTypeToCInput(fType)
        cppCbParams.add(cbType & " " & fName)
        cppCbSummaryParams.add(fName)
        cTrampolineParams.add(cType & " " & fName)
        if isCStringType(fType):
          traitInvokeArgs.add(
            fName & " ? std::string_view(" & fName & ") : std::string_view()"
          )
        else:
          traitInvokeArgs.add(fName)

  let traitName = typeDisplayName & "EventTraits"
  var trait = "struct " & traitName & " {\n"
  trait.add("    template <typename Owner>\n")
  trait.add(
    "    using Callback = std::function<void(" & cppCbParams.join(", ") & ")>;\n\n"
  )

  var callbackSignatureParams: seq[string] = @["uint32_t", "void*"]
  callbackSignatureParams.add(cTrampolineParams)
  trait.add(
    "    using CCallback = void (*)(" & callbackSignatureParams.join(", ") & ");\n\n"
  )

  trait.add(
    "    static uint64_t registerWithC(uint32_t ctx, CCallback callback, void* userData) noexcept {\n"
  )
  trait.add("        return ::" & publicRegFuncName & "(ctx, callback, userData);\n")
  trait.add("    }\n\n")

  trait.add(
    "    static void unregisterWithC(uint32_t ctx, uint64_t handle) noexcept {\n"
  )
  trait.add("        ::" & publicDeregFuncName & "(ctx, handle);\n")
  trait.add("    }\n\n")

  trait.add("    template <typename Owner>\n")
  trait.add("    static void invoke(const Callback<Owner>& fn")
  if cTrampolineParams.len > 0:
    trait.add(", ")
    var invokeParams: seq[string] = @["Owner& owner"]
    invokeParams.add(cTrampolineParams)
    trait.add(invokeParams.join(", "))
  else:
    trait.add("Owner& owner")
  trait.add(") noexcept {\n")
  trait.add("        try {\n")
  trait.add("            fn(" & traitInvokeArgs.join(", ") & ");\n")
  trait.add("        } catch (...) {\n")
  trait.add("        }\n")
  trait.add("    }\n")
  trait.add("};")
  gApiCppPreamble.add(trait)

  let dispatcherAlias = typeDisplayName & "Dispatcher"
  var cArgTypes: seq[string] = @[]
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fType = fieldTypes[i]
      if isSeqOfStringNode(fType):
        cArgTypes.add("const char**")
        cArgTypes.add("int32_t")
      elif isSeqOfPrimitiveNode(fType):
        cArgTypes.add("const " & nimTypeToCSuffix(ident(seqItemTypeName(fType))) & "*")
        cArgTypes.add("int32_t")
      elif isSeqType(fType):
        cArgTypes.add(seqItemTypeName(fType) & "CItem*")
        cArgTypes.add("int32_t")
      elif isArrayTypeNode(fType):
        cArgTypes.add(
          "const " & nimTypeToCSuffix(ident(arrayNodeElemName(fType))) & "*"
        )
        cArgTypes.add("int32_t")
      elif isEnumRegistered($fType):
        cArgTypes.add($fType)
      else:
        cArgTypes.add(nimTypeToCInput(fType))

  var dispatcherDecl =
    "    using " & dispatcherAlias & " = EventDispatcher<__CPP_CLASS__, " & traitName
  if cArgTypes.len > 0:
    dispatcherDecl.add(", " & cArgTypes.join(", "))
  dispatcherDecl.add(">;\n")
  dispatcherDecl.add(
    "    " & dispatcherAlias & " " & toSnakeCase(typeDisplayName) & "Dispatcher_;\n"
  )
  gApiCppPrivateMembers.add(dispatcherDecl)

  gApiCppConstructorInitializers.add(
    toSnakeCase(typeDisplayName) & "Dispatcher_(*this)"
  )
  gApiCppShutdownStatements.add(toSnakeCase(typeDisplayName) & "Dispatcher_.clear();")

  gApiCppClassMethods.add(
    "using " & typeDisplayName & "Callback = " & traitName & "::Callback<__CPP_CLASS__>;"
  )
  gApiCppInterfaceSummary.add(
    typeDisplayName & "Callback(" & cppCbSummaryParams.join(", ") & ");"
  )

  var onMethod =
    "uint64_t on" & typeDisplayName & "(" & typeDisplayName & "Callback fn) noexcept {\n"
  onMethod.add(
    "        return " & toSnakeCase(typeDisplayName) &
      "Dispatcher_.add(std::move(fn));\n"
  )
  onMethod.add("    }")
  gApiCppClassMethods.add(onMethod)
  gApiCppInterfaceSummary.add("on" & typeDisplayName & "(fn);")

  var offMethod = "void off" & typeDisplayName & "(uint64_t handle = 0) noexcept {\n"
  offMethod.add("        if (handle == 0) {\n")
  offMethod.add(
    "            " & toSnakeCase(typeDisplayName) & "Dispatcher_.clear();\n"
  )
  offMethod.add("        } else {\n")
  offMethod.add(
    "            " & toSnakeCase(typeDisplayName) & "Dispatcher_.remove(handle);\n"
  )
  offMethod.add("        }\n")
  offMethod.add("    }")
  gApiCppClassMethods.add(offMethod)
  gApiCppInterfaceSummary.add("off" & typeDisplayName & "(handle = 0);")

  # Step 11: Generate Python on/off event methods (when -d:BrokerFfiApiGenPy)
  when defined(BrokerFfiApiGenPy):
    let pySnakeEvent = toSnakeCase(typeDisplayName)

    # CFUNCTYPE definition + argtypes/restype setup
    # Store CFUNCTYPE as instance attribute (self._XxxCCallback) for use in methods
    block:
      var cfuncArgs: seq[string] = @[]
      cfuncArgs.add("None") # return type
      cfuncArgs.add("ctypes.c_uint32")
      cfuncArgs.add("ctypes.c_void_p")
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          if isSeqType(fieldTypes[i]):
            cfuncArgs.add("ctypes.c_void_p")
            cfuncArgs.add("ctypes.c_int32")
          elif isArrayTypeNode(fieldTypes[i]):
            # C ABI: const elemType* ptr + int32_t count (Nim heap-copies the array)
            let ctElem = nimTypeToCtypes(ident(arrayNodeElemName(fieldTypes[i])))
            cfuncArgs.add("ctypes.POINTER(" & ctElem & ")")
            cfuncArgs.add("ctypes.c_int32")
          else:
            cfuncArgs.add(nimTypeToCtypes(fieldTypes[i]))

      let cfuncName = "self._" & typeDisplayName & "CCallback"
      gApiPyCallbackSetup.add(
        cfuncName & " = ctypes.CFUNCTYPE(" & cfuncArgs.join(", ") & ")"
      )
      gApiPyCallbackSetup.add(
        "_lib." & publicRegFuncName & ".argtypes = [ctypes.c_uint32, " & cfuncName &
          ", ctypes.c_void_p]"
      )
      gApiPyCallbackSetup.add(
        "_lib." & publicRegFuncName & ".restype = ctypes.c_uint64"
      )
      gApiPyCallbackSetup.add(
        "_lib." & publicDeregFuncName & ".argtypes = [ctypes.c_uint32, ctypes.c_uint64]"
      )
      gApiPyCallbackSetup.add("_lib." & publicDeregFuncName & ".restype = None")

    # Build Python callback parameter list and forwarding.
    # pyTrampolineParams: raw names matching CFUNCTYPE arg count
    #   (seq[T] fields expand to two names: foo + foo_count)
    # pyUserParams: one name per Nim field (for summary/callable hint)
    # pyDecodeLines: multi-line decode code emitted inside trampoline body
    # pyForwards: expressions forwarded to the Python callback
    var pyTrampolineParams: seq[string] = @[]
    var pyUserParams: seq[string] = @[]
    var pyDecodeLines: string = ""
    var pyForwards: seq[string] = @[]
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fName = $fieldNames[i]
        let snakeFname = toSnakeCase(fName)
        let fType = fieldTypes[i]
        pyUserParams.add(snakeFname)
        if isCStringType(fType):
          pyTrampolineParams.add(snakeFname)
          pyForwards.add(
            snakeFname & ".decode(\"utf-8\") if " & snakeFname & " else \"\""
          )
        elif isSeqType(fType):
          # CFUNCTYPE emits two args: pointer + count
          pyTrampolineParams.add(snakeFname)
          pyTrampolineParams.add(snakeFname & "_count")
          let elemName = seqItemTypeName(fType)
          let listVar = "_" & snakeFname & "_list"
          if elemName.toLowerAscii() in ["string", "cstring"]:
            pyDecodeLines.add("            " & listVar & ": list[str] = []\n")
            pyDecodeLines.add(
              "            if " & snakeFname & " and " & snakeFname & "_count > 0:\n"
            )
            pyDecodeLines.add(
              "                _str_arr = ctypes.cast(" & snakeFname &
                ", ctypes.POINTER(ctypes.c_char_p))\n"
            )
            pyDecodeLines.add(
              "                for _i in range(" & snakeFname & "_count):\n"
            )
            pyDecodeLines.add(
              "                    " & listVar &
                ".append(_str_arr[_i].decode('utf-8') if _str_arr[_i] else '')\n"
            )
          elif isNimPrimitive(elemName):
            let ctElem = nimTypeToCtypes(ident(elemName))
            pyDecodeLines.add("            " & listVar & " = []\n")
            pyDecodeLines.add(
              "            if " & snakeFname & " and " & snakeFname & "_count > 0:\n"
            )
            pyDecodeLines.add(
              "                _arr = ctypes.cast(" & snakeFname & ", ctypes.POINTER(" &
                ctElem & "))\n"
            )
            pyDecodeLines.add(
              "                for _i in range(" & snakeFname & "_count):\n"
            )
            pyDecodeLines.add("                    " & listVar & ".append(_arr[_i])\n")
          else:
            # seq[CustomObject]: cast to CItem*, reconstruct
            pyDecodeLines.add("            " & listVar & " = []\n")
            pyDecodeLines.add(
              "            if " & snakeFname & " and " & snakeFname & "_count > 0:\n"
            )
            pyDecodeLines.add(
              "                _arr = ctypes.cast(" & snakeFname & ", ctypes.POINTER(" &
                elemName & "CItem))\n"
            )
            pyDecodeLines.add(
              "                for _i in range(" & snakeFname & "_count):\n"
            )
            pyDecodeLines.add("                    " & listVar & ".append(_arr[_i])\n")
          pyForwards.add(listVar)
        elif isArrayTypeNode(fType):
          # C ABI: pointer + count (same layout as seq[primitive])
          pyTrampolineParams.add(snakeFname)
          pyTrampolineParams.add(snakeFname & "_count")
          let elemName = arrayNodeElemName(fType)
          let ctElem = nimTypeToCtypes(ident(elemName))
          let listVar = "_" & snakeFname & "_list"
          pyDecodeLines.add("            " & listVar & " = []\n")
          pyDecodeLines.add(
            "            if " & snakeFname & " and " & snakeFname & "_count > 0:\n"
          )
          pyDecodeLines.add(
            "                _arr = ctypes.cast(" & snakeFname & ", ctypes.POINTER(" &
              ctElem & "))\n"
          )
          pyDecodeLines.add(
            "                for _i in range(" & snakeFname & "_count):\n"
          )
          pyDecodeLines.add("                    " & listVar & ".append(_arr[_i])\n")
          pyForwards.add(listVar)
        elif isEnumRegistered($fType):
          # Wrap raw int with the Python IntEnum class
          pyTrampolineParams.add(snakeFname)
          pyForwards.add($fType & "(" & snakeFname & ")")
        else:
          pyTrampolineParams.add(snakeFname)
          pyForwards.add(snakeFname)

    let cfuncTypeName = "self._" & typeDisplayName & "CCallback"

    # Build specific Callable type hint from event fields.
    # Python callbacks are owner-aware like the C++ wrapper surface: the first
    # argument is the Mylib wrapper instance that owns the registration.
    var pyTypeHintParams: seq[string] = @["Mylib"]
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        pyTypeHintParams.add(nimTypeToPyAnnotation(fieldTypes[i]))
    let pyCallableHint = "Callable[[" & pyTypeHintParams.join(", ") & "], None]"
    var pySummaryParams: seq[string] = @[("owner")]
    pySummaryParams.add(pyUserParams)

    # on_<event> method
    block:
      let pyCamelEvent = "on" & typeDisplayName
      var m =
        "    def " & pyCamelEvent & "(self, callback: " & pyCallableHint & ") -> int:\n"
      m.add(
        "        \"\"\"Subscribe to " & typeDisplayName &
          " events.\n\n        The callback receives the owning Mylib instance as its first\n        argument instead of the raw ctx value so ownership stays at the\n        wrapper level while the C ABI details remain hidden. Returns a\n        handle for removal.\"\"\"\n"
      )
      m.add("        self._requireContext()\n")
      # Build the trampoline that decodes ABI values to Python types
      m.add("        @" & cfuncTypeName & "\n")
      var trampolineParams = @["_ctx", "_user_data"]
      trampolineParams.add(pyTrampolineParams)
      m.add("        def _trampoline(" & trampolineParams.join(", ") & "):\n")
      if pyDecodeLines.len > 0:
        m.add(pyDecodeLines)
      var pyCallbackInvokeArgs = @["self"]
      pyCallbackInvokeArgs.add(pyForwards)
      m.add("            callback(" & pyCallbackInvokeArgs.join(", ") & ")\n")
      m.add(
        "        handle = self._lib." & publicRegFuncName &
          "(self._ctx, _trampoline, None)\n"
      )
      m.add("        if handle == 0:\n")
      m.add("            raise __LIB_ERROR__(\"Failed to register event listener\")\n")
      m.add("        with self._lock:\n")
      m.add(
        "            self._cb_refs[(\"" & typeDisplayName &
          "\", handle)] = _trampoline\n"
      )
      m.add("        return handle\n\n")
      m.add(
        "    def on_" & pySnakeEvent & "(self, callback: " & pyCallableHint &
          ") -> int:\n"
      )
      m.add("        return self." & pyCamelEvent & "(callback)")
      gApiPyEventMethods.add(m)
      gApiPyInterfaceSummary.add(
        typeDisplayName & "Callback(" & pySummaryParams.join(", ") & ")"
      )
      gApiPyInterfaceSummary.add(pyCamelEvent & "(callback)")
      gApiPyInterfaceSummary.add("on_" & pySnakeEvent & "(callback)")

    # off_<event> method
    block:
      let pyCamelEvent = "off" & typeDisplayName
      var m = "    def " & pyCamelEvent & "(self, handle: int = 0) -> None:\n"
      m.add("        \"\"\"Unsubscribe from " & typeDisplayName & " events.\n\n")
      m.add("        Args:\n")
      m.add(
        "            handle: Listener handle from on_" & pySnakeEvent &
          "(). 0 removes all.\n"
      )
      m.add("        \"\"\"\n")
      m.add("        self._requireContext()\n")
      m.add("        self._lib." & publicDeregFuncName & "(self._ctx, handle)\n")
      m.add("        # Note: callback references are intentionally kept alive in\n")
      m.add("        # _cb_refs until shutdown(). The Nim delivery thread may still\n")
      m.add(
        "        # have in-flight event futures holding the raw function pointer;\n"
      )
      m.add(
        "        # releasing the ctypes object here could cause a use-after-free.\n\n"
      )
      m.add("    def off_" & pySnakeEvent & "(self, handle: int = 0) -> None:\n")
      m.add("        self." & pyCamelEvent & "(handle)")
      gApiPyEventMethods.add(m)
      gApiPyInterfaceSummary.add(pyCamelEvent & "(handle = 0)")
      gApiPyInterfaceSummary.add("off_" & pySnakeEvent & "(handle = 0)")

  # Step 12: Append to compile-time accumulators
  gApiEventHandlerEntries.add((typeId, handlerProcName))
  gApiEventCleanupProcNames.add(cleanupProcName)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
macro generateApiEventBrokerDeferred*(body: untyped): untyped =
  ## Deferred codegen macro. By the time this expands, any preceding
  ## `autoRegisterApiType` calls have already populated the type registry.
  generateApiEventBrokerImpl(body)

{.push raises: [].}

proc generateApiEventBroker*(body: NimNode): NimNode =
  ## Two-phase API event broker generation:
  ## 1. Emit `autoRegisterApiType` calls for external types (typed macro phase)
  ## 2. Emit deferred codegen macro that runs AFTER types are registered
  result = newStmtList()

  # Phase 1: auto-register external types
  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  # Phase 2: deferred codegen
  result.add(newCall(ident("generateApiEventBrokerDeferred"), copyNimTree(body)))

{.pop.}
