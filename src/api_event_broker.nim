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
  ##     proc signature*(
  ##         action: int32,
  ##         eventTypeId: int32,
  ##         callbackPtr: pointer,
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
                  ident("allocSharedCString"), newDotExpr(evtParam, copyNimTree(fName))
                ),
              ),
            )
          )
          callbackCallArgs.add(cVarIdent)
          postCallStmts.add(newCall(ident("freeSharedCString"), cVarIdent))
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
            ctx: BrokerContext, callbackPtr: pointer
        ): Result[RegisterEventListenerResult, string] =
          let `cbLocal` = cast[`callbackTypeIdent`](callbackPtr)
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
            listenerHandle: uint64,
        ): Future[Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
          case action
          of 0:
            return `registerHelperIdent`(ctx, callbackPtr)
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
          0'u64,
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
            BrokerContext(ctx), 2'i32, int32(`typeIdConst`), nil, 0'u64
          )
        else:
          # Remove specific listener by handle
          discard waitFor RegisterEventListenerResult.request(
            BrokerContext(ctx), 1'i32, int32(`typeIdConst`), nil, handle
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

  # C++ wrapper: trampoline + multiplexed std::function callbacks
  # Build the std::function signature from event fields
  var cppCbParams: seq[string] = @[]
  var cppTrampolineForwards: seq[string] = @[]
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = $fieldNames[i]
      let cbType = nimTypeToCppCallbackParam(fieldTypes[i])
      cppCbParams.add(cbType)
      # Trampoline converts const char* → std::string_view (const in signature, not ctor)
      if isCStringType(fieldTypes[i]):
        cppTrampolineForwards.add(
          "std::string_view(" & fName & " ? " & fName & " : \"\")"
        )
      else:
        cppTrampolineForwards.add(fName)

  let cppFuncType = "std::function<void(" & cppCbParams.join(", ") & ")>"
  let prefix = "s" & typeDisplayName

  # Build C callback param list for the trampoline signature
  var cTrampolineParams: seq[string] = @[]
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = $fieldNames[i]
      let cType = nimTypeToCInput(fieldTypes[i])
      cTrampolineParams.add(cType & " " & fName)

  # Private static members
  var priv = ""
  priv.add("    // --- " & typeDisplayName & " event callback storage ---\n")
  priv.add("    static inline std::mutex " & prefix & "Mtx_;\n")
  priv.add(
    "    static inline std::unordered_map<uint64_t, " & cppFuncType & "> " & prefix &
      "Cbs_;\n"
  )
  priv.add(
    "    static inline uint64_t " & prefix &
      "CHandle_ = 0; // C-layer trampoline handle\n"
  )
  priv.add("    static inline std::atomic<uint64_t> " & prefix & "NextId_{1};\n")
  # Trampoline function
  priv.add(
    "    static void " & prefix & "Trampoline_(" & cTrampolineParams.join(", ") & ") {\n"
  )
  priv.add("        std::lock_guard<std::mutex> lock(" & prefix & "Mtx_);\n")
  priv.add("        for (auto& [id, fn] : " & prefix & "Cbs_) {\n")
  priv.add("            if (fn) fn(" & cppTrampolineForwards.join(", ") & ");\n")
  priv.add("        }\n")
  priv.add("    }\n")
  gApiCppPrivateMembers.add(priv)

  # Public on/off methods
  var onMethod = "uint64_t on" & typeDisplayName & "(" & cppFuncType & " fn) {\n"
  onMethod.add("        std::lock_guard<std::mutex> lock(" & prefix & "Mtx_);\n")
  onMethod.add("        // Register C trampoline once with the Nim layer\n")
  onMethod.add("        if (" & prefix & "CHandle_ == 0) {\n")
  onMethod.add(
    "            " & prefix & "CHandle_ = ::" & regFuncName & "(ctx_, " & prefix &
      "Trampoline_);\n"
  )
  onMethod.add("        }\n")
  onMethod.add("        uint64_t id = " & prefix & "NextId_.fetch_add(1);\n")
  onMethod.add("        " & prefix & "Cbs_[id] = std::move(fn);\n")
  onMethod.add("        return id;\n")
  onMethod.add("    }")
  gApiCppClassMethods.add(onMethod)

  var offMethod = "void off" & typeDisplayName & "(uint64_t handle = 0) {\n"
  offMethod.add("        std::lock_guard<std::mutex> lock(" & prefix & "Mtx_);\n")
  offMethod.add("        if (handle == 0) {\n")
  offMethod.add("            // Remove all\n")
  offMethod.add("            " & prefix & "Cbs_.clear();\n")
  offMethod.add("            if (" & prefix & "CHandle_) {\n")
  offMethod.add(
    "                ::" & deregFuncName & "(ctx_, " & prefix & "CHandle_);\n"
  )
  offMethod.add("                " & prefix & "CHandle_ = 0;\n")
  offMethod.add("            }\n")
  offMethod.add("        } else {\n")
  offMethod.add("            " & prefix & "Cbs_.erase(handle);\n")
  offMethod.add(
    "            if (" & prefix & "Cbs_.empty() && " & prefix & "CHandle_) {\n"
  )
  offMethod.add(
    "                ::" & deregFuncName & "(ctx_, " & prefix & "CHandle_);\n"
  )
  offMethod.add("                " & prefix & "CHandle_ = 0;\n")
  offMethod.add("            }\n")
  offMethod.add("        }\n")
  offMethod.add("    }")
  gApiCppClassMethods.add(offMethod)

  # Step 11: Generate Python on/off event methods (when -d:BrokerFfiApiGenPy)
  when defined(BrokerFfiApiGenPy):
    let pySnakeEvent = toSnakeCase(typeDisplayName)

    # CFUNCTYPE definition + argtypes/restype setup
    # Store CFUNCTYPE as instance attribute (self._XxxCCallback) for use in methods
    block:
      var cfuncArgs: seq[string] = @[]
      cfuncArgs.add("None") # return type
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          cfuncArgs.add(nimTypeToCtypes(fieldTypes[i]))

      let cfuncName = "self._" & typeDisplayName & "CCallback"
      gApiPyCallbackSetup.add(
        cfuncName & " = ctypes.CFUNCTYPE(" & cfuncArgs.join(", ") & ")"
      )
      gApiPyCallbackSetup.add(
        "_lib." & regFuncName & ".argtypes = [ctypes.c_uint32, " & cfuncName & "]"
      )
      gApiPyCallbackSetup.add("_lib." & regFuncName & ".restype = ctypes.c_uint64")
      gApiPyCallbackSetup.add(
        "_lib." & deregFuncName & ".argtypes = [ctypes.c_uint32, ctypes.c_uint64]"
      )
      gApiPyCallbackSetup.add("_lib." & deregFuncName & ".restype = None")

    # Build Python callback parameter list and forwarding
    var pyCallbackParams: seq[string] = @[]
    var pyForwards: seq[string] = @[]
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fName = $fieldNames[i]
        let snakeFname = toSnakeCase(fName)
        pyCallbackParams.add(snakeFname)
        if isCStringType(fieldTypes[i]):
          pyForwards.add(
            snakeFname & ".decode(\"utf-8\") if " & snakeFname & " else \"\""
          )
        else:
          pyForwards.add(snakeFname)

    let cfuncTypeName = "self._" & typeDisplayName & "CCallback"

    # Build specific Callable type hint from event fields
    # e.g. Callable[[int, str, str, str], None]
    var pyTypeHintParams: seq[string] = @[]
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        pyTypeHintParams.add(nimTypeToPyAnnotation(fieldTypes[i]))
    let pyCallableHint = "Callable[[" & pyTypeHintParams.join(", ") & "], None]"

    # on_<event> method
    block:
      let pyCamelEvent = "on" & typeDisplayName
      var m =
        "    def " & pyCamelEvent & "(self, callback: " & pyCallableHint & ") -> int:\n"
      m.add(
        "        \"\"\"Subscribe to " & typeDisplayName &
          " events. Returns a handle for removal.\"\"\"\n"
      )
      m.add("        self._requireContext()\n")
      # Build the trampoline that decodes strings
      m.add("        @" & cfuncTypeName & "\n")
      m.add("        def _trampoline(" & pyCallbackParams.join(", ") & "):\n")
      m.add("            callback(" & pyForwards.join(", ") & ")\n")
      m.add("        handle = self._lib." & regFuncName & "(self._ctx, _trampoline)\n")
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
      m.add("        self._lib." & deregFuncName & "(self._ctx, handle)\n")
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

  # Step 12: Append to compile-time accumulators
  gApiEventHandlerEntries.add((typeId, handlerProcName))
  gApiEventCleanupProcNames.add(cleanupProcName)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
