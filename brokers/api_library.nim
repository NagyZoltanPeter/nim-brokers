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
import ./internal/api_codegen_cbor_py
import ./internal/api_codegen_cbor_rust
import ./internal/api_codegen_cbor_go
import ./internal/api_codegen_cbor_cddl
import ./internal/api_codegen_cmake
import ./internal/api_cbor_descriptor
import ./internal/api_cbor_subs_registry
import ./internal/api_cbor_tuple
import ./internal/api_cbor_courier
import ./internal/mt_broker_common

export api_cbor_descriptor, api_cbor_subs_registry, api_cbor_tuple, api_cbor_courier
export mt_broker_common

export results, chronos, chronicles, broker_context, api_common

# ---------------------------------------------------------------------------
# Macro helpers
# ---------------------------------------------------------------------------

proc parseLibraryConfig(
    body: NimNode
): tuple[
  name: string,
  version: string,
  initializeRequest: NimNode,
  shutdownRequest: NimNode,
  refType: NimNode,
  ffiMode: BrokerFfiMode,
  ffiModeExplicit: bool,
] {.compileTime.} =
  var name = ""
  var version = "0.1.0"
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
      of "version":
        var v = value
        if v.kind == nnkStmtList and v.len == 1:
          v = v[0]
        if v.kind == nnkStrLit:
          version = v.strVal
        else:
          error("version must be a string literal", v)
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
    version: version,
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

proc registerBrokerLibraryCborImpl(
  body: NimNode,
  config:
    tuple[
      name: string,
      version: string,
      initializeRequest: NimNode,
      shutdownRequest: NimNode,
      refType: NimNode,
      ffiMode: BrokerFfiMode,
      ffiModeExplicit: bool,
    ],
): NimNode

proc registerBrokerLibraryImpl(body: NimNode): NimNode =
  let config = parseLibraryConfig(body)

  # The native FFI codegen surface was retired — see doc/CBOR_Refactoring.md.
  # `resolveFfiMode` still runs as a consistency check on the
  # `ffiMode:` field (and rejects any leftover `mfNative` setting).
  discard resolveFfiMode(config.ffiMode, config.ffiModeExplicit, config.name)

  registerBrokerLibraryCborImpl(body, config)

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
        version: string,
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
  # Phase 10: subscription state lives in a hand-rolled shared-heap registry
  # (`api_cbor_subs_registry`). The previous codegen kept a GC'd
  # `Table[(uint32, string), seq[Subscription]]` plus `Lock` here; that broke
  # `--mm:refc` cross-thread delivery because subscribe/unsubscribe run on
  # foreign caller threads while the listener fires on the processing thread.
  let subsRegIdent = ident("g" & libName & "CborSubsReg")
  let subsHandleIdent = ident("g" & libName & "CborNextSubHandle")
  let subscribeFuncName = libName & "_subscribe"
  let subscribeFuncNameLit = newLit(subscribeFuncName)
  let subscribeFuncIdent = ident(subscribeFuncName)
  let unsubscribeFuncName = libName & "_unsubscribe"
  let unsubscribeFuncNameLit = newLit(unsubscribeFuncName)
  let unsubscribeFuncIdent = ident(unsubscribeFuncName)
  let knownEventPredIdent = ident(libName & "CborIsKnownEvent")
  let installAllListenersIdent = ident(libName & "CborInstallAllListeners")

  # Discovery / introspection identifiers (Phase 6).
  let listApisFuncName = libName & "_listApis"
  let listApisFuncNameLit = newLit(listApisFuncName)
  let listApisFuncIdent = ident(listApisFuncName)
  let getSchemaFuncName = libName & "_getSchema"
  let getSchemaFuncNameLit = newLit(getSchemaFuncName)
  let getSchemaFuncIdent = ident(getSchemaFuncName)
  let descriptorIdent = ident("g" & libName & "CborDescriptor")
  let apiListIdent = ident("g" & libName & "CborApiList")
  let descriptorBuildIdent = ident(libName & "CborBuildDescriptor")
  let apiListBuildIdent = ident(libName & "CborBuildApiList")

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
          # Part C — buffer courier. `courier` is allocated in
          # `_createContext` and freed in `_shutdown`. `courierSignal` is
          # the processing thread's broker dispatch signal, published by
          # the processing thread once its chronos loop is up so a foreign
          # `<lib>_call` can wake it after enqueuing a request.
          courier: ptr CborCourier
          courierSignal: ThreadSignalPtr

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

      var `ctxsIdent`: seq[ptr `ctxEntryIdent`]
      var `ctxsLockIdent`: Lock
      var `ctxsInitIdent`: Atomic[int]

      # Subscription registry: shared-heap hash table from
      # `api_cbor_subs_registry`. Lazily allocated in `_initialize`.
      var `subsRegIdent`: ptr SubsRegistry
      var `subsHandleIdent`: Atomic[uint64]

      var `nimInitFlagIdent`: Atomic[int]
      var `gcRegFlagIdent` {.threadvar.}: bool
  )

  # ------------------------------------------------------------------
  # `<lib>_version` — static semver baked from `registerBrokerLibrary`.
  # ------------------------------------------------------------------
  let cborVersionFuncName = libName & "_version"
  let cborVersionFuncNameLit = newLit(cborVersionFuncName)
  let cborVersionFuncIdent = ident(cborVersionFuncName)
  let cborVersionConstIdent = ident("g" & libName & "VersionStr")
  let cborVersionStrLit = newLit(config.version)
  result.add(
    quote do:
      const `cborVersionConstIdent`: cstring = `cborVersionStrLit`
      proc `cborVersionFuncIdent`*(): cstring {.
          exportc: `cborVersionFuncNameLit`, cdecl, dynlib
      .} =
        `cborVersionConstIdent`

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
          `subsRegIdent` = subsRegistryNew()
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
            # Phase 10: shared-heap snapshot + shared-heap encode buffer.
            # Nothing GC'd crosses the callback fan-out, so this path is
            # safe under both --mm:orc and --mm:refc.
            var snap: ptr UncheckedArray[SubSnapshot] = nil
            var snapLen: int = 0
            subsRegistrySnapshot(
              `subsRegIdent`, uint32(ctx), `eventNameLit`.cstring, snap, snapLen
            )
            if snapLen == 0:
              return
            var payloadBuf: pointer = nil
            var payloadLen: int = 0
            let encRes = cborEncodeShared(evt, payloadBuf, payloadLen)
            if encRes.isErr:
              subsRegistrySnapshotFree(snap)
              return
            for i in 0 ..< snapLen:
              let cbPtr = snap[i].cb
              if cbPtr.isNil:
                continue
              let cbTyped = cast[`eventCallbackTypeIdent`](cbPtr)
              cbTyped(
                uint32(ctx),
                `eventNameLit`.cstring,
                payloadBuf,
                int32(payloadLen),
                snap[i].userData,
              )
            if not payloadBuf.isNil:
              deallocShared(payloadBuf)
            subsRegistrySnapshotFree(snap)

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
        # `eventNameC` is owned by the foreign caller; the registry copies it
        # into shared heap on insertion, so we don't need to keep `name`
        # alive past this call.
        subsRegistryAdd(`subsRegIdent`, ctx, eventNameC, h, cast[pointer](cb), userData)
        return h

      proc `unsubscribeFuncIdent`*(
          ctx: uint32, eventNameC: cstring, handle: uint64
      ): int32 {.exportc: `unsubscribeFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if eventNameC.isNil:
          return -1'i32
        if handle == 0'u64:
          # Drop every subscription for this (ctx, name).
          return subsRegistryRemoveAllForKey(`subsRegIdent`, ctx, eventNameC)
        return subsRegistryRemoveOne(`subsRegIdent`, ctx, eventNameC, handle)

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

        # ----------------------------------------------------------------
        # Part C — buffer courier. The processing thread owns CBOR decode,
        # the provider call, and CBOR encode. A foreign `<lib>_call` hands
        # us a raw request buffer over `arg.courier.chan` and blocks on a
        # response slot; we wake on the shared broker dispatch signal.
        # ----------------------------------------------------------------
        proc handleCourierMsg(m: CborCallMsg) {.async: (raises: []), gcsafe.} =
          # Copy the request bytes off the shared buffer, then free it —
          # ownership of `m.reqBuf` transferred to us via the channel.
          var nimReq = newSeq[byte](m.reqLen.int)
          if m.reqLen > 0 and not m.reqBuf.isNil:
            copyMem(addr nimReq[0], m.reqBuf, m.reqLen.int)
          if not m.reqBuf.isNil:
            deallocShared(m.reqBuf)
          let apiName = $cast[cstring](addr m.apiName[0])
          var respBuf: pointer = nil
          var respLen: int32 = 0
          var status: int32 = 0
          if not `knownNamePredIdent`(apiName):
            let em = "unknown apiName: " & apiName
            let b = allocShared0(em.len)
            if em.len > 0:
              copyMem(b, unsafeAddr em[0], em.len)
            respBuf = b
            respLen = int32(em.len)
            status = -4'i32
          else:
            let dispRes = catch:
              await `dispatchProcIdent`(apiName, arg.ctx, nimReq)
            if dispRes.isErr():
              status = -10'i32
            else:
              let respBytes = dispRes.get()
              if respBytes.len > 0:
                let b = allocShared0(respBytes.len)
                copyMem(b, unsafeAddr respBytes[0], respBytes.len)
                respBuf = b
                respLen = int32(respBytes.len)
          completeSlot(arg.courier, m.slotIdx.int, respBuf, respLen, status)

        # Drained by the shared `brokerDispatchLoop` whenever the dispatch
        # signal fires. Each message is handled on its own spawned
        # coroutine so a slow provider does not stall the drain.
        proc courierPoll(): int {.gcsafe, raises: [].} =
          var didWork = 0
          while true:
            var m: CborCallMsg
            if not tryDequeue(addr arg.courier.ring, m):
              break
            asyncSpawn handleCourierMsg(m)
            didWork = 1
          didWork

        # Publish this thread's dispatch signal so a foreign `<lib>_call`
        # can wake us, register the courier poller, and start the loop.
        # Done BEFORE `processingReady = 1` so the first `_call` (which can
        # only arrive after `createContext` returns) is always serviced.
        arg.courierSignal = getOrInitBrokerSignal()
        registerBrokerPoller(courierPoll)
        ensureBrokerDispatchStarted()

        arg.processingReady.store(1, moRelease)

        proc awaitShutdown(flag: ptr Atomic[int]) {.async: (raises: []).} =
          while flag[].load(moAcquire) != 1:
            let s = catch:
              await sleepAsync(milliseconds(5))
            if s.isErr():
              discard

        waitFor awaitShutdown(addr arg.shutdownFlag)
        # Part C: tear down the dispatch-loop coroutine cleanly before the
        # thread exits. `_shutdown` waits for `courier.inFlight` to reach 0
        # (while this thread is still handling) before it sets
        # `shutdownFlag`, so no courier message is in flight here.
        stopBrokerDispatchHere()

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
        # Part C — courier: 64 response slots = ceiling on concurrent
        # in-flight `<lib>_call`s; a call past that fails fast.
        arg.courier = newCborCourier(64)
        arg.courierSignal = nil

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
          freeCborCourier(arg.courier)
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
          freeCborCourier(arg.courier)
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

        # Part C — drain in-flight `_call`s BEFORE stopping the processing
        # thread. `active` is already false (set under the lock above) so
        # no new call enters; in-flight calls complete (the processing
        # thread is still handling) and decrement `inFlight`. Only once
        # inFlight reaches 0 is the channel guaranteed quiescent, so
        # signalling shutdown + freeing the courier cannot race a `_call`.
        # A bounded timeout guards against a hung provider (best-effort).
        block:
          let courier = entryToShutdown.arg.courier
          if not courier.isNil:
            var waitedMs = 0
            const drainTimeoutMs = 5000
            while courier.inFlight.load(moAcquire) > 0 and waitedMs < drainTimeoutMs:
              sleep(1)
              inc waitedMs

        entryToShutdown.arg.shutdownFlag.store(1, moRelease)
        joinThread(entryToShutdown.procThread)
        # Phase 10: free this ctx's subscription state *after* the
        # processing thread is joined. The processing thread is the
        # delivery thread, so the join is the only barrier we need to
        # guarantee no concurrent listener is mid-snapshot.
        subsRegistryFreeForCtx(`subsRegIdent`, ctx)
        if not entryToShutdown.arg.processingErrorMessage.isNil:
          freeCString(entryToShutdown.arg.processingErrorMessage)
        # Part C — free the courier. Phase 1a: `<lib>_call` does not yet
        # use the courier, so freeing right after joinThread is safe (no
        # in-flight calls). Phase 1b adds the inFlight-counter wait.
        freeCborCourier(entryToShutdown.arg.courier)
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
        # Part C — buffer courier. This runs on the foreign caller's
        # thread and does NO CBOR decode and NO chronos loop: it hands the
        # raw request buffer to the processing thread and blocks on a
        # response slot. `reqBuf` ownership transfers to the processing
        # thread on a successful `send`; every error path frees it here.
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        if apiNameC.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -2'i32
        if reqLen < 0 or reqLen.int > `bufSizeCap`:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -3'i32
        let nameLen = apiNameC.len
        if nameLen >= CborApiNameMax:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -2'i32

        # Resolve ctx -> courier. `inFlight` is bumped under the SAME lock
        # `_shutdown` uses to flip `active`, so once shutdown has run no
        # new call can enter; `_shutdown` then waits for inFlight -> 0.
        var courier: ptr CborCourier = nil
        var courierSig: ThreadSignalPtr = nil
        withLock `ctxsLockIdent`:
          for i in 0 ..< `ctxsIdent`.len:
            let e = `ctxsIdent`[i]
            if uint32(e.ctx) == ctx and e.active:
              courier = e.arg.courier
              courierSig = e.arg.courierSignal
              discard courier.inFlight.fetchAdd(1, moAcquireRelease)
              break
        if courier.isNil:
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -5'i32

        let slotIdx = claimSlot(courier)
        if slotIdx < 0:
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -6'i32

        var msg: CborCallMsg
        if nameLen > 0:
          copyMem(addr msg.apiName[0], apiNameC, nameLen)
        # `msg` is stack-zero-initialised, so apiName stays NUL-terminated.
        msg.reqBuf = reqBuf
        msg.reqLen = reqLen
        msg.slotIdx = int32(slotIdx)
        # Ownership of reqBuf transfers into the ring here. Enqueue is
        # backstopped by the slot claim above (ring.cap == slotCount), so
        # a false return is a programming error rather than backpressure;
        # we still handle it cleanly: undo the slot + inFlight, free
        # reqBuf, return -6.
        if not tryEnqueue(addr courier.ring, msg):
          releaseSlot(courier, slotIdx)
          discard courier.inFlight.fetchSub(1, moAcquireRelease)
          if not reqBuf.isNil:
            deallocShared(reqBuf)
          return -6'i32
        if not courierSig.isNil:
          discard courierSig.fireSync()

        let res = waitSlot(courier, slotIdx)
        releaseSlot(courier, slotIdx)
        respBufOut[] = res.respBuf
        respLenOut[] = res.respLen
        discard courier.inFlight.fetchSub(1, moAcquireRelease)
        return res.status

  )

  # ------------------------------------------------------------------
  # Generated artifacts: write the C header + CDDL schema next to the
  # build output so foreign-language wrappers can pick them up via `-I`.
  # ------------------------------------------------------------------
  let outDir =
    detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
  var requestNames: seq[string] = @[]
  for e in entries:
    requestNames.add(e.apiName)
  var eventNames: seq[string] = @[]
  for e in eventEntries:
    eventNames.add(e.apiName)
  generateCborCHeaderFile(outDir, libName, config.version, requestNames, eventNames)
  generateCborCppHeaderFile(outDir, libName, entries, eventEntries)
  when defined(BrokerFfiApiGenPy):
    generateCborPyFile(outDir, libName, entries, eventEntries)
  when defined(BrokerFfiApiGenRust):
    generateCborRustFile(outDir, libName, entries, eventEntries)
  when defined(BrokerFfiApiGenGo):
    generateCborGoFile(outDir, libName, entries, eventEntries)

  generateCMakePackageFiles(
    outDir, libName, config.version, cborMode = true, hasCpp = true
  )

  # Emit the CDDL schema and capture its text for the runtime descriptor.
  let cddlText =
    generateCborCddlFile(outDir, libName, entries, eventEntries, gApiTypeRegistry)

  # ------------------------------------------------------------------
  # Discovery API (Phase 6): runtime descriptor + `<lib>_listApis` /
  # `<lib>_getSchema` C exports. The descriptor is built lazily on the
  # first call; subsequent calls re-use the cached value.
  # ------------------------------------------------------------------
  let descriptorOnceIdent = ident("g" & libName & "CborDescriptorOnce")
  let apiListOnceIdent = ident("g" & libName & "CborApiListOnce")

  # Build the descriptor population body as a Nim source string. Doing it
  # this way keeps every string / int literal in straight Nim code rather
  # than having to splice deeply nested AST through `quote do:`.
  var buildSrc = "proc " & libName & "CborBuildDescriptor(): LibraryDescriptor =\n"
  buildSrc.add("  result.libName = " & escape(libName) & "\n")
  buildSrc.add("  result.cddl = " & escape(cddlText) & "\n")
  buildSrc.add("  result.requests = @[\n")
  for r in entries:
    buildSrc.add("    ApiRequestInfo(apiName: " & escape(r.apiName) & ",\n")
    let argsTypeRepr =
      if r.argFields.len > 0:
        upperCamel(r.apiName) & "Args"
      else:
        ""
    buildSrc.add("      argsType: " & escape(argsTypeRepr) & ",\n")
    buildSrc.add("      argFields: @[\n")
    for (fname, ftype) in r.argFields:
      buildSrc.add(
        "        ApiFieldInfo(name: " & escape(fname) & ", nimType: " & escape(ftype) &
          "),\n"
      )
    buildSrc.add("      ],\n")
    buildSrc.add("      responseType: " & escape(r.responseTypeName) & "),\n")
  buildSrc.add("  ]\n")
  buildSrc.add("  result.events = @[\n")
  for e in eventEntries:
    buildSrc.add(
      "    ApiEventInfo(apiName: " & escape(e.apiName) & ", payloadType: " &
        escape(e.typeName) & "),\n"
    )
  buildSrc.add("  ]\n")
  buildSrc.add("  result.types = @[\n")
  for t in gApiTypeRegistry:
    if t.name.endsWith("CborArgs"):
      continue
    let kindStr =
      case t.kind
      of atkObject: "object"
      of atkEnum: "enum"
      of atkAlias: "alias"
      of atkDistinct: "distinct"
    buildSrc.add(
      "    ApiTypeInfo(name: " & escape(t.name) & ", kind: " & escape(kindStr) & ",\n"
    )
    buildSrc.add("      fields: @[\n")
    for f in t.fields:
      buildSrc.add(
        "        ApiFieldInfo(name: " & escape(f.name) & ", nimType: " &
          escape(f.nimType) & "),\n"
      )
    buildSrc.add("      ],\n")
    buildSrc.add("      enumValues: @[\n")
    for v in t.enumValues:
      buildSrc.add(
        "        ApiEnumValueInfo(name: " & escape(v.name) & ", ordinal: " & $v.ordinal &
          "),\n"
      )
    buildSrc.add("      ],\n")
    buildSrc.add("      underlyingType: " & escape(t.underlyingType) & "),\n")
  buildSrc.add("  ]\n")

  # Build the lightweight ApiList in the same fashion.
  buildSrc.add("\nproc " & libName & "CborBuildApiList(): ApiList =\n")
  buildSrc.add("  result.libName = " & escape(libName) & "\n")
  buildSrc.add("  result.requests = @[\n")
  for r in entries:
    buildSrc.add("    " & escape(r.apiName) & ",\n")
  buildSrc.add("  ]\n")
  buildSrc.add("  result.events = @[\n")
  for e in eventEntries:
    buildSrc.add("    " & escape(e.apiName) & ",\n")
  buildSrc.add("  ]\n")

  try:
    result.add(parseStmt(buildSrc))
  except ValueError as e:
    error("CBOR FFI: failed to parse generated descriptor builder: " & e.msg)

  let ensureDescriptorIdent = ident(libName & "CborEnsureDescriptor")
  let ensureApiListIdent = ident(libName & "CborEnsureApiList")

  # Cached singletons + lazy initialisers.
  result.add(
    quote do:
      var `descriptorOnceIdent`: bool
      var `descriptorIdent`: LibraryDescriptor
      var `apiListOnceIdent`: bool
      var `apiListIdent`: ApiList

      proc `ensureDescriptorIdent`() {.gcsafe.} =
        {.cast(gcsafe).}:
          if not `descriptorOnceIdent`:
            `descriptorIdent` = `descriptorBuildIdent`()
            `descriptorOnceIdent` = true

      proc `ensureApiListIdent`() {.gcsafe.} =
        {.cast(gcsafe).}:
          if not `apiListOnceIdent`:
            `apiListIdent` = `apiListBuildIdent`()
            `apiListOnceIdent` = true

  )

  # `<lib>_listApis` — returns a JSON-encoded `ApiList` string.
  result.add(
    quote do:
      proc `listApisFuncIdent`*(
          respBufOut: ptr pointer, respLenOut: ptr int32
      ): int32 {.exportc: `listApisFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        `ensureApiListIdent`()
        var jsonStr: string
        try:
          jsonStr = toJsonString(`apiListIdent`)
        except CatchableError:
          return -10'i32
        if jsonStr.len > 0:
          let buf = allocShared0(jsonStr.len)
          copyMem(buf, addr jsonStr[0], jsonStr.len)
          respBufOut[] = buf
          respLenOut[] = int32(jsonStr.len)
        return 0'i32

  )

  # `<lib>_getSchema` — returns a JSON-encoded `LibraryDescriptor` string.
  result.add(
    quote do:
      proc `getSchemaFuncIdent`*(
          respBufOut: ptr pointer, respLenOut: ptr int32
      ): int32 {.exportc: `getSchemaFuncNameLit`, cdecl, dynlib.} =
        ensureForeignThreadGc()
        if respBufOut.isNil or respLenOut.isNil:
          return -1'i32
        respBufOut[] = nil
        respLenOut[] = 0
        `ensureDescriptorIdent`()
        var jsonStr: string
        try:
          jsonStr = toJsonString(`descriptorIdent`)
        except CatchableError:
          return -10'i32
        if jsonStr.len > 0:
          let buf = allocShared0(jsonStr.len)
          copyMem(buf, addr jsonStr[0], jsonStr.len)
          respBufOut[] = buf
          respLenOut[] = int32(jsonStr.len)
        return 0'i32

  )

  when defined(brokerDebug):
    echo "[brokers/cbor] registerBrokerLibraryCborImpl emitted runtime for '" & libName &
      "' with " & $entries.len & " request adapters and " & $eventEntries.len &
      " event entries"
    echo result.repr

{.pop.}

macro registerBrokerLibrary*(body: untyped): untyped =
  ## Generates the full shared-library surface for a broker FFI library.
  ## A no-op unless one of `-d:BrokerFfiApi`, `-d:BrokerFfiApiCBOR`, or
  ## `-d:BrokerFfiApiNative` is set, so client code never needs a
  ## `when defined(...)` guard around it. `-d:BrokerFfiApiCBOR` and
  ## `-d:BrokerFfiApiNative` each enable FFI codegen on their own and
  ## additionally select the strategy; `-d:BrokerFfiApi` enables FFI
  ## codegen and defaults to the CBOR strategy.
  when defined(BrokerFfiApi) or defined(BrokerFfiApiCBOR) or defined(BrokerFfiApiNative):
    registerBrokerLibraryImpl(body)
  else:
    newStmtList()
