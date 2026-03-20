## API Library Registration
## ------------------------
## Provides the `registerBrokerLibrary` macro that generates:
## 1. Library context lifecycle management (init/shutdown C exports)
## 2. Compile-time validation of mandatory InitRequest/DestroyRequest types
## 3. C header file generation from accumulated broker declarations
## 4. Memory management helpers (free_string)
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

  # Thread argument type
  let threadArgIdent = ident(libName & "ThreadArg")
  let threadProcIdent = ident(libName & "ProcessingThread")
  let ctxEntryIdent = ident(libName & "CtxEntry")
  let globalCtxsIdent = ident("g" & libName & "Ctxs")
  let globalCtxsLockIdent = ident("g" & libName & "CtxsLock")
  let globalCtxsInitIdent = ident("g" & libName & "CtxsInit")

  result = newStmtList()

  # Compile-time validation: ensure InitRequest and DestroyRequest types exist
  # This is checked at compile time because the macros that define these types
  # must appear before registerBrokerLibrary.
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
        `threadArgIdent` = object
          ctx: BrokerContext
          shutdownChan: ptr AsyncChannel[bool]

        `ctxEntryIdent` = object
          ctx: BrokerContext
          thread: Thread[ptr `threadArgIdent`]
          shutdownChan: ptr AsyncChannel[bool]
          active: bool

  )

  # Global context registry
  result.add(
    quote do:
      var `globalCtxsIdent`: seq[`ctxEntryIdent`]
      var `globalCtxsLockIdent`: Lock
      var `globalCtxsInitIdent`: Atomic[int]

      proc ensureLibCtxInit() =
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

  # Processing thread proc
  result.add(
    quote do:
      proc `threadProcIdent`(arg: ptr `threadArgIdent`) {.thread.} =
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

  # init function
  result.add(
    quote do:
      proc `initFuncIdent`(): uint32 {.exportc: `initFuncNameLit`, cdecl, dynlib.} =
        ensureLibCtxInit()
        let ctx = NewBrokerContext()
        let shutdownChan =
          cast[ptr AsyncChannel[bool]](createShared(AsyncChannel[bool], 1))
        discard shutdownChan[].open()

        let arg = cast[ptr `threadArgIdent`](createShared(`threadArgIdent`, 1))
        arg.ctx = ctx
        arg.shutdownChan = shutdownChan

        var entry = `ctxEntryIdent`(ctx: ctx, shutdownChan: shutdownChan, active: true)
        try:
          createThread(entry.thread, `threadProcIdent`, arg)
        except ResourceExhaustedError:
          shutdownChan[].close()
          deallocShared(shutdownChan)
          deallocShared(arg)
          return 0'u32

        withLock(`globalCtxsLockIdent`):
          `globalCtxsIdent`.add(entry)

        return uint32(ctx)

  )

  # shutdown function
  result.add(
    quote do:
      proc `shutdownFuncIdent`(
          ctx: uint32
      ) {.exportc: `shutdownFuncNameLit`, cdecl, dynlib.} =
        ensureLibCtxInit()
        let brokerCtx = BrokerContext(ctx)

        var entryIdx = -1
        withLock(`globalCtxsLockIdent`):
          for i in 0 ..< `globalCtxsIdent`.len:
            if `globalCtxsIdent`[i].ctx == brokerCtx and `globalCtxsIdent`[i].active:
              entryIdx = i
              break

        if entryIdx < 0:
          return

        # Signal shutdown
        let shutdownChan = `globalCtxsIdent`[entryIdx].shutdownChan
        shutdownChan[].sendSync(true)

        # Wait for thread to finish
        joinThread(`globalCtxsIdent`[entryIdx].thread)

        # Mark inactive and clean up
        withLock(`globalCtxsLockIdent`):
          `globalCtxsIdent`[entryIdx].active = false

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
  appendHeaderDecl(generateCFuncProto(initFuncName, "uint32_t", @[]))
  appendHeaderDecl(generateCFuncProto(shutdownFuncName, "void", @[("ctx", "uint32_t")]))
  appendHeaderDecl(generateCFuncProto(freeStringFuncName, "void", @[("s", "char*")]))

  # Generate header file at compile time
  # Prefer explicit override, then compiler --outdir, then the directory of --out.
  let outDir =
    detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
  generateHeaderFile(outDir)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
