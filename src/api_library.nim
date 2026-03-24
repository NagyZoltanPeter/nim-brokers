## API Library Registration
## ------------------------
## Provides the `registerBrokerLibrary` macro that generates:
## 1. Library context lifecycle management (createContext/shutdown C exports)
## 2. Compile-time validation of mandatory InitializeRequest/DestroyRequest types
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
##   destroyRequest: DestroyRequest
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
import ./broker_context, ./api_common

export results, chronos, chronicles, broker_context, api_common, asyncchannels

# ---------------------------------------------------------------------------
# Macro helpers
# ---------------------------------------------------------------------------

proc parseLibraryConfig(
    body: NimNode
): tuple[
  name: string, initializeRequest: NimNode, destroyRequest: NimNode, refType: NimNode
] {.compileTime.} =
  var name = ""
  var initializeReq: NimNode = nil
  var destroyReq: NimNode = nil
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
      of "destroyrequest":
        if value.kind == nnkStmtList and value.len == 1:
          destroyReq = value[0]
        else:
          destroyReq = value
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
  if destroyReq.isNil():
    error("registerBrokerLibrary requires a 'destroyRequest' field", body)

  (
    name: name,
    initializeRequest: initializeReq,
    destroyRequest: destroyReq,
    refType: refTy,
  )

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------

macro registerBrokerLibrary*(body: untyped): untyped =
  let config = parseLibraryConfig(body)
  let libName = config.name
  let initializeReqIdent = config.initializeRequest
  let destroyReqIdent = config.destroyRequest

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

  # Compile-time validation: ensure InitializeRequest and DestroyRequest types exist
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
      when not compiles(typeof(`destroyReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: destroyRequest type '" & astToStr(`destroyReqIdent`) &
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
  let nimMainIdent = ident(libName & "NimMain")
  let nimMainImportName = newLit(libName & "NimMain")
  let createContextResultIdent = ident(libName & "CreateContextResult")
  let exportedCreateContextResultIdent =
    postfix(copyNimTree(createContextResultIdent), "*")

  result.add(
    quote do:
      proc `nimMainIdent`() {.importc: `nimMainImportName`, cdecl.}

      var `nimInitializedIdent`: Atomic[bool]

      proc `initLibFuncIdent`() =
        if not `nimInitializedIdent`.exchange(true):
          when compileOption("app", "lib"):
            `nimMainIdent`()
            when declared(setupForeignThreadGc):
              setupForeignThreadGc()
            when declared(nimGC_setStackBottom):
              var locals {.volatile, noinit.}: pointer
              locals = addr(locals)
              nimGC_setStackBottom(locals)

      type `exportedCreateContextResultIdent` {.exportc.} = object
        ctx*: uint32
        error_message*: cstring

      proc `freeCreateContextResultFuncIdent`(
          r: ptr `createContextResultIdent`
      ) {.exportc: `freeCreateContextResultFuncNameLit`, cdecl, dynlib.} =
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

      proc ensureLibCtxInit() =
        if not `nimInitializedIdent`.load(moRelaxed):
          `initLibFuncIdent`()
        if `globalCtxsInitIdent`.load(moRelaxed) == 2:
          return
        var expected = 0
        if `globalCtxsInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          initLock(`globalCtxsLockIdent`)
          `globalCtxsIdent` = @[]
          `globalCtxsInitIdent`.store(2, moRelease)
        else:
          while `globalCtxsInitIdent`.load(moAcquire) != 2:
            discard

      proc releaseCtxEntryResources(entryPtr: ptr `ctxEntryIdent`) =
        if entryPtr.isNil:
          return

        if not entryPtr.procArg.isNil:
          deallocShared(entryPtr.procArg)

        if not entryPtr.delivArg.isNil:
          deallocShared(entryPtr.delivArg)

        deallocShared(entryPtr)

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

    # proc installEventListenerProvider(ctx: BrokerContext) =
    #   discard RegisterEventListenerResult.setProvider(ctx, closure)
    let setProviderCall = newTree(
      nnkDiscardStmt,
      newCall(
        newDotExpr(ident("RegisterEventListenerResult"), ident("setProvider")),
        provCtxIdent,
        closureLambda,
      ),
    )

    let installerFormalParams = newTree(
      nnkFormalParams,
      newEmptyNode(),
      newTree(nnkIdentDefs, provCtxIdent, ident("BrokerContext"), newEmptyNode()),
    )

    let installerProc = newTree(
      nnkProcDef,
      installProviderIdent,
      newEmptyNode(),
      newEmptyNode(),
      installerFormalParams,
      newEmptyNode(),
      newEmptyNode(),
      newStmtList(setProviderCall),
    )
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

  # Processing thread proc
  result.add(
    quote do:
      proc `waitForStartupProcIdent`(
          startupFlag: ptr Atomic[int], timeoutMs: int
      ): bool =
        var waitedMs = 0
        while startupFlag[].load(moAcquire) != 1:
          if waitedMs >= timeoutMs:
            return false
          sleep(1)
          inc waitedMs
        true

      proc `procThreadProcIdent`(arg: ptr `procThreadArgIdent`) {.thread.} =
        setThreadBrokerContext(arg.ctx)

        when compiles(setupProviders(arg.ctx)):
          setupProviders(arg.ctx)

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
          `installProviderIdent`(arg.ctx)

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

    )
  elif hasEventHandlers:
    result.add(
      quote do:
        proc `delivThreadProcIdent`(arg: ptr `delivThreadArgIdent`) {.thread.} =
          setThreadBrokerContext(arg.ctx)
          `installProviderIdent`(arg.ctx)

          arg.startupState.deliveryReady.store(1, moRelease)

          proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.async: (raises: []).} =
            while shutdownFlag[].load(moAcquire) != 1:
              let sleepRes = catch:
                await sleepAsync(milliseconds(1))
              if sleepRes.isErr():
                discard

          waitFor awaitShutdown(addr arg.shutdownFlag)

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
        ensureLibCtxInit()
        result.ctx = 0'u32
        result.error_message = nil

        var ctx = NewBrokerContext()
        # Context 0 is reserved as the C-side error sentinel
        if uint32(ctx) == 0:
          ctx = NewBrokerContext()

        let startupState =
          cast[ptr `startupStateIdent`](createShared(`startupStateIdent`, 1))
        startupState.deliveryReady.store(0, moRelease)
        startupState.processingReady.store(0, moRelease)

        # Create processing thread arg
        let procArg =
          cast[ptr `procThreadArgIdent`](createShared(`procThreadArgIdent`, 1))
        procArg.ctx = ctx
        procArg.shutdownFlag.store(0, moRelease)
        procArg.startupState = startupState

        # Create delivery thread arg
        let delivArg =
          cast[ptr `delivThreadArgIdent`](createShared(`delivThreadArgIdent`, 1))
        delivArg.ctx = ctx
        delivArg.shutdownFlag.store(0, moRelease)
        delivArg.startupState = startupState

        # Allocate entry on shared heap — Thread objects must not be moved
        # after createThread (the pthread holds a pointer to them)
        let entry = cast[ptr `ctxEntryIdent`](createShared(`ctxEntryIdent`, 1))
        entry.ctx = ctx
        entry.procArg = procArg
        entry.delivArg = delivArg
        entry.active = true

        # Start delivery thread first (so provider is ready for requests)
        try:
          createThread(entry.delivThread, `delivThreadProcIdent`, delivArg)
        except ResourceExhaustedError:
          deallocShared(startupState)
          releaseCtxEntryResources(entry)
          result.error_message = allocCStringCopy(
            "createContext failed: delivery thread creation exhausted resources"
          )
          return
        except Exception as e:
          trace "Delivery thread creation failed", err = e.msg
          deallocShared(startupState)
          releaseCtxEntryResources(entry)
          result.error_message = allocCStringCopy(
            "createContext failed: delivery thread creation failed: " & e.msg
          )
          return

        if not `waitForStartupProcIdent`(addr startupState.deliveryReady, 5000):
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          deallocShared(startupState)
          releaseCtxEntryResources(entry)
          result.error_message =
            allocCStringCopy("createContext failed: delivery thread startup timed out")
          return

        # Start processing thread
        try:
          createThread(entry.procThread, `procThreadProcIdent`, procArg)
        except ResourceExhaustedError:
          # Shut down delivery thread
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          deallocShared(startupState)
          releaseCtxEntryResources(entry)
          result.error_message = allocCStringCopy(
            "createContext failed: processing thread creation exhausted resources"
          )
          return
        except Exception as e:
          trace "Processing thread creation failed", err = e.msg
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.delivThread)
          deallocShared(startupState)
          releaseCtxEntryResources(entry)
          result.error_message = allocCStringCopy(
            "createContext failed: processing thread creation failed: " & e.msg
          )
          return

        if not `waitForStartupProcIdent`(addr startupState.processingReady, 5000):
          procArg.shutdownFlag.store(1, moRelease)
          delivArg.shutdownFlag.store(1, moRelease)
          joinThread(entry.procThread)
          joinThread(entry.delivThread)
          deallocShared(startupState)
          releaseCtxEntryResources(entry)
          result.error_message = allocCStringCopy(
            "createContext failed: processing thread startup timed out"
          )
          return

        deallocShared(startupState)

        withLock(`globalCtxsLockIdent`):
          `globalCtxsIdent`.add(entry)

        result.ctx = uint32(ctx)

  )

  # shutdown function — stops both threads
  result.add(
    quote do:
      proc `shutdownFuncIdent`(
          ctx: uint32
      ) {.exportc: `shutdownFuncNameLit`, cdecl, dynlib.} =
        ensureLibCtxInit()
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
        freeCString(s)

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

  # Generate header file at compile time
  let outDir =
    detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
  generateHeaderFile(outDir)

  # Generate Python wrapper file when requested
  when defined(BrokerFfiApiGenPy):
    generatePythonFile(outDir)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
