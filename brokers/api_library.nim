## API Library Registration
## ------------------------
## Provides the `registerBrokerLibrary` macro that generates:
## 1. Library context lifecycle management (createContext/shutdown C exports)
## 2. Compile-time validation of mandatory InitializeRequest/ShutdownRequest types
## 3. C header file generation from accumulated broker declarations
## 4. Memory management helpers (free_string)
## 5. Delivery thread creation (hosts event listeners, calls C callbacks)
## 6. Aggregate event listener provider (dispatches by typeId)
## 7. Aggregate cleanup (removes all listeners on shutdown)
##
## Usage:
## ```nim
## registerBrokerLibrary:
##   name: "mylib"
##   initializeRequest: InitializeRequest
##   shutdownRequest: ShutdownRequest
##   refType: MyLibObject  # optional
## ```
##
## The `registerBrokerLibrary` macro MUST appear after all `EventBroker(API)`
## and `RequestBroker(API)` declarations in the source file.

{.push raises: [].}

import std/[atomics, locks, macros, os, strutils, tables]
import chronos, chronicles
import results
import ./broker_context, ./internal/api_common
import ./internal/api_codegen_cbor_h
import ./internal/api_codegen_cbor_hpp

export results, chronos, chronicles, broker_context, api_common

# ---------------------------------------------------------------------------
# Macro helpers
# ---------------------------------------------------------------------------

proc parseLibraryConfig(
    body: NimNode
): tuple[
  name: string,
  initializeRequest: NimNode,
  shutdownRequest: NimNode,
  refType: NimNode,
  ffiMode: BrokerFfiMode,
  ffiModeExplicit: bool,
] {.compileTime.} =
  var name = ""
  var initializeReq: NimNode = nil
  var shutdownReq: NimNode = nil
  var refTy: NimNode = nil
  var ffiMode = mfCbor
  var ffiModeExplicit = false

  for stmt in body:
    if stmt.kind == nnkCall and stmt.len == 2:
      let key = $stmt[0]
      let value = stmt[1]
      case key.toLowerAscii()
      of "name":
        if value.kind == nnkStmtList and value.len == 1:
          name = value[0].strVal
        elif value.kind == nnkStrLit:
          name = value.strVal
        else:
          error("name must be a string literal", value)
      of "initializerequest":
        if value.kind == nnkStmtList and value.len == 1:
          initializeReq = value[0]
        else:
          initializeReq = value
      of "shutdownrequest", "destroyrequest":
        if value.kind == nnkStmtList and value.len == 1:
          shutdownReq = value[0]
        else:
          shutdownReq = value
      of "reftype":
        if value.kind == nnkStmtList and value.len == 1:
          refTy = value[0]
        else:
          refTy = value
      of "ffimode":
        var modeNode = value
        if modeNode.kind == nnkStmtList and modeNode.len == 1:
          modeNode = modeNode[0]
        var modeText = ""
        case modeNode.kind
        of nnkStrLit:
          modeText = modeNode.strVal
        of nnkIdent, nnkSym:
          modeText = $modeNode
        else:
          error(
            "ffiMode must be the identifier or string literal `cbor` or `native`",
            modeNode,
          )
        ffiMode = parseFfiModeLiteral(modeText)
        ffiModeExplicit = true
      else:
        error("Unknown registerBrokerLibrary key: " & key, stmt)
    else:
      error("registerBrokerLibrary expects key: value pairs", stmt)

  if name.len == 0:
    error("registerBrokerLibrary requires a 'name' field", body)
  if initializeReq.isNil():
    error("registerBrokerLibrary requires a 'initializeRequest' field", body)
  if shutdownReq.isNil():
    error(
      "registerBrokerLibrary requires a 'shutdownRequest' field (the legacy 'destroyRequest' alias is still accepted)",
      body,
    )

  (
    name: name,
    initializeRequest: initializeReq,
    shutdownRequest: shutdownReq,
    refType: refTy,
    ffiMode: ffiMode,
    ffiModeExplicit: ffiModeExplicit,
  )

proc parseTypeExpr(
    exprText: string, context: NimNode
): NimNode {.compileTime, raises: [].} =
  try:
    parseExpr(exprText)
  except ValueError as exc:
    error(
      "Failed to parse generated type expression '" & exprText & "': " & exc.msg,
      context,
    )

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------

proc registerBrokerLibraryNativeImpl(
  body: NimNode,
  config:
    tuple[
      name: string,
      initializeRequest: NimNode,
      shutdownRequest: NimNode,
      refType: NimNode,
      ffiMode: BrokerFfiMode,
      ffiModeExplicit: bool,
    ],
): NimNode

proc registerBrokerLibraryCborImpl(
  body: NimNode,
  config:
    tuple[
      name: string,
      initializeRequest: NimNode,
      shutdownRequest: NimNode,
      refType: NimNode,
      ffiMode: BrokerFfiMode,
      ffiModeExplicit: bool,
    ],
): NimNode

proc registerBrokerLibraryImpl(body: NimNode): NimNode =
  let config = parseLibraryConfig(body)

  # Resolve FFI mode (compile flag-driven; config field is a consistency check).
  let resolvedMode = resolveFfiMode(config.ffiMode, config.ffiModeExplicit, config.name)

  case resolvedMode
  of mfNative:
    registerBrokerLibraryNativeImpl(body, config)
  of mfCbor:
    registerBrokerLibraryCborImpl(body, config)

proc registerBrokerLibraryNativeImpl(
    body: NimNode,
    config:
      tuple[
        name: string,
        initializeRequest: NimNode,
        shutdownRequest: NimNode,
        refType: NimNode,
        ffiMode: BrokerFfiMode,
        ffiModeExplicit: bool,
      ],
): NimNode =
  let libName = config.name
  let libNameLit = newLit(libName)
  let initializeReqIdent = config.initializeRequest
  let shutdownReqIdent = config.shutdownRequest

  # Set library name for header generation
  gApiLibraryName = libName

  let createContextFuncName = libName & "_createContext"
  let shutdownFuncName = libName & "_shutdown"
  let freeStringFuncName = libName & "_free_string"
  let freeCreateContextResultFuncName = "free_" & libName & "_create_context_result"

  let createContextFuncIdent = ident(createContextFuncName)
  let shutdownFuncIdent = ident(shutdownFuncName)
  let freeStringFuncIdent = ident(freeStringFuncName)
  let freeCreateContextResultFuncIdent = ident(freeCreateContextResultFuncName)

  let createContextFuncNameLit = newLit(createContextFuncName)
  let shutdownFuncNameLit = newLit(shutdownFuncName)
  let freeStringFuncNameLit = newLit(freeStringFuncName)
  let freeCreateContextResultFuncNameLit = newLit(freeCreateContextResultFuncName)

  # Processing thread identifiers
  let procThreadArgIdent = ident(libName & "ProcThreadArg")
  let procThreadProcIdent = ident(libName & "ProcessingThread")

  # Delivery thread identifiers
  let delivThreadArgIdent = ident(libName & "DelivThreadArg")
  let delivThreadProcIdent = ident(libName & "DeliveryThread")

  # Context entry
  let ctxEntryIdent = ident(libName & "CtxEntry")
  let globalCtxsIdent = ident("g" & libName & "Ctxs")
  let globalCtxsLockIdent = ident("g" & libName & "CtxsLock")
  let globalCtxsInitIdent = ident("g" & libName & "CtxsInit")
  let startupStateIdent = ident(libName & "StartupState")
  let waitForStartupProcIdent = ident("waitFor" & libName & "Startup")

  result = newStmtList()

  # Emit foreign thread GC helper (once per compilation unit — safe if already
  # emitted by a broker macro, the flag in api_common prevents duplicates).
  result.add(emitEnsureForeignThreadGc())

  # Compile-time validation: ensure InitializeRequest and ShutdownRequest types exist
  result.add(
    quote do:
      when not compiles(typeof(`initializeReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: initializeRequest type '" &
            astToStr(`initializeReqIdent`) &
            "' is not defined. Ensure a RequestBroker(API) declaring this type " &
            "appears before registerBrokerLibrary."
        .}
      when not compiles(typeof(`shutdownReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: shutdownRequest type '" &
            astToStr(`shutdownReqIdent`) &
            "' is not defined. Ensure a RequestBroker(API) declaring this type " &
            "appears before registerBrokerLibrary."
        .}
  )

  # Thread argument and context entry types
  result.add(
    quote do:
      type
        `startupStateIdent` = object
          deliveryReady: Atomic[int]
          processingReady: Atomic[int]
          deliveryErrorMessage: cstring
          processingErrorMessage: cstring

        `procThreadArgIdent` = object
          ctx: BrokerContext
          shutdownFlag: Atomic[int]
          startupState: ptr `startupStateIdent`

        `delivThreadArgIdent` = object
          ctx: BrokerContext
          shutdownFlag: Atomic[int]
          startupState: ptr `startupStateIdent`

        `ctxEntryIdent` = object
          ctx: BrokerContext
          procThread: Thread[ptr `procThreadArgIdent`]
          delivThread: Thread[ptr `delivThreadArgIdent`]
          procArg: ptr `procThreadArgIdent`
          delivArg: ptr `delivThreadArgIdent`
          active: bool

  )

  # Library initialization — must be called exactly once from the C/C++ app
  # before any other library functions. Initializes the Nim runtime, sets up
  # the GC for the foreign (C/C++) calling thread, and configures the stack bottom.
  let initLibFuncName = libName & "_initialize"
  let initLibFuncIdent = ident(initLibFuncName)
  let nimInitializedIdent = ident("g" & libName & "NimInitialized")
  let gcRegisteredIdent = ident("g" & libName & "GcRegistered")
  let nimMainIdent = ident(libName & "NimMain")
  let createContextResultIdent = ident(libName & "CreateContextResult")
  let exportedCreateContextResultIdent =
    postfix(copyNimTree(createContextResultIdent), "*")

  # Emit the NimMain import declaration (POSIX only).
  #
  # On POSIX with --nimMainPrefix:<libname>, DLL init code calls
  # <libname>NimMain, so we import it by its prefixed name and call it
  # ourselves in _initialize to guarantee the runtime is ready before any
  # Nim code runs on a foreign thread.
  #
  # On Windows, --nimMainPrefix is not used (LLVM/clang hard-errors on the
  # dllexport attribute mismatch in the generated forward decl vs definition).
  # Windows DLLs get a DllMain generated by Nim's cgen that calls NimMain()
  # during DLL_PROCESS_ATTACH — before LoadLibrary returns, and therefore
  # before any exported function can be invoked.  So the runtime is already
  # initialized by the time _initialize is called; we simply skip the
  # NimMain call on Windows.
  when not defined(windows):
    let nimMainImportName = newLit(libName & "NimMain")
    result.add(
      quote do:
        proc `nimMainIdent`() {.importc: `nimMainImportName`, cdecl.}
    )

  result.add(
    quote do:
      var `nimInitializedIdent`: Atomic[int]
      var `gcRegisteredIdent` {.threadvar.}: bool

      proc `initLibFuncIdent`(): Result[void, string] =
        # Step 1: One-time process-wide Nim runtime initialization
        while true:
          case `nimInitializedIdent`.load(moAcquire)
          of 2:
            break
          of -1:
            return err("Failed to initialize Nim runtime")
          of 1:
            sleep(1)
          else:
            var expected = 0
            if `nimInitializedIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
              # On Windows the Nim runtime is already initialized by the
              # DllMain that Nim's codegen emits (called during DLL_PROCESS_ATTACH,
              # before LoadLibrary returns).  On POSIX there is no equivalent
              # automatic init, so we call <libname>NimMain explicitly here.
              when compileOption("app", "lib") and not defined(windows):
                let initRes = catch:
                  `nimMainIdent`()
                if initRes.isErr():
                  error "Failed to initialize Nim runtime",
                    library = `libNameLit`, detail = initRes.error.msg
                  `nimInitializedIdent`.store(-1, moRelease)
                  return err("Failed to initialize Nim runtime")

              `nimInitializedIdent`.store(2, moRelease)
              break

        # Step 2: Per-thread foreign thread GC registration
        when compileOption("app", "lib"):
          if not `gcRegisteredIdent`:
            when declared(setupForeignThreadGc):
              setupForeignThreadGc()
            `gcRegisteredIdent` = true
          when declared(nimGC_setStackBottom):
            var locals {.volatile, noinit.}: pointer
            locals = addr(locals)
            nimGC_setStackBottom(locals)

        return ok()

      type `exportedCreateContextResultIdent` {.exportc.} = object
        ctx*: uint32
        error_message*: cstring

      proc `freeCreateContextResultFuncIdent`(
          r: ptr `createContextResultIdent`
      ) {.exportc: `freeCreateContextResultFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if r.isNil:
          return
        if not r.error_message.isNil:
          freeCString(r.error_message)
          r.error_message = nil

  )

  # Global context registry (stores pointers to heap-allocated entries
  # because Thread objects must not be moved after createThread)
  result.add(
    quote do:
      var `globalCtxsIdent`: seq[ptr `ctxEntryIdent`]
      var `globalCtxsLockIdent`: Lock
      var `globalCtxsInitIdent`: Atomic[int]

      proc ensureLibCtxInit(): Result[void, string] =
        let initRes = `initLibFuncIdent`()
        if initRes.isErr():
          return err(initRes.error())
        if `globalCtxsInitIdent`.load(moRelaxed) == 2:
          return ok()
        var expected = 0
        if `globalCtxsInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          initLock(`globalCtxsLockIdent`)
          `globalCtxsIdent` = @[]
          `globalCtxsInitIdent`.store(2, moRelease)
        else:
          while `globalCtxsInitIdent`.load(moAcquire) != 2:
            sleep(1)
        ok()

      proc cleanupStartupState(startupState: ptr `startupStateIdent`) =
        if startupState.isNil:
          return
        if not startupState.deliveryErrorMessage.isNil:
          freeCString(startupState.deliveryErrorMessage)
          startupState.deliveryErrorMessage = nil
        if not startupState.processingErrorMessage.isNil:
          freeCString(startupState.processingErrorMessage)
          startupState.processingErrorMessage = nil
        deallocShared(startupState)

      proc releaseCtxEntryResources(entryPtr: ptr `ctxEntryIdent`) =
        if entryPtr.isNil:
          return

        if not entryPtr.procArg.isNil:
          deallocShared(entryPtr.procArg)

        if not entryPtr.delivArg.isNil:
          deallocShared(entryPtr.delivArg)

        deallocShared(entryPtr)

      proc releaseCreateContextResources(
          startupState: ptr `startupStateIdent`,
          procArg: ptr `procThreadArgIdent`,
          delivArg: ptr `delivThreadArgIdent`,
          entryPtr: ptr `ctxEntryIdent`,
      ) =
        cleanupStartupState(startupState)
        if not entryPtr.isNil:
          releaseCtxEntryResources(entryPtr)
          return
        if not procArg.isNil:
          deallocShared(procArg)
        if not delivArg.isNil:
          deallocShared(delivArg)

      proc recordStartupFailure(
          startupFlag: ptr Atomic[int],
          errorMessage: ptr cstring,
          stage: string,
          detail: string,
      ) =
        error "Library context startup failed",
          library = `libNameLit`, stage = stage, detail = detail
        if not errorMessage[].isNil:
          freeCString(errorMessage[])
        errorMessage[] = allocCStringCopy(detail)
        startupFlag[].store(-1, moRelease)

  )

  # Generate aggregate event listener provider installer
  # This proc installs the single RegisterEventListenerResult provider
  # that dispatches by eventTypeId to per-type handler procs.
  let installProviderIdent = ident("installEventListenerProvider")

  if gApiEventHandlerEntries.len > 0:
    let provCtxIdent = genSym(nskParam, "ctx")

    # Build case statement branches (use literal int values, not ident refs,
    # because ident refs to constants can fail inside async closures)
    var caseStmt = newTree(nnkCaseStmt, ident("eventTypeId"))
    for (typeIdValue, handlerProcName) in gApiEventHandlerEntries:
      let branch = newTree(
        nnkOfBranch,
        newLit(int32(typeIdValue)),
        newStmtList(
          newTree(
            nnkReturnStmt,
            newCall(
              ident("await"),
              newCall(
                ident(handlerProcName),
                provCtxIdent,
                ident("action"),
                ident("callbackPtr"),
                ident("userData"),
                ident("listenerHandle"),
              ),
            ),
          )
        ),
      )
      caseStmt.add(branch)

    # else branch
    caseStmt.add(
      newTree(
        nnkElse,
        newStmtList(
          newTree(
            nnkReturnStmt,
            newCall(
              ident("err"),
              newTree(
                nnkInfix,
                ident("&"),
                newLit("Unknown event type: "),
                newCall(ident("$"), ident("eventTypeId")),
              ),
            ),
          )
        ),
      )
    )

    # Build provider closure
    let closureBody = newStmtList(caseStmt)

    let closureFormalParams = newTree(
      nnkFormalParams,
      newTree(
        nnkBracketExpr,
        ident("Future"),
        newTree(
          nnkBracketExpr,
          ident("Result"),
          ident("RegisterEventListenerResult"),
          ident("string"),
        ),
      ),
      newTree(nnkIdentDefs, ident("action"), ident("int32"), newEmptyNode()),
      newTree(nnkIdentDefs, ident("eventTypeId"), ident("int32"), newEmptyNode()),
      newTree(nnkIdentDefs, ident("callbackPtr"), ident("pointer"), newEmptyNode()),
      newTree(nnkIdentDefs, ident("userData"), ident("pointer"), newEmptyNode()),
      newTree(nnkIdentDefs, ident("listenerHandle"), ident("uint64"), newEmptyNode()),
    )

    let closurePragmas = newTree(nnkPragma, ident("closure"), ident("async"))

    let closureLambda = newTree(
      nnkLambda,
      newEmptyNode(),
      newEmptyNode(),
      newEmptyNode(),
      closureFormalParams,
      closurePragmas,
      newEmptyNode(),
      closureBody,
    )

    let installerProc = quote:
      proc `installProviderIdent`(`provCtxIdent`: BrokerContext): Result[void, string] =
        let providerInstallRes =
          RegisterEventListenerResult.setProvider(`provCtxIdent`, `closureLambda`)
        if providerInstallRes.isErr():
          return err(providerInstallRes.error())
        return ok()

    result.add(installerProc)

  # Generate aggregate cleanup proc (sync — dropAllListeners is sync in MT mode)
  let cleanupAllIdent = ident("cleanupAllApiEventListeners")
  if gApiEventCleanupProcNames.len > 0:
    let cleanupCtxIdent = genSym(nskParam, "ctx")
    var cleanupBody = newStmtList()
    for procName in gApiEventCleanupProcNames:
      cleanupBody.add(newCall(ident(procName), cleanupCtxIdent))

    let cleanupFormalParams = newTree(
      nnkFormalParams,
      newEmptyNode(),
      newTree(nnkIdentDefs, cleanupCtxIdent, ident("BrokerContext"), newEmptyNode()),
    )

    let cleanupProc = newTree(
      nnkProcDef,
      cleanupAllIdent,
      newEmptyNode(),
      newEmptyNode(),
      cleanupFormalParams,
      newEmptyNode(),
      newEmptyNode(),
      cleanupBody,
    )
    result.add(cleanupProc)

  let cleanupAllRequestsIdent = ident("cleanupAllApiRequestProviders")
  block:
    let cleanupCtxIdent = genSym(nskParam, "ctx")
    var cleanupBody = newStmtList()
    for procName in gApiRequestCleanupProcNames:
      cleanupBody.add(newCall(ident(procName), cleanupCtxIdent))

    let cleanupFormalParams = newTree(
      nnkFormalParams,
      newEmptyNode(),
      newTree(nnkIdentDefs, cleanupCtxIdent, ident("BrokerContext"), newEmptyNode()),
    )

    let cleanupProc = newTree(
      nnkProcDef,
      cleanupAllRequestsIdent,
      newEmptyNode(),
      newEmptyNode(),
      cleanupFormalParams,
      newEmptyNode(),
      newEmptyNode(),
      cleanupBody,
    )
    result.add(cleanupProc)

  # Generate aggregate processLoop shutdown proc (async — awaits per-type procs)
  let shutdownAllProcessLoopsIdent = ident("shutdownAllApiEventProcessLoops")
  block:
    let shutdownCtxIdent = genSym(nskParam, "ctx")
    var shutdownBody = newStmtList()
    for procName in gApiEventProcessLoopShutdownProcNames:
      shutdownBody.add(
        newCall(ident("await"), newCall(ident(procName), shutdownCtxIdent))
      )
    let shutdownFormalParams = newTree(
      nnkFormalParams,
      newEmptyNode(),
      newTree(nnkIdentDefs, shutdownCtxIdent, ident("BrokerContext"), newEmptyNode()),
    )
    let asyncPragma = newTree(
      nnkPragma,
      newTree(
        nnkExprColonExpr,
        ident("async"),
        newTree(
          nnkTupleConstr,
          newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
        ),
      ),
    )
    let shutdownProc = newTree(
      nnkProcDef,
      shutdownAllProcessLoopsIdent,
      newEmptyNode(),
      newEmptyNode(),
      shutdownFormalParams,
      asyncPragma,
      newEmptyNode(),
      shutdownBody,
    )
    result.add(shutdownProc)

  # Processing thread proc
  result.add(
    quote do:
      proc `waitForStartupProcIdent`(
          startupFlag: ptr Atomic[int], timeoutMs: int
      ): int =
        var waitedMs = 0
        while true:
          let startupStatus = startupFlag[].load(moAcquire)
          if startupStatus != 0:
            return startupStatus
          if waitedMs >= timeoutMs:
            return 0
          sleep(1)
          inc waitedMs

      proc `procThreadProcIdent`(arg: ptr `procThreadArgIdent`) {.thread.} =
        setThreadBrokerContext(arg.ctx)

        when compiles(setupProviders(arg.ctx).isErr()):
          let setupCatchRes = catch:
            setupProviders(arg.ctx)
          if setupCatchRes.isErr():
            recordStartupFailure(
              addr arg.startupState.processingReady,
              addr arg.startupState.processingErrorMessage,
              "request processing startup",
              "setupProviders raised exception: " & setupCatchRes.error.msg,
            )
            return
          let setupRes = setupCatchRes.get()
          if setupRes.isErr():
            recordStartupFailure(
              addr arg.startupState.processingReady,
              addr arg.startupState.processingErrorMessage,
              "request processing startup",
              setupRes.error(),
            )
            return
        elif compiles(setupProviders(arg.ctx)):
          let setupCatchRes = catch:
            setupProviders(arg.ctx)
          if setupCatchRes.isErr():
            recordStartupFailure(
              addr arg.startupState.processingReady,
              addr arg.startupState.processingErrorMessage,
              "request processing startup",
              "setupProviders raised exception: " & setupCatchRes.error.msg,
            )
            return

        arg.startupState.processingReady.store(1, moRelease)

        proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.async: (raises: []).} =
          while shutdownFlag[].load(moAcquire) != 1:
            let sleepRes = catch:
              await sleepAsync(milliseconds(1))
            if sleepRes.isErr():
              discard

        proc drainAsyncOps() {.async: (raises: []).} =
          let sleepRes = catch:
            await sleepAsync(milliseconds(1))
          if sleepRes.isErr():
            discard

        waitFor awaitShutdown(addr arg.shutdownFlag)

        `cleanupAllRequestsIdent`(arg.ctx)
        waitFor drainAsyncOps()

  )

  # Delivery thread proc
  let hasEventHandlers = gApiEventHandlerEntries.len > 0
  let hasCleanup = gApiEventCleanupProcNames.len > 0

  if hasEventHandlers and hasCleanup:
    result.add(
      quote do:
        proc `delivThreadProcIdent`(arg: ptr `delivThreadArgIdent`) {.thread.} =
          setThreadBrokerContext(arg.ctx)

          # Install the aggregate event listener provider
          let installProviderRes = `installProviderIdent`(arg.ctx)
          if installProviderRes.isErr():
            recordStartupFailure(
              addr arg.startupState.deliveryReady,
              addr arg.startupState.deliveryErrorMessage,
              "event delivery startup",
              installProviderRes.error(),
            )
            return

          arg.startupState.deliveryReady.store(1, moRelease)

          proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.async: (raises: []).} =
            while shutdownFlag[].load(moAcquire) != 1:
              let sleepRes = catch:
                await sleepAsync(milliseconds(1))
              if sleepRes.isErr():
                discard

          waitFor awaitShutdown(addr arg.shutdownFlag)

          # Cleanup: drop all registered event listeners
          `cleanupAllIdent`(arg.ctx)
          # Remove the RegisterEventListenerResult provider before entering the
          # processLoop shutdown so that any in-flight on<Event>() requests processed
          # during the shutdown waitFor return an error instead of calling listen()
          # on a partially-torn-down bucket registry.
          RegisterEventListenerResult.clearProvider(arg.ctx)
          # Terminate all processLoop coroutines on this thread and await them before
          # the thread exits to prevent use-after-free on thread-local allocators.
          waitFor `shutdownAllProcessLoopsIdent`(arg.ctx)

    )
  elif hasEventHandlers:
    result.add(
      quote do:
        proc `delivThreadProcIdent`(arg: ptr `delivThreadArgIdent`) {.thread.} =
          setThreadBrokerContext(arg.ctx)
          let installProviderRes = `installProviderIdent`(arg.ctx)
          if installProviderRes.isErr():
            recordStartupFailure(
              addr arg.startupState.deliveryReady,
              addr arg.startupState.deliveryErrorMessage,
              "event delivery startup",
              installProviderRes.error(),
            )
            return

          arg.startupState.deliveryReady.store(1, moRelease)

          proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.async: (raises: []).} =
            while shutdownFlag[].load(moAcquire) != 1:
              let sleepRes = catch:
                await sleepAsync(milliseconds(1))
              if sleepRes.isErr():
                discard

          waitFor awaitShutdown(addr arg.shutdownFlag)

          RegisterEventListenerResult.clearProvider(arg.ctx)
          waitFor `shutdownAllProcessLoopsIdent`(arg.ctx)

    )
  else:
    result.add(
      quote do:
        proc `delivThreadProcIdent`(arg: ptr `delivThreadArgIdent`) {.thread.} =
          setThreadBrokerContext(arg.ctx)

          arg.startupState.deliveryReady.store(1, moRelease)

          proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.async: (raises: []).} =
            while shutdownFlag[].load(moAcquire) != 1:
              let sleepRes = catch:
                await sleepAsync(milliseconds(1))
              if sleepRes.isErr():
                discard

          waitFor awaitShutdown(addr arg.shutdownFlag)

    )

  # createContext function — creates context, both threads
  result.add(
    quote do:
      proc `createContextFuncIdent`(): `createContextResultIdent` {.
          exportc: `createContextFuncNameLit`, cdecl, dynlib
      .} =
        ensureForeignThreadGc()
        result.ctx = 0'u32
        result.error_message = nil

        let initRes = ensureLibCtxInit()
        if initRes.isErr():
          result.error_message = allocCStringCopy(initRes.error())
          return

        var ctx = NewBrokerContext()
        # Context 0 is reserved as the C-side error sentinel
        if uint32(ctx) == 0:
          ctx = NewBrokerContext()

        var startupState: ptr `startupStateIdent` = nil
        var procArg: ptr `procThreadArgIdent` = nil
        var delivArg: ptr `delivThreadArgIdent` = nil
        var entry: ptr `ctxEntryIdent` = nil

        try:
          startupState =
            cast[ptr `startupStateIdent`](createShared(`startupStateIdent`, 1))
        except ResourceExhaustedError:
          error "Failed to allocate createContext startup state",
            library = `libNameLit`, ctx = uint32(ctx), detail = "resource exhaustion"
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        except Exception as e:
          error "Failed to allocate createContext startup state",
            library = `libNameLit`, ctx = uint32(ctx), detail = e.msg
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return

        startupState.deliveryReady.store(0, moRelease)
        startupState.processingReady.store(0, moRelease)
        startupState.deliveryErrorMessage = nil
        startupState.processingErrorMessage = nil

        # Create processing thread arg
        try:
          procArg =
            cast[ptr `procThreadArgIdent`](createShared(`procThreadArgIdent`, 1))
        except ResourceExhaustedError:
          error "Failed to allocate processing-thread startup arguments",
            library = `libNameLit`, ctx = uint32(ctx), detail = "resource exhaustion"
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        except Exception as e:
          error "Failed to allocate processing-thread startup arguments",
            library = `libNameLit`, ctx = uint32(ctx), detail = e.msg
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        procArg.ctx = ctx
        procArg.shutdownFlag.store(0, moRelease)
        procArg.startupState = startupState

        # Create delivery thread arg
        try:
          delivArg =
            cast[ptr `delivThreadArgIdent`](createShared(`delivThreadArgIdent`, 1))
        except ResourceExhaustedError:
          error "Failed to allocate delivery-thread startup arguments",
            library = `libNameLit`, ctx = uint32(ctx), detail = "resource exhaustion"
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        except Exception as e:
          error "Failed to allocate delivery-thread startup arguments",
            library = `libNameLit`, ctx = uint32(ctx), detail = e.msg
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        delivArg.ctx = ctx
        delivArg.shutdownFlag.store(0, moRelease)
        delivArg.startupState = startupState

        # Allocate entry on shared heap — Thread objects must not be moved
        # after createThread (the pthread holds a pointer to them)
        try:
          entry = cast[ptr `ctxEntryIdent`](createShared(`ctxEntryIdent`, 1))
        except ResourceExhaustedError:
          error "Failed to allocate library context entry",
            library = `libNameLit`, ctx = uint32(ctx), detail = "resource exhaustion"
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        except Exception as e:
          error "Failed to allocate library context entry",
            library = `libNameLit`, ctx = uint32(ctx), detail = e.msg
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during startup preparation"
          )
          return
        entry.ctx = ctx
        entry.procArg = procArg
        entry.delivArg = delivArg
        entry.active = true

        # Start delivery thread first (so provider is ready for requests)
        try:
          createThread(entry.delivThread, `delivThreadProcIdent`, delivArg)
        except ResourceExhaustedError:
          error "Failed to create delivery thread",
            library = `libNameLit`, ctx = uint32(ctx), detail = "resource exhaustion"
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during event delivery startup"
          )
          return
        except Exception as e:
          error "Failed to create delivery thread",
            library = `libNameLit`, ctx = uint32(ctx), detail = e.msg
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during event delivery startup"
          )
          return

        let deliveryStartupStatus =
          `waitForStartupProcIdent`(addr startupState.deliveryReady, 5000)
        if deliveryStartupStatus != 1:
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          if deliveryStartupStatus == -1:
            error "Event delivery startup reported failure",
              library = `libNameLit`,
              ctx = uint32(ctx),
              detail =
                if startupState.deliveryErrorMessage.isNil:
                  "no additional detail"
                else:
                  $startupState.deliveryErrorMessage
            result.error_message = allocCStringCopy(
              "Library context creation failed during event delivery startup"
            )
          else:
            error "Event delivery startup timed out",
              library = `libNameLit`, ctx = uint32(ctx), timeout_ms = 5000
            result.error_message = allocCStringCopy(
              "Library context creation timed out during event delivery startup"
            )
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          return

        # Start processing thread
        try:
          createThread(entry.procThread, `procThreadProcIdent`, procArg)
        except ResourceExhaustedError:
          # Shut down delivery thread
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          error "Failed to create processing thread",
            library = `libNameLit`, ctx = uint32(ctx), detail = "resource exhaustion"
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during request processing startup"
          )
          return
        except Exception as e:
          error "Failed to create processing thread",
            library = `libNameLit`, ctx = uint32(ctx), detail = e.msg
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          result.error_message = allocCStringCopy(
            "Library context creation failed during request processing startup"
          )
          return

        let processingStartupStatus =
          `waitForStartupProcIdent`(addr startupState.processingReady, 5000)
        if processingStartupStatus != 1:
          procArg.shutdownFlag.store(1, moRelease)
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.procThread)
          joinThread(entry.delivThread)
          if processingStartupStatus == -1:
            error "Request processing startup reported failure",
              library = `libNameLit`,
              ctx = uint32(ctx),
              detail =
                if startupState.processingErrorMessage.isNil:
                  "no additional detail"
                else:
                  $startupState.processingErrorMessage
            result.error_message = allocCStringCopy(
              "Library context creation failed during request processing startup"
            )
          else:
            error "Request processing startup timed out",
              library = `libNameLit`, ctx = uint32(ctx), timeout_ms = 5000
            result.error_message = allocCStringCopy(
              "Library context creation timed out during request processing startup"
            )
          releaseCreateContextResources(startupState, procArg, delivArg, entry)
          return

        cleanupStartupState(startupState)

        withLock(`globalCtxsLockIdent`):
          `globalCtxsIdent`.add(entry)

        result.ctx = uint32(ctx)

  )
  # shutdown function — runs application shutdown work, then stops both threads
  result.add(
    quote do:
      proc `shutdownFuncIdent`(
          ctx: uint32
      ) {.exportc: `shutdownFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        let initRes = ensureLibCtxInit()
        if initRes.isErr():
          error "Library shutdown skipped because initialization failed",
            library = `libNameLit`, ctx = ctx, detail = initRes.error()
          return
        let brokerCtx = BrokerContext(ctx)

        var entryPtr: ptr `ctxEntryIdent` = nil
        withLock(`globalCtxsLockIdent`):
          for i in 0 ..< `globalCtxsIdent`.len:
            let candidate = `globalCtxsIdent`[i]
            if candidate.isNil:
              continue
            if candidate.ctx == brokerCtx and candidate.active:
              entryPtr = candidate
              entryPtr.active = false
              `globalCtxsIdent`[i] = nil
              break

        if entryPtr.isNil:
          return

        let shutdownRes = waitFor `shutdownReqIdent`.request(brokerCtx)
        if shutdownRes.isErr():
          error "Library shutdown request failed",
            library = `libNameLit`, ctx = ctx, detail = shutdownRes.error()

        # Drain residual callSoon callbacks left pending on the calling thread.
        # Under --mm:refc, each waitFor leaves callbacks after the poll sentinel;
        # without draining, the ZCT grows across context lifecycles and eventually
        # triggers collectZCT on a freed cell (cell.typ == nil → SIGSEGV).
        block:
          proc drainCallerCallbacks() {.async: (raises: []).} =
            let sleepRes = catch:
              await sleepAsync(milliseconds(1))
            if sleepRes.isErr():
              discard

          waitFor drainCallerCallbacks()

        # Signal delivery thread shutdown first
        entryPtr.delivArg.shutdownFlag.store(1, moRelease)
        joinThread(entryPtr.delivThread)

        # Then signal processing thread shutdown
        # (the processing thread cleans up its own request providers internally
        # before exiting; we do a final sweep here for any cross-thread state)
        entryPtr.procArg.shutdownFlag.store(1, moRelease)
        joinThread(entryPtr.procThread)

        cleanupAllApiRequestProviders(brokerCtx)

        withLock(`globalCtxsLockIdent`):
          var writeIdx = 0
          for i in 0 ..< `globalCtxsIdent`.len:
            let candidate = `globalCtxsIdent`[i]
            if candidate.isNil:
              continue
            `globalCtxsIdent`[writeIdx] = candidate
            inc writeIdx
          `globalCtxsIdent`.setLen(writeIdx)

        releaseCtxEntryResources(entryPtr)

  )

  # free_string function
  result.add(
    quote do:
      proc `freeStringFuncIdent`(
          s: cstring
      ) {.exportc: `freeStringFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        freeCString(s)

  )

  # Public library-prefixed wrappers for request/event/free helper exports.
  for wrapper in gApiCExportWrappers:
    let publicFuncName = libName & "_" & wrapper.publicSuffix
    let publicFuncIdent = ident(publicFuncName)
    let publicFuncNameLit = newLit(publicFuncName)
    let rawFuncIdent = ident(wrapper.rawName)

    var formalParams = newTree(nnkFormalParams)
    if wrapper.returnType == "void":
      formalParams.add(newEmptyNode())
    else:
      formalParams.add(parseTypeExpr(wrapper.returnType, rawFuncIdent))

    var callExpr = newCall(rawFuncIdent)
    for (paramName, paramType) in wrapper.params:
      let paramIdent = ident(paramName)
      formalParams.add(
        newTree(
          nnkIdentDefs, paramIdent, parseTypeExpr(paramType, paramIdent), newEmptyNode()
        )
      )
      callExpr.add(paramIdent)

    let pragmas = newTree(
      nnkPragma,
      newTree(nnkExprColonExpr, ident("exportc"), publicFuncNameLit),
      ident("cdecl"),
      ident("dynlib"),
    )

    let body =
      if wrapper.returnType == "void":
        newStmtList(callExpr)
      else:
        newStmtList(newTree(nnkReturnStmt, callExpr))

    result.add(
      newTree(
        nnkProcDef,
        postfix(publicFuncIdent, "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParams,
        pragmas,
        newEmptyNode(),
        body,
      )
    )

  # Append lifecycle function prototypes to header
  appendHeaderDecl(
    generateCStruct(
      libName & "CreateContextResult",
      @[("ctx", "uint32_t"), ("error_message", "char*")],
    )
  )
  appendHeaderDecl(
    generateCFuncProto(createContextFuncName, libName & "CreateContextResult", @[])
  )
  appendHeaderDecl(
    generateCFuncProto(
      freeCreateContextResultFuncName,
      "void",
      @[("r", libName & "CreateContextResult*")],
    )
  )
  appendHeaderDecl(generateCFuncProto(shutdownFuncName, "void", @[("ctx", "uint32_t")]))
  appendHeaderDecl(generateCFuncProto(freeStringFuncName, "void", @[("s", "char*")]))

  # Generate output files at compile time
  let outDir =
    detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
  let libNameResolved = if gApiLibraryName.len > 0: gApiLibraryName else: "brokers_api"
  generateCHeaderFile(outDir, libNameResolved)
  generateCppHeaderFile(outDir, libNameResolved)

  # Generate Python wrapper file when requested
  when defined(BrokerFfiApiGenPy):
    generatePythonFile(outDir, libNameResolved)

  when defined(brokerDebug):
    echo result.repr

# ---------------------------------------------------------------------------
# CBOR-mode library codegen.
#
# Emits the small fixed C ABI surface (initialize / createContext / shutdown
# / allocBuffer / freeBuffer / call) plus a per-library dispatch case
# statement that routes apiName strings to the adapter procs registered by
# `RequestBroker(API)` expansions. Buffer ownership: every void* crossing
# the ABI is allocated by Nim and freed by Nim. Threading: a dedicated
# processing thread runs `setupProviders(ctx)` and the chronos event loop
# that drives the request providers; foreign threads invoke `<lib>_call`
# and use `waitFor` to drive a momentary chronos loop on the calling
# thread, which dispatches across the MT broker channel to the processing
# thread. Events are not yet wired (Phase 3).
# ---------------------------------------------------------------------------

proc registerBrokerLibraryCborImpl(
    body: NimNode,
    config:
      tuple[
        name: string,
        initializeRequest: NimNode,
        shutdownRequest: NimNode,
        refType: NimNode,
        ffiMode: BrokerFfiMode,
        ffiModeExplicit: bool,
      ],
): NimNode =
  let libName = config.name
  gApiLibraryName = libName

  let initializeReqIdent = config.initializeRequest
  let shutdownReqIdent = config.shutdownRequest

  # Identifiers
  let initFuncName = libName & "_initialize"
  let initFuncNameLit = newLit(initFuncName)
  let initFuncIdent = ident(initFuncName)
  let createContextFuncName = libName & "_createContext"
  let createContextFuncNameLit = newLit(createContextFuncName)
  let createContextFuncIdent = ident(createContextFuncName)
  let shutdownFuncName = libName & "_shutdown"
  let shutdownFuncNameLit = newLit(shutdownFuncName)
  let shutdownFuncIdent = ident(shutdownFuncName)
  let callFuncName = libName & "_call"
  let callFuncNameLit = newLit(callFuncName)
  let callFuncIdent = ident(callFuncName)
  let allocBufFuncName = libName & "_allocBuffer"
  let allocBufFuncNameLit = newLit(allocBufFuncName)
  let allocBufFuncIdent = ident(allocBufFuncName)
  let freeBufFuncName = libName & "_freeBuffer"
  let freeBufFuncNameLit = newLit(freeBufFuncName)
  let freeBufFuncIdent = ident(freeBufFuncName)

  let nimMainIdent = ident(libName & "NimMain")
  let nimInitFlagIdent = ident("g" & libName & "NimInit")
  let gcRegFlagIdent = ident("g" & libName & "GcReg")
  let ctxEntryIdent = ident(libName & "CborCtxEntry")
  let procThreadArgIdent = ident(libName & "CborThreadArg")
  let procThreadProcIdent = ident(libName & "CborProcessingThread")
  let ctxsIdent = ident("g" & libName & "CborCtxs")
  let ctxsLockIdent = ident("g" & libName & "CborCtxsLock")
  let ctxsInitIdent = ident("g" & libName & "CborCtxsInit")
  let dispatchProcIdent = ident(libName & "CborDispatch")
  let libNameLit = newLit(libName)

  # Event subscription identifiers (used by the per-event installers and the
  # subscribe / unsubscribe C exports).
  let eventCallbackTypeIdent = ident(libName & "CborEventCallback")
  let subscriptionTypeIdent = ident(libName & "CborSubscription")
  let subsKeyTypeIdent = ident(libName & "CborSubsKey")
  let subsTableIdent = ident("g" & libName & "CborSubs")
  let subsLockIdent = ident("g" & libName & "CborSubsLock")
  let subsHandleIdent = ident("g" & libName & "CborNextSubHandle")
  let subscribeFuncName = libName & "_subscribe"
  let subscribeFuncNameLit = newLit(subscribeFuncName)
  let subscribeFuncIdent = ident(subscribeFuncName)
  let unsubscribeFuncName = libName & "_unsubscribe"
  let unsubscribeFuncNameLit = newLit(unsubscribeFuncName)
  let unsubscribeFuncIdent = ident(unsubscribeFuncName)
  let knownEventPredIdent = ident(libName & "CborIsKnownEvent")
  let installAllListenersIdent = ident(libName & "CborInstallAllListeners")

  # Hard cap on a single buffer to detect runaway encodes.
  let bufSizeCap = newLit(64 * 1024 * 1024)

  result = newStmtList()

  # Compile-time validation of the mandatory request types.
  result.add(
    quote do:
      when not compiles(typeof(`initializeReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: initializeRequest type '" &
            astToStr(`initializeReqIdent`) &
            "' is not defined. Ensure a RequestBroker(API) declaring this type " &
            "appears before registerBrokerLibrary."
        .}
      when not compiles(typeof(`shutdownReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: shutdownRequest type '" &
            astToStr(`shutdownReqIdent`) &
            "' is not defined. Ensure a RequestBroker(API) declaring this type " &
            "appears before registerBrokerLibrary."
        .}
  )

  # Foreign-thread GC bootstrap (once per compilation unit).
  result.add(emitEnsureForeignThreadGc())

  # NimMain import on POSIX (Windows DllMain auto-runs it).
  when not defined(windows):
    let nimMainImportName = newLit(libName & "NimMain")
    result.add(
      quote do:
        proc `nimMainIdent`() {.importc: `nimMainImportName`, cdecl.}
    )

  # ------------------------------------------------------------------
  # Build the dispatch case statement from accumulated request entries.
  # Snapshot and clear the accumulator so a second registerBrokerLibrary in
  # the same compilation unit (a future multi-library scenario) starts fresh.
  # ------------------------------------------------------------------
  # Snapshot the registered request adapters and event entries. We
  # deliberately do NOT clear the global accumulators here — Nim's
  # compile-time VM aliases `let` copies of seqs back to the source, so
  # resetting before reading would leave us with an empty list. A future
  # multi-library-per-compilation scenario would need a different pattern
  # (e.g., snapshot a length and slice from there next time).
  let entries = gApiCborRequestEntries
  let eventEntries = gApiCborEventEntries

  # The dispatch proc is async and returns just `seq[byte]`. To signal
  # "unknown apiName" without raising or capturing a `var bool`, the
  # convention is: empty seq + the calling `<lib>_call` checks against the
  # known-name set (a separate non-async predicate proc).
  let knownNamePredIdent = ident(libName & "CborIsKnownApiName")

  var caseStmt = nnkCaseStmt.newTree(ident("apiName"))
  for entry in entries:
    let nameLit = newLit(entry.apiName)
    let adapterCall = newCall(ident(entry.adapterProc), ident("ctx"), ident("reqBuf"))
    let branchBody = newStmtList(
      nnkReturnStmt.newTree(nnkCommand.newTree(ident("await"), adapterCall))
    )
    caseStmt.add(nnkOfBranch.newTree(nameLit, branchBody))
  caseStmt.add(
    nnkElse.newTree(
      newStmtList(nnkReturnStmt.newTree(prefix(nnkBracket.newTree(), "@")))
    )
  )

  let dispatchProc = nnkProcDef.newTree(
    postfix(dispatchProcIdent, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      nnkBracketExpr.newTree(
        ident("Future"), nnkBracketExpr.newTree(ident("seq"), ident("byte"))
      ),
      newIdentDefs(ident("apiName"), ident("string")),
      newIdentDefs(ident("ctx"), ident("BrokerContext")),
      newIdentDefs(ident("reqBuf"), nnkBracketExpr.newTree(ident("seq"), ident("byte"))),
    ),
    nnkPragma.newTree(
      newColonExpr(
        ident("async"),
        nnkTupleConstr.newTree(newColonExpr(ident("raises"), nnkBracket.newTree())),
      ),
      ident("gcsafe"),
    ),
    newEmptyNode(),
    newStmtList(caseStmt),
  )
  result.add(dispatchProc)

  # Companion predicate: foreign caller dispatch needs to distinguish
  # "unknown name" from "known name with empty response". Predicate is a
  # plain non-async proc so `<lib>_call` can call it directly.
  var nameSet = newStmtList()
  var nameCase = nnkCaseStmt.newTree(ident("apiName"))
  for entry in entries:
    nameCase.add(
      nnkOfBranch.newTree(
        newLit(entry.apiName), newStmtList(nnkReturnStmt.newTree(ident("true")))
      )
    )
  nameCase.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(ident("false")))))
  nameSet.add(nameCase)
  let knownProc = nnkProcDef.newTree(
    postfix(knownNamePredIdent, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      ident("bool"), newIdentDefs(ident("apiName"), ident("string"))
    ),
    nnkPragma.newTree(ident("gcsafe")),
    newEmptyNode(),
    nameSet,
  )
  result.add(knownProc)

  # ------------------------------------------------------------------
  # Event known-name predicate (companion to request side).
  # ------------------------------------------------------------------
  block:
    var eventCase = nnkCaseStmt.newTree(ident("eventName"))
    for e in eventEntries:
      eventCase.add(
        nnkOfBranch.newTree(
          newLit(e.apiName), newStmtList(nnkReturnStmt.newTree(ident("true")))
        )
      )
    eventCase.add(nnkElse.newTree(newStmtList(nnkReturnStmt.newTree(ident("false")))))
    let eventKnownProc = nnkProcDef.newTree(
      postfix(knownEventPredIdent, "*"),
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        ident("bool"), newIdentDefs(ident("eventName"), ident("string"))
      ),
      nnkPragma.newTree(ident("gcsafe")),
      newEmptyNode(),
      newStmtList(eventCase),
    )
    result.add(eventKnownProc)

  # ------------------------------------------------------------------
  # Per-library types and globals.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      type
        `procThreadArgIdent` = object
          ctx: BrokerContext
          shutdownFlag: Atomic[int]
          processingReady: Atomic[int]
          processingErrorMessage: cstring

        `ctxEntryIdent` = object
          ctx: BrokerContext
          procThread: Thread[ptr `procThreadArgIdent`]
          arg: ptr `procThreadArgIdent`
          active: bool

        `eventCallbackTypeIdent`* = proc(
          ctx: uint32,
          eventName: cstring,
          payloadBuf: pointer,
          payloadLen: int32,
          userData: pointer,
        ) {.cdecl, gcsafe, raises: [].}

        `subscriptionTypeIdent` = object
          handle: uint64
          cb: `eventCallbackTypeIdent`
          userData: pointer

        `subsKeyTypeIdent` = tuple[ctx: uint32, eventName: string]

      var `ctxsIdent`: seq[ptr `ctxEntryIdent`]
      var `ctxsLockIdent`: Lock
      var `ctxsInitIdent`: Atomic[int]

      var `subsTableIdent`: Table[`subsKeyTypeIdent`, seq[`subscriptionTypeIdent`]]
      var `subsLockIdent`: Lock
      var `subsHandleIdent`: Atomic[uint64]

      var `nimInitFlagIdent`: Atomic[int]
      var `gcRegFlagIdent` {.threadvar.}: bool
  )

  # ------------------------------------------------------------------
  # `<lib>_initialize` — Nim runtime + GC setup. Idempotent.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `initFuncIdent`*() {.exportc: `initFuncNameLit`, cdecl, dynlib.} =
        # Step 1: one-time Nim runtime init.
        while true:
          case `nimInitFlagIdent`.load(moAcquire)
          of 2:
            break
          of -1:
            return
          of 1:
            sleep(1)
          else:
            var expected = 0
            if `nimInitFlagIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
              when compileOption("app", "lib") and not defined(windows):
                let initRes = catch:
                  `nimMainIdent`()
                if initRes.isErr():
                  error "Failed to initialize Nim runtime",
                    library = `libNameLit`, detail = initRes.error.msg
                  `nimInitFlagIdent`.store(-1, moRelease)
                  return
              `nimInitFlagIdent`.store(2, moRelease)
              break

        # Step 2: per-thread foreign GC registration.
        when compileOption("app", "lib"):
          if not `gcRegFlagIdent`:
            when declared(setupForeignThreadGc):
              setupForeignThreadGc()
            `gcRegFlagIdent` = true
          when declared(nimGC_setStackBottom):
            var locals {.volatile, noinit.}: pointer
            locals = addr(locals)
            nimGC_setStackBottom(locals)

        # Step 3: lazy-init the global ctx registry and the subs map/lock.
        var ctxsExpected = 0
        if `ctxsInitIdent`.compareExchange(ctxsExpected, 1, moAcquire, moRelaxed):
          initLock(`ctxsLockIdent`)
          initLock(`subsLockIdent`)
          `subsTableIdent` =
            initTable[`subsKeyTypeIdent`, seq[`subscriptionTypeIdent`]]()
          `ctxsInitIdent`.store(2, moRelease)
        else:
          while `ctxsInitIdent`.load(moAcquire) != 2:
            sleep(1)

  )

  # ------------------------------------------------------------------
  # `<lib>_allocBuffer` / `<lib>_freeBuffer`.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `allocBufFuncIdent`*(
          size: int32
      ): pointer {.exportc: `allocBufFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if size <= 0 or size.int > `bufSizeCap`:
          return nil
        allocShared0(size.int)

      proc `freeBufFuncIdent`*(
          buf: pointer
      ) {.exportc: `freeBufFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if not buf.isNil:
          deallocShared(buf)

  )

  # ------------------------------------------------------------------
  # Per-event listener installers.
  #
  # Each installer registers an MT-broker listener whose body:
  #   1. Snapshots the subscription list for (ctx, eventName) under the
  #      subs lock (so concurrent subscribe/unsubscribe doesn't iterate
  #      while we mutate).
  #   2. CBOR-encodes the event payload once (callback fan-out reuses the
  #      buffer for all subscribers).
  #   3. Allocates a shared-heap buffer, copies the bytes in, invokes each
  #      subscriber's C callback synchronously, frees the buffer.
  #
  # The listener captures the per-library globals — they live for the
  # lifetime of the library, so closure capture is safe.
  # ------------------------------------------------------------------
  var installerNames: seq[string] = @[]
  for e in eventEntries:
    let eventTypeIdent = ident(e.typeName)
    let installerIdent = ident(libName & "Cbor" & e.typeName & "Installer")
    let eventNameLit = newLit(e.apiName)
    installerNames.add($installerIdent)
    result.add(
      quote do:
        proc `installerIdent`*(ctx: BrokerContext): Result[void, string] =
          proc handler(
              evt: `eventTypeIdent`
          ): Future[void] {.async: (raises: []), gcsafe.} =
            let key: `subsKeyTypeIdent` = (uint32(ctx), `eventNameLit`)
            var subs: seq[`subscriptionTypeIdent`]
            {.cast(gcsafe).}:
              withLock `subsLockIdent`:
                subs = `subsTableIdent`.getOrDefault(key)
            if subs.len == 0:
              return
            let encRes = cborEncode(evt)
            if encRes.isErr:
              return
            let bytes = encRes.value
            var buf: pointer = nil
            if bytes.len > 0:
              buf = allocShared0(bytes.len)
              copyMem(buf, unsafeAddr bytes[0], bytes.len)
            for sub in subs:
              if sub.cb.isNil:
                continue
              sub.cb(
                uint32(ctx), `eventNameLit`.cstring, buf, int32(bytes.len), sub.userData
              )
            if not buf.isNil:
              deallocShared(buf)

          let listenRes = `eventTypeIdent`.listen(ctx, handler)
          if listenRes.isErr:
            return Result[void, string].err(listenRes.error)
          return Result[void, string].ok()

    )

  # ------------------------------------------------------------------
  # Umbrella installer: called from the processing thread after
  # setupProviders so listeners are live before any foreign caller can
  # subscribe.
  # ------------------------------------------------------------------
  var installerCalls = newStmtList()
  for installerName in installerNames:
    let installerIdent = ident(installerName)
    installerCalls.add(
      newTree(nnkPrefix, ident("?"), newCall(installerIdent, ident("ctx")))
    )
  installerCalls.add(
    nnkReturnStmt.newTree(
      newCall(
        newDotExpr(
          nnkBracketExpr.newTree(ident("Result"), ident("void"), ident("string")),
          ident("ok"),
        )
      )
    )
  )
  let installAllProc = nnkProcDef.newTree(
    postfix(installAllListenersIdent, "*"),
    newEmptyNode(),
    newEmptyNode(),
    nnkFormalParams.newTree(
      nnkBracketExpr.newTree(ident("Result"), ident("void"), ident("string")),
      newIdentDefs(ident("ctx"), ident("BrokerContext")),
    ),
    newEmptyNode(),
    newEmptyNode(),
    installerCalls,
  )
  result.add(installAllProc)

  # ------------------------------------------------------------------
  # `<lib>_subscribe` / `<lib>_unsubscribe`.
  #
  # Subscribe handle convention: 0 == failure (unknown event, allocation
  # error, nil callback for non-probe paths). 1 is reserved as the
  # "supported" sentinel returned for probe calls (cb == nil). Real
  # subscriptions start at 2 to avoid colliding with these reserved
  # values.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `subscribeFuncIdent`*(
          ctx: uint32,
          eventNameC: cstring,
          cb: `eventCallbackTypeIdent`,
          userData: pointer,
      ): uint64 {.exportc: `subscribeFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if eventNameC.isNil:
          return 0'u64
        let name = $eventNameC
        if not `knownEventPredIdent`(name):
          return 0'u64
        if cb.isNil:
          # Probe mode: caller wants to know whether the eventName is
          # supported by this library version. 1 is a sentinel never
          # returned for real subscriptions.
          return 1'u64
        # Real subscription handle: skip 0 (failure) and 1 (probe).
        let h = `subsHandleIdent`.fetchAdd(1, moRelaxed) + 2'u64
        {.cast(gcsafe).}:
          withLock `subsLockIdent`:
            let key: `subsKeyTypeIdent` = (ctx, name)
            var current = `subsTableIdent`.getOrDefault(key)
            current.add(`subscriptionTypeIdent`(handle: h, cb: cb, userData: userData))
            `subsTableIdent`[key] = current
        return h

      proc `unsubscribeFuncIdent`*(
          ctx: uint32, eventNameC: cstring, handle: uint64
      ): int32 {.exportc: `unsubscribeFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if eventNameC.isNil:
          return -1'i32
        let name = $eventNameC
        {.cast(gcsafe).}:
          withLock `subsLockIdent`:
            let key: `subsKeyTypeIdent` = (ctx, name)
            var subs = `subsTableIdent`.getOrDefault(key)
            if subs.len == 0:
              return -2'i32
            if handle == 0'u64:
              `subsTableIdent`.del(key)
              return 0'i32
            var idx = -1
            for i in 0 ..< subs.len:
              if subs[i].handle == handle:
                idx = i
                break
            if idx < 0:
              return -3'i32
            subs.delete(idx)
            if subs.len == 0:
              `subsTableIdent`.del(key)
            else:
              `subsTableIdent`[key] = subs
            return 0'i32

  )

  # ------------------------------------------------------------------
  # Processing thread proc (one per ctx). Runs setupProviders then loops
  # on a chronos event loop until shutdownFlag is set.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `procThreadProcIdent`(arg: ptr `procThreadArgIdent`) {.thread.} =
        setThreadBrokerContext(arg.ctx)

        when compiles(setupProviders(arg.ctx).isErr()):
          let setupCatchRes = catch:
            setupProviders(arg.ctx)
          if setupCatchRes.isErr():
            arg.processingErrorMessage =
              allocCStringCopy("setupProviders raised: " & setupCatchRes.error.msg)
            arg.processingReady.store(-1, moRelease)
            return
          let setupRes = setupCatchRes.get()
          if setupRes.isErr():
            arg.processingErrorMessage = allocCStringCopy(setupRes.error())
            arg.processingReady.store(-1, moRelease)
            return
        elif compiles(setupProviders(arg.ctx)):
          let setupCatchRes = catch:
            setupProviders(arg.ctx)
          if setupCatchRes.isErr():
            arg.processingErrorMessage =
              allocCStringCopy("setupProviders raised: " & setupCatchRes.error.msg)
            arg.processingReady.store(-1, moRelease)
            return

        # Install event listeners so subscriptions arriving any time after
        # createContext returns will receive emitted events.
        let installCatchRes = catch:
          `installAllListenersIdent`(arg.ctx)
        if installCatchRes.isErr():
          arg.processingErrorMessage = allocCStringCopy(
            "event listener install raised: " & installCatchRes.error.msg
          )
          arg.processingReady.store(-1, moRelease)
          return
        let installRes = installCatchRes.get()
        if installRes.isErr():
          arg.processingErrorMessage =
            allocCStringCopy("event listener install failed: " & installRes.error())
          arg.processingReady.store(-1, moRelease)
          return

        arg.processingReady.store(1, moRelease)

        proc awaitShutdown(flag: ptr Atomic[int]) {.async: (raises: []).} =
          while flag[].load(moAcquire) != 1:
            let s = catch:
              await sleepAsync(milliseconds(5))
            if s.isErr():
              discard

        waitFor awaitShutdown(addr arg.shutdownFlag)

  )

  # ------------------------------------------------------------------
  # `<lib>_createContext` — spawn ctx + processing thread, await ready.
  # `<lib>_shutdown` — signal, join, free.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `createContextFuncIdent`*(
          errOut: ptr cstring
      ): uint32 {.exportc: `createContextFuncNameLit`, cdecl, dynlib.} =
        `initFuncIdent`()
        ensureForeignThreadGc()

        # Skip BrokerContext value 0 — `<lib>_createContext` reserves 0
        # as the failure return code visible to foreign callers.
        var bctx = NewBrokerContext()
        while uint32(bctx) == 0'u32:
          bctx = NewBrokerContext()
        let arg =
          cast[ptr `procThreadArgIdent`](allocShared0(sizeof(`procThreadArgIdent`)))
        arg.ctx = bctx
        arg.shutdownFlag.store(0, moRelaxed)
        arg.processingReady.store(0, moRelaxed)
        arg.processingErrorMessage = nil

        let entry = cast[ptr `ctxEntryIdent`](allocShared0(sizeof(`ctxEntryIdent`)))
        entry.ctx = bctx
        entry.arg = arg
        entry.active = true

        let createRes = catch:
          createThread(entry.procThread, `procThreadProcIdent`, arg)
        if createRes.isErr():
          if not errOut.isNil:
            errOut[] = allocCStringCopy(
              "Failed to spawn processing thread: " & createRes.error.msg
            )
          deallocShared(arg)
          deallocShared(entry)
          return 0'u32

        # Poll for processingReady (or failure).
        var waitedMs = 0
        const timeoutMs = 5000
        var status = 0
        while waitedMs < timeoutMs:
          status = arg.processingReady.load(moAcquire).int
          if status != 0:
            break
          sleep(1)
          inc waitedMs

        if status != 1:
          arg.shutdownFlag.store(1, moRelease)
          joinThread(entry.procThread)
          if not errOut.isNil:
            if not arg.processingErrorMessage.isNil:
              errOut[] = arg.processingErrorMessage
              arg.processingErrorMessage = nil
            else:
              errOut[] = allocCStringCopy("processing thread did not become ready")
          deallocShared(arg)
          deallocShared(entry)
          return 0'u32

        withLock `ctxsLockIdent`:
          `ctxsIdent`.add(entry)
        return uint32(bctx)

      proc `shutdownFuncIdent`*(
          ctx: uint32
      ): int32 {.exportc: `shutdownFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        var entryToShutdown: ptr `ctxEntryIdent` = nil
        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            let e = `ctxsIdent`[i]
            if uint32(e.ctx) == ctx and e.active:
              e.active = false
              entryToShutdown = e
              break
        if entryToShutdown.isNil:
          return -1'i32

        entryToShutdown.arg.shutdownFlag.store(1, moRelease)
        joinThread(entryToShutdown.procThread)
        if not entryToShutdown.arg.processingErrorMessage.isNil:
          freeCString(entryToShutdown.arg.processingErrorMessage)
        deallocShared(entryToShutdown.arg)

        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            if `ctxsIdent`[i] == entryToShutdown:
              `ctxsIdent`.del(i)
              break
        deallocShared(entryToShutdown)
        return 0'i32

  )

  # ------------------------------------------------------------------
  # `<lib>_call` — string dispatch over the generated case statement.
  # ------------------------------------------------------------------
  result.add(
    quote do:
      proc `callFuncIdent`*(
          ctx: uint32,
          apiNameC: cstring,
          reqBuf: pointer,
          reqLen: int32,
          respBufOut: ptr pointer,
          respLenOut: ptr int32,
      ): int32 {.exportc: `callFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        if apiNameC.isNil:
          return -2'i32
        if reqLen < 0 or reqLen.int > `bufSizeCap`:
          return -3'i32

        let apiName = $apiNameC

        # Copy the inbound buffer into a Nim seq[byte] so the bytes outlive
        # the C buffer (which we free unconditionally before returning).
        var nimReq = newSeq[byte](reqLen.int)
        if reqLen > 0 and not reqBuf.isNil:
          copyMem(addr nimReq[0], reqBuf, reqLen.int)
        if not reqBuf.isNil:
          deallocShared(reqBuf)

        let bctx = BrokerContext(ctx)

        if not `knownNamePredIdent`(apiName):
          let msg = "unknown apiName: " & apiName
          let buf = allocShared0(msg.len)
          if msg.len > 0:
            copyMem(buf, unsafeAddr msg[0], msg.len)
          respBufOut[] = buf
          respLenOut[] = int32(msg.len)
          return -4'i32

        let dispRes = catch:
          waitFor `dispatchProcIdent`(apiName, bctx, nimReq)
        if dispRes.isErr():
          # Should not happen (adapter is raises:[]), but be defensive.
          return -10'i32

        let respBytes = dispRes.get()
        if respBytes.len > 0:
          let buf = allocShared0(respBytes.len)
          copyMem(buf, unsafeAddr respBytes[0], respBytes.len)
          respBufOut[] = buf
          respLenOut[] = int32(respBytes.len)
        return 0'i32

  )

  # ------------------------------------------------------------------
  # Generated artifacts: write the C header next to the build output so
  # foreign-language wrappers can pick it up via `-I`.
  # ------------------------------------------------------------------
  let outDir =
    detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
  var requestNames: seq[string] = @[]
  for e in entries:
    requestNames.add(e.apiName)
  var eventNames: seq[string] = @[]
  for e in eventEntries:
    eventNames.add(e.apiName)
  generateCborCHeaderFile(outDir, libName, requestNames, eventNames)
  generateCborCppHeaderFile(outDir, libName, entries, eventEntries)

  when defined(brokerDebug):
    echo "[brokers/cbor] registerBrokerLibraryCborImpl emitted runtime for '" & libName &
      "' with " & $entries.len & " request adapters and " & $eventEntries.len &
      " event entries"
    echo result.repr

{.pop.}

macro registerBrokerLibrary*(body: untyped): untyped =
  ## Generates the full shared-library surface for a broker FFI library.
  ## When compiled without `-d:BrokerFfiApi` this is a no-op, so client
  ## code never needs a `when defined(BrokerFfiApi):` guard around it.
  when defined(BrokerFfiApi):
    registerBrokerLibraryImpl(body)
  else:
    newStmtList()
