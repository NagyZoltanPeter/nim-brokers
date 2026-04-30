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

import std/[atomics, locks, macros, os, strutils]
import chronos, chronicles
import results
import asyncchannels
import ./broker_context, ./internal/api_common

export results, chronos, chronicles, broker_context, api_common, asyncchannels

# ---------------------------------------------------------------------------
# Macro helpers
# ---------------------------------------------------------------------------

proc parseLibraryConfig(
    body: NimNode
): tuple[
  name: string, initializeRequest: NimNode, shutdownRequest: NimNode, refType: NimNode
] {.compileTime.} =
  var name = ""
  var initializeReq: NimNode = nil
  var shutdownReq: NimNode = nil
  var refTy: NimNode = nil

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

proc registerBrokerLibraryImpl(body: NimNode): NimNode =
  let config = parseLibraryConfig(body)
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

{.pop.}

macro registerBrokerLibrary*(body: untyped): untyped =
  ## Generates the full shared-library surface for a broker FFI library.
  ## When compiled without `-d:BrokerFfiApi` this is a no-op, so client
  ## code never needs a `when defined(BrokerFfiApi):` guard around it.
  when defined(BrokerFfiApi):
    registerBrokerLibraryImpl(body)
  else:
    newStmtList()
