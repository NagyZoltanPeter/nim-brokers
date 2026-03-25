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
    callbackFormal.add(
      newTree(nnkIdentDefs, ident("ctx"), ident("uint32"), newEmptyNode())
    )
    callbackFormal.add(
      newTree(nnkIdentDefs, ident("userData"), ident("pointer"), newEmptyNode())
    )
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
    callbackFormal.add(
      newTree(nnkIdentDefs, ident("ctx"), ident("uint32"), newEmptyNode())
    )
    callbackFormal.add(
      newTree(nnkIdentDefs, ident("userData"), ident("pointer"), newEmptyNode())
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

  var cppCbParams: seq[string] = @["Owner& owner"]
  var cTrampolineParams: seq[string] = @[]
  var traitInvokeArgs: seq[string] = @["owner"]
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fName = $fieldNames[i]
      let cbType = nimTypeToCppCallbackParam(fieldTypes[i])
      let cType = nimTypeToCInput(fieldTypes[i])
      cppCbParams.add(cbType & " " & fName)
      cTrampolineParams.add(cType & " " & fName)
      if isCStringType(fieldTypes[i]):
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
      cArgTypes.add(nimTypeToCInput(fieldTypes[i]))

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

  var onMethod =
    "uint64_t on" & typeDisplayName & "(" & typeDisplayName & "Callback fn) noexcept {\n"
  onMethod.add(
    "        return " & toSnakeCase(typeDisplayName) &
      "Dispatcher_.add(std::move(fn));\n"
  )
  onMethod.add("    }")
  gApiCppClassMethods.add(onMethod)

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
      var trampolineParams = @["_ctx", "_user_data"]
      trampolineParams.add(pyCallbackParams)
      m.add("        def _trampoline(" & trampolineParams.join(", ") & "):\n")
      m.add("            callback(" & pyForwards.join(", ") & ")\n")
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

  # Step 12: Append to compile-time accumulators
  gApiEventHandlerEntries.add((typeId, handlerProcName))
  gApiEventCleanupProcNames.add(cleanupProcName)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
