## API Library Registration
## ------------------------
## Provides the `registerBrokerLibrary` macro that generates:
## 1. Library context lifecycle management (init/shutdown C exports)
## 2. Compile-time validation of mandatory InitRequest/DestroyRequest types
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
##   initRequest: InitRequest
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
): tuple[name: string, initRequest: NimNode, destroyRequest: NimNode, refType: NimNode] {.
    compileTime
.} =
  var name = ""
  var initReq: NimNode = nil
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
      of "initrequest":
        if value.kind == nnkStmtList and value.len == 1:
          initReq = value[0]
        else:
          initReq = value
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
  if initReq.isNil():
    error("registerBrokerLibrary requires an 'initRequest' field", body)
  if destroyReq.isNil():
    error("registerBrokerLibrary requires a 'destroyRequest' field", body)

  (name: name, initRequest: initReq, destroyRequest: destroyReq, refType: refTy)

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------

macro registerBrokerLibrary*(body: untyped): untyped =
  let config = parseLibraryConfig(body)
  let libName = config.name
  let initReqIdent = config.initRequest
  let destroyReqIdent = config.destroyRequest

  # Set library name for header generation
  gApiLibraryName = libName

  let initFuncName = libName & "_init"
  let shutdownFuncName = libName & "_shutdown"
  let freeStringFuncName = libName & "_free_string"

  let initFuncIdent = ident(initFuncName)
  let shutdownFuncIdent = ident(shutdownFuncName)
  let freeStringFuncIdent = ident(freeStringFuncName)

  let initFuncNameLit = newLit(initFuncName)
  let shutdownFuncNameLit = newLit(shutdownFuncName)
  let freeStringFuncNameLit = newLit(freeStringFuncName)

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

  result = newStmtList()

  # Compile-time validation: ensure InitRequest and DestroyRequest types exist
  result.add(
    quote do:
      when not compiles(typeof(`initReqIdent`)):
        {.
          error:
            "registerBrokerLibrary: initRequest type '" & astToStr(`initReqIdent`) &
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
        `procThreadArgIdent` = object
          ctx: BrokerContext
          shutdownChan: ptr AsyncChannel[bool]

        `delivThreadArgIdent` = object
          ctx: BrokerContext
          shutdownChan: ptr AsyncChannel[bool]

        `ctxEntryIdent` = object
          ctx: BrokerContext
          procThread: Thread[ptr `procThreadArgIdent`]
          delivThread: Thread[ptr `delivThreadArgIdent`]
          procShutdownChan: ptr AsyncChannel[bool]
          delivShutdownChan: ptr AsyncChannel[bool]
          active: bool

  )

  # Library initialization — must be called exactly once from the C/C++ app
  # before any other library functions. Initializes the Nim runtime, sets up
  # the GC for the foreign (C/C++) calling thread, and configures the stack bottom.
  let initLibFuncName = libName & "_initialize"
  let initLibFuncIdent = ident(initLibFuncName)
  let initLibFuncNameLit = newLit(initLibFuncName)
  let nimInitializedIdent = ident("g" & libName & "NimInitialized")
  let nimMainIdent = ident(libName & "NimMain")
  let nimMainImportName = newLit(libName & "NimMain")

  result.add(
    quote do:
      proc `nimMainIdent`() {.importc: `nimMainImportName`, cdecl.}

      var `nimInitializedIdent`: Atomic[bool]

      proc `initLibFuncIdent`() {.exportc: `initLibFuncNameLit`, cdecl, dynlib.} =
        if not `nimInitializedIdent`.exchange(true):
          `nimMainIdent`()
          when declared(setupForeignThreadGc):
            setupForeignThreadGc()
          when declared(nimGC_setStackBottom):
            var locals {.volatile, noinit.}: pointer
            locals = addr(locals)
            nimGC_setStackBottom(locals)

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
          # Library not initialized — call initialize first
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

  # Processing thread proc
  result.add(
    quote do:
      proc `procThreadProcIdent`(arg: ptr `procThreadArgIdent`) {.thread.} =
        setThreadBrokerContext(arg.ctx)

        when compiles(setupProviders(arg.ctx)):
          setupProviders(arg.ctx)

        proc awaitShutdown(
            shutdownChan: ptr AsyncChannel[bool]
        ) {.async: (raises: []).} =
          let recvRes = catch:
            await shutdownChan.recv()
          if recvRes.isErr():
            discard # channel closed, shutting down

        waitFor awaitShutdown(arg.shutdownChan)

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

          proc awaitShutdown(
              shutdownChan: ptr AsyncChannel[bool]
          ) {.async: (raises: []).} =
            let recvRes = catch:
              await shutdownChan.recv()
            if recvRes.isErr():
              discard

          waitFor awaitShutdown(arg.shutdownChan)

          # Cleanup: drop all registered event listeners
          `cleanupAllIdent`(arg.ctx)

    )
  elif hasEventHandlers:
    result.add(
      quote do:
        proc `delivThreadProcIdent`(arg: ptr `delivThreadArgIdent`) {.thread.} =
          setThreadBrokerContext(arg.ctx)
          `installProviderIdent`(arg.ctx)

          proc awaitShutdown(
              shutdownChan: ptr AsyncChannel[bool]
          ) {.async: (raises: []).} =
            let recvRes = catch:
              await shutdownChan.recv()
            if recvRes.isErr():
              discard

          waitFor awaitShutdown(arg.shutdownChan)

    )
  else:
    result.add(
      quote do:
        proc `delivThreadProcIdent`(arg: ptr `delivThreadArgIdent`) {.thread.} =
          setThreadBrokerContext(arg.ctx)

          proc awaitShutdown(
              shutdownChan: ptr AsyncChannel[bool]
          ) {.async: (raises: []).} =
            let recvRes = catch:
              await shutdownChan.recv()
            if recvRes.isErr():
              discard

          waitFor awaitShutdown(arg.shutdownChan)

    )

  # init function — creates context, both threads
  result.add(
    quote do:
      proc `initFuncIdent`(): uint32 {.exportc: `initFuncNameLit`, cdecl, dynlib.} =
        ensureLibCtxInit()
        var ctx = NewBrokerContext()
        # Context 0 is reserved as the C-side error sentinel
        if uint32(ctx) == 0:
          ctx = NewBrokerContext()

        # Create shutdown channels
        let procShutdownChan =
          cast[ptr AsyncChannel[bool]](createShared(AsyncChannel[bool], 1))
        discard procShutdownChan[].open()

        let delivShutdownChan =
          cast[ptr AsyncChannel[bool]](createShared(AsyncChannel[bool], 1))
        discard delivShutdownChan[].open()

        # Create processing thread arg
        let procArg =
          cast[ptr `procThreadArgIdent`](createShared(`procThreadArgIdent`, 1))
        procArg.ctx = ctx
        procArg.shutdownChan = procShutdownChan

        # Create delivery thread arg
        let delivArg =
          cast[ptr `delivThreadArgIdent`](createShared(`delivThreadArgIdent`, 1))
        delivArg.ctx = ctx
        delivArg.shutdownChan = delivShutdownChan

        # Allocate entry on shared heap — Thread objects must not be moved
        # after createThread (the pthread holds a pointer to them)
        let entry = cast[ptr `ctxEntryIdent`](createShared(`ctxEntryIdent`, 1))
        entry.ctx = ctx
        entry.procShutdownChan = procShutdownChan
        entry.delivShutdownChan = delivShutdownChan
        entry.active = true

        # Start delivery thread first (so provider is ready for requests)
        try:
          createThread(entry.delivThread, `delivThreadProcIdent`, delivArg)
        except ResourceExhaustedError:
          procShutdownChan[].close()
          delivShutdownChan[].close()
          deallocShared(procShutdownChan)
          deallocShared(delivShutdownChan)
          deallocShared(procArg)
          deallocShared(delivArg)
          deallocShared(entry)
          return 0'u32
        except Exception as e:
          deallocShared(entry)
          return 0'u32

        # Brief pause to let delivery thread start and register provider
        sleep(50)

        # Start processing thread
        try:
          createThread(entry.procThread, `procThreadProcIdent`, procArg)
        except ResourceExhaustedError:
          # Shut down delivery thread
          delivShutdownChan[].sendSync(true)
          joinThread(entry.delivThread)
          procShutdownChan[].close()
          delivShutdownChan[].close()
          deallocShared(procShutdownChan)
          deallocShared(delivShutdownChan)
          deallocShared(procArg)
          deallocShared(delivArg)
          deallocShared(entry)
          return 0'u32
        except Exception as e:
          deallocShared(entry)
          return 0'u32

        # Brief pause to let processing thread start and register providers
        sleep(50)

        withLock(`globalCtxsLockIdent`):
          `globalCtxsIdent`.add(entry)

        return uint32(ctx)

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
            if `globalCtxsIdent`[i].ctx == brokerCtx and `globalCtxsIdent`[i].active:
              entryPtr = `globalCtxsIdent`[i]
              break

        if entryPtr.isNil:
          return

        # Signal delivery thread shutdown first
        entryPtr.delivShutdownChan[].sendSync(true)
        joinThread(entryPtr.delivThread)

        # Then signal processing thread shutdown
        entryPtr.procShutdownChan[].sendSync(true)
        joinThread(entryPtr.procThread)

        # Mark inactive
        withLock(`globalCtxsLockIdent`):
          entryPtr.active = false

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
    "/* Call once before any other library function to initialize the Nim runtime */\n" &
      generateCFuncProto(initLibFuncName, "void", @[])
  )
  appendHeaderDecl(generateCFuncProto(initFuncName, "uint32_t", @[]))
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
