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

  # Step 2b: Emit foreign thread GC helper (once per compilation unit)
  result.add(emitEnsureForeignThreadGc())

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
  # Enum fields map to cint (int32) — Nim default-sized enums can be as narrow
  # as 1 byte; widening to cint matches the C/C++ enum (int) and Python c_int32.
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
          # ABI: enum params cross the FFI as cint (int32). The C/C++ header
          # declares the param as the enum typedef (int-sized in C) and the
          # Python CFUNCTYPE uses c_int32. A Nim default-sized enum can be as
          # narrow as 1 byte for ordinals 0..3, so without this widening Nim
          # would only write the low byte to the cdecl arg slot — the upper
          # bytes carry register garbage and the foreign side reads a corrupt
          # value (manifested as test_typed_scalar_event_enum failing).
          callbackFormal.add(
            newTree(
              nnkIdentDefs, copyNimTree(fieldNames[i]), ident("cint"), newEmptyNode()
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
            # On free: free string fields inside each CItem, then deallocShared
            # the outer array (encodeXToCItem allocates strings via allocCStringCopy).
            let itemFields = lookupFfiStruct(elemName)
            let cItemIdent = ident(elemName & "CItem")
            seqPtrCastType = newTree(nnkPtrTy, cItemIdent)
            let encodeFuncIdent = ident("encode" & elemName & "ToCItem")
            let arrVarIdent = genSym(nskLet, "arr_" & $fName)
            let iiVarIdent = genSym(nskForVar, "ii_" & $fName)

            var itemFreeStmts = newStmtList()
            for (ifName, ifType) in itemFields:
              if ifType.toLowerAscii() in ["string", "cstring"]:
                let ifNameIdent = ident(ifName)
                itemFreeStmts.add(
                  quote do:
                    if not `arrVarIdent`[`iiVarIdent`].`ifNameIdent`.isNil:
                      freeCString(`arrVarIdent`[`iiVarIdent`].`ifNameIdent`)
                )

            preCallStmts.add(
              quote do:
                let `countVarIdent` = cint(`evtParam`.`fName`.len)
                let `ptrVarIdent` =
                  if `countVarIdent` > 0:
                    let `arrVarIdent` = cast[ptr UncheckedArray[`cItemIdent`]](allocShared(
                      int(`countVarIdent`) * sizeof(`cItemIdent`)
                    ))
                    for `iiVarIdent` in 0 ..< int(`countVarIdent`):
                      `arrVarIdent`[`iiVarIdent`] =
                        `encodeFuncIdent`(`evtParam`.`fName`[`iiVarIdent`])
                    cast[pointer](`arrVarIdent`)
                  else:
                    nil
            )
            postCallStmts.add(
              quote do:
                if not `ptrVarIdent`.isNil:
                  let `arrVarIdent` =
                    cast[ptr UncheckedArray[`cItemIdent`]](`ptrVarIdent`)
                  for `iiVarIdent` in 0 ..< int(`countVarIdent`):
                    `itemFreeStmts`
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
          # Widen Nim's possibly-narrow enum field to cint to match the
          # foreign-side ABI (see callbackFormal above).
          callbackCallArgs.add(
            newCall(ident("cint"), newDotExpr(evtParam, copyNimTree(fName)))
          )
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
        ensureForeignThreadGc()
        let res = blockingRequest(
          RegisterEventListenerResult,
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
        ensureForeignThreadGc()
        if handle == 0'u64:
          # Remove all listeners for this event type
          discard blockingRequest(
            RegisterEventListenerResult,
            BrokerContext(ctx),
            2'i32,
            int32(`typeIdConst`),
            nil,
            nil,
            0'u64,
          )
        else:
          # Remove specific listener by handle
          discard blockingRequest(
            RegisterEventListenerResult,
            BrokerContext(ctx),
            1'i32,
            int32(`typeIdConst`),
            nil,
            nil,
            handle,
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
  # The detail::EventDispatcher template itself is emitted by api_codegen_cpp;
  # here we only flag that at least one event subscription exists.
  gApiCppEventDispatcherEmitted = true

  var cppCbParams: seq[string] = @[("Owner& owner")]
  var cTrampolineParams: seq[string] = @[]
  var traitInvokeArgs: seq[string] = @["owner"]
  # Setup statements emitted inside `invoke()` BEFORE the `fn(...)` call —
  # used to materialise non-owning views (e.g. building a
  # std::vector<std::string_view> from `const char** + count` for
  # seq[string] event params). Kept lifetime-bound to the call so the span
  # the user receives stays valid throughout.
  var traitInvokePreamble = ""
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = $fieldNames[i]
      let fType = fieldTypes[i]
      if isSeqOfStringNode(fType):
        # Public C++ callback receives std::span<const std::string_view> —
        # zero-copy parity with the CBOR-mode wrapper. Trampoline still
        # takes the raw `const char** + count` C ABI; we materialise a
        # temporary vector<string_view> in `invoke()` and pass a span
        # over it to the user callback.
        cppCbParams.add("std::span<const std::string_view> " & fName)
        cTrampolineParams.add("const char** " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        let viewVar = fName & "_view"
        traitInvokePreamble.add(
          "        std::vector<std::string_view> " & viewVar & ";\n" & "        if (" &
            fName & " && " & fName & "_count > 0) {\n" & "            " & viewVar &
            ".reserve(" & fName & "_count);\n" & "            for (int32_t i = 0; i < " &
            fName & "_count; ++i)\n" & "                " & viewVar & ".emplace_back(\n" &
            "                    " & fName & "[i] ? std::string_view(" & fName &
            "[i]) : std::string_view());\n" & "        }\n"
        )
        traitInvokeArgs.add("std::span<const std::string_view>(" & viewVar & ")")
      elif isSeqOfPrimitiveNode(fType):
        let elemName = seqItemTypeName(fType)
        let cppElemType = nimTypeToCpp(ident(elemName))
        let cElemType = nimTypeToCSuffix(ident(elemName))
        cppCbParams.add("std::span<const " & cppElemType & "> " & fName)
        cTrampolineParams.add("const " & cElemType & "* " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        traitInvokeArgs.add(
          "std::span<const " & cppElemType & ">(" & fName & ", " & fName & "_count)"
        )
      elif isSeqType(fType):
        # Public C++ callback receives `std::span<const Item>` (parity
        # with CBOR-mode wrapper). Trampoline still receives the raw
        # `ItemCItem* + count` C ABI; we materialise a temporary
        # `std::vector<Item>` in the invoke preamble via the per-type
        # `detail::adopt<Item>(CItem)` helper, then pass a span over
        # it. Per-event O(N) string-copy cost (same as the CBOR
        # decoded vector path); kept lifetime-bound to the callback.
        let itemTypeName = seqItemTypeName(fType)
        cppCbParams.add("std::span<const " & itemTypeName & "> " & fName)
        cTrampolineParams.add(itemTypeName & "CItem* " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        let viewVar = fName & "_view"
        traitInvokePreamble.add(
          "        std::vector<" & itemTypeName & "> " & viewVar & ";\n" & "        if (" &
            fName & " && " & fName & "_count > 0) {\n" & "            " & viewVar &
            ".reserve(" & fName & "_count);\n" & "            for (int32_t i = 0; i < " &
            fName & "_count; ++i)\n" & "                " & viewVar &
            ".emplace_back(adopt" & itemTypeName & "(" & fName & "[i]));\n" &
            "        }\n"
        )
        traitInvokeArgs.add("std::span<const " & itemTypeName & ">(" & viewVar & ")")
      elif isArrayTypeNode(fType):
        let elemName = arrayNodeElemName(fType)
        let cppElemType = nimTypeToCpp(ident(elemName))
        let cElemType = nimTypeToCSuffix(ident(elemName))
        cppCbParams.add("std::span<const " & cppElemType & "> " & fName)
        cTrampolineParams.add("const " & cElemType & "* " & fName)
        cTrampolineParams.add("int32_t " & fName & "_count")
        traitInvokeArgs.add(
          "std::span<const " & cppElemType & ">(" & fName & ", " & fName & "_count)"
        )
      elif isEnumRegistered($fType):
        # Public C++ callback receives the C++ `enum class <Name>` (in
        # namespace). C trampoline signature uses `::<Name>_C` (the C
        # typedef-enum at global scope, suffixed by codegen to avoid
        # the namespace collision). `invoke` static_casts between the
        # two — both have int32_t underlying so the cast is a no-op
        # at runtime.
        let enumTypeName = $fType
        cppCbParams.add(enumTypeName & " " & fName)
        cTrampolineParams.add("::" & enumTypeName & "_C " & fName)
        traitInvokeArgs.add("static_cast<" & enumTypeName & ">(" & fName & ")")
      else:
        let cbType = nimTypeToCppCallbackParam(fType)
        let cType = nimTypeToCInput(fType)
        cppCbParams.add(cbType & " " & fName)
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
  if traitInvokePreamble.len > 0:
    trait.add(traitInvokePreamble)
  trait.add("        try {\n")
  trait.add("            fn(" & traitInvokeArgs.join(", ") & ");\n")
  trait.add("        } catch (...) {\n")
  trait.add("        }\n")
  trait.add("    }\n")
  trait.add("};")

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
        # Qualify with `::` and the `_C` suffix so the EventDispatcher
        # template instantiation uses the C typedef-enum (global scope,
        # suffix-renamed to avoid namespace collision with the C++ enum
        # class).
        cArgTypes.add("::" & $fType & "_C")
      else:
        cArgTypes.add(nimTypeToCInput(fType))

  # detail:: forward decl of the trait, full definition emitted after class.
  gApiCppDetailForwardDecls.add("struct " & traitName & ";")
  gApiCppDetailTraits.add(trait)

  # Public callback alias is an inlined std::function<void(Mylib&, …)> — no
  # dependency on detail traits, so the class header stays self-contained.
  var publicCbParams: seq[string] = @[]
  for p in cppCbParams:
    publicCbParams.add(p.replace("Owner&", "__CPP_CLASS__&"))
  let callbackAlias = typeDisplayName & "Callback"

  let dispField = toSnakeCase(typeDisplayName) & "Dispatcher_"

  # Class private members: dispatcher type alias + unique_ptr field.
  var aliasDecl =
    "    using " & dispatcherAlias & " = detail::EventDispatcher<__CPP_CLASS__, detail::" &
    traitName
  if cArgTypes.len > 0:
    aliasDecl.add(", " & cArgTypes.join(", "))
  aliasDecl.add(">;")
  gApiCppPrivateMembers.add(aliasDecl)
  gApiCppPrivateMembers.add(
    "    std::unique_ptr<" & dispatcherAlias & "> " & dispField & ";"
  )

  # ctor / shutdown plumbing — now operates on a unique_ptr.
  gApiCppConstructorInitializers.add(
    dispField & "(std::make_unique<" & dispatcherAlias & ">(*this))"
  )
  gApiCppShutdownStatements.add("if (" & dispField & ") " & dispField & "->clear();")

  # Public callback alias + on/off declarations inside the class.
  gApiCppMethodDecls.add(
    "using " & callbackAlias & " = std::function<void(" & publicCbParams.join(", ") &
      ")>;"
  )
  gApiCppMethodDecls.add(
    "uint64_t on" & typeDisplayName & "(" & callbackAlias & " fn) noexcept;"
  )
  gApiCppMethodDecls.add(
    "void off" & typeDisplayName & "(uint64_t handle = 0) noexcept;"
  )

  # on / off inline definitions
  var onDef =
    "inline uint64_t __CPP_CLASS__::on" & typeDisplayName & "(" & callbackAlias &
    " fn) noexcept {\n"
  onDef.add("    return " & dispField & "->add(std::move(fn));\n")
  onDef.add("}")
  gApiCppMethodDefs.add(onDef)

  var offDef =
    "inline void __CPP_CLASS__::off" & typeDisplayName & "(uint64_t handle) noexcept {\n"
  offDef.add("    if (handle == 0) {\n")
  offDef.add("        " & dispField & "->clear();\n")
  offDef.add("    } else {\n")
  offDef.add("        " & dispField & "->remove(handle);\n")
  offDef.add("    }\n")
  offDef.add("}")
  gApiCppMethodDefs.add(offDef)

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
  gApiEventProcessLoopShutdownProcNames.add(
    "shutdownProcessLoopsForCtx" & typeDisplayName
  )

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
  ##    and `registerArraySizeConst` calls for array-size const idents
  ## 2. Emit deferred codegen macro that runs AFTER registrations complete
  result = newStmtList()

  # Phase 1a: auto-register external types
  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  # Phase 1b: pre-resolve const idents used as array sizes
  let sizeIdents = discoverArraySizeIdents(body)
  if sizeIdents.len > 0:
    result.add(emitArraySizeRegistrations(sizeIdents))

  # Phase 2: deferred codegen
  result.add(newCall(ident("generateApiEventBrokerDeferred"), copyNimTree(body)))

{.pop.}
