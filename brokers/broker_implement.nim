## BrokerImplement — derived implementation of a BrokerInterface
## (doc/HIERARCHICAL_BROKERS_PLAN.md, phase P4).
##
##   type MyServiceImpl = ref object of IMyService
##     db: Database
##
##   BrokerImplement MyServiceImpl of IMyService:
##     proc new(T: typedesc[MyServiceImpl], db: Database): MyServiceImpl =
##       MyServiceImpl(db: db)        ## natural ctor: build + return a bare
##                                    ## instance (no ctx, no providers)
##     method getHealth(self: MyServiceImpl): Future[Result[GetHealth, string]] =
##       ok(GetHealth(...))           ## raw method body for each request verb
##
## An optional `proc init(self: MyServiceImpl)` hook may also be declared; it
## runs AFTER `self.brokerCtx` is bound and BEFORE providers are wired, so it can
## derive per-instance state from `self.brokerCtx` (which the bare `new` cannot).
##
## Generates:
##   * `MyServiceImpl.create(db = ...)` — allocate a fresh instance brokerCtx,
##     call the user `new`, and wire per-instance provider closures;
##   * `MyServiceImpl.createUnderContext(ctx, db = ...)` — same, but ADOPT an
##     externally-supplied `ctx` (the FFI library ctx, or a parent's sub-ctx);
##   * `close(self)` — clears those providers, breaking the instance<->closure
##     cycle (mandatory under --mm:refc) and freeing the instance ctx for reuse.
##
## Each request provider closure dispatches to the raw `<verb>Impl` body
## (capturing `self`). The public call surface is the interface's tunneling proc
## (`<Broker>.request(self.brokerCtx, …)`), so direct/base-typed calls route
## through the broker rather than a direct vtable call. The user `new` returns a
## bare, unwired instance — call `create` / `createUnderContext` to get a working
## one.

import std/[macros, strutils, atomics]
import chronos, results
import ./broker_context
import ./request_broker, ./event_broker
import ./internal/helper/broker_utils
import ./internal/broker_debug

export chronos, results, broker_context, request_broker, event_broker

proc canonPragma(async: bool): NimNode {.compileTime.} =
  ## Canonical override pragma matching the BrokerInterface abstract base
  ## (byte-identical async/raises/gcsafe is required for method dispatch).
  let src =
    if async:
      "proc d() {.async: (raises: []), gcsafe.} = discard"
    else:
      "proc d() {.gcsafe, raises: [].} = discard"
  parseStmt(src)[0][4]

proc isAsyncRet(ret: NimNode): bool {.compileTime.} =
  ret.kind == nnkBracketExpr and ret.len >= 1 and ret[0].kind == nnkIdent and
    ret[0].eqIdent("Future")

proc baseName(n: NimNode): NimNode {.compileTime.} =
  if n.kind == nnkPostfix:
    n[1]
  else:
    n

macro BrokerImplement*(args: varargs[untyped]): untyped =
  ## See module docs. Invoked as `BrokerImplement Impl of IFace: <body>`.
  if args.len < 2:
    macros.error("BrokerImplement requires `Impl of IFace:` and a body")
  let body = args[^1]
  if body.kind != nnkStmtList:
    macros.error("BrokerImplement body must be a `:` block")
  let infix = args[0]
  if infix.kind != nnkInfix or not infix[0].eqIdent("of"):
    macros.error(
      "BrokerImplement must be written `BrokerImplement Impl of IFace:`", infix
    )
  let implName = infix[1]
  let implStr = $implName
  let ifaceStr = $infix[2]

  result = newStmtList()

  var ctorParams: seq[NimNode] = @[] # user `new` params after the `T: typedesc`
  var userNew: NimNode = nil # the user-authored `proc new`, re-emitted verbatim
  var initBody: NimNode = nil # optional `proc init(self: Impl)` post-context body
  let postInitName = ident(implStr & "PostInit")
  # (verb, brokerName, argParams, payloadRepr, async)
  var methods: seq[(string, string, seq[NimNode], string, bool)] = @[]

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      if baseName(stmt[0]).eqIdent("new"):
        if userNew != nil:
          macros.error("BrokerImplement: duplicate `new` ctor", stmt)
        let p = stmt.params
        # params: [returnType, T: typedesc[Impl], ...ctorArgs]; the user `new`
        # allocates and RETURNS a bare instance — no ctx, no providers.
        if p.len < 2:
          macros.error(
            "BrokerImplement `new` must take `T: typedesc[" & implStr &
              "]` as its first parameter",
            stmt,
          )
        for i in 2 ..< p.len: # skip return type (0) and the typedesc dispatcher (1)
          ctorParams.add(copyNimTree(p[i]))
        userNew = copyNimTree(stmt)
      elif baseName(stmt[0]).eqIdent("init"):
        # Optional post-context hook: runs AFTER `self.brokerCtx` is bound and
        # BEFORE providers are wired, so it may derive per-instance state from
        # `self.brokerCtx`. Written `proc init(self: Impl) = …` (explicit self).
        if initBody != nil:
          macros.error("BrokerImplement: duplicate `init` hook", stmt)
        let p = stmt.params
        if p.len != 2 or p[1].len != 3 or not p[1][1].eqIdent(implStr):
          macros.error(
            "BrokerImplement `init` must be `proc init(self: " & implStr & ")`", stmt
          )
        initBody = copyNimTree(stmt.body)
      else:
        macros.error(
          "BrokerImplement only allows `new` / `init` procs and `method` overrides",
          stmt,
        )
    of nnkMethodDef:
      let verb = $baseName(stmt[0])
      let p = stmt.params
      let ret = p[0]
      let async = isAsyncRet(ret)
      let payload = extractResultOk(ret, async)
      if payload.isNil:
        macros.error(
          "method `" & verb & "` must return " &
            (if async: "Future[Result[T, string]]" else: "Result[T, string]"),
          stmt,
        )
      # Emit the user's method body as a PRIVATE `<verb>Impl` proc — NOT a
      # virtual `method` override. The public entry point is the interface's
      # tunneling proc (`<Broker>.request(self.brokerCtx, …)`); the provider
      # closure below calls this raw `<verb>Impl` on the owning thread. This is
      # the only call site of the raw body, so a direct `instance.verb(…)` (or
      # `IFace(instance).verb(…)`) routes through the broker — honoring mocks,
      # MT cross-thread tunneling, and thread affinity — instead of bypassing it.
      let implProc = nnkProcDef.newTree(
        ident(verb & "Impl"), # private (unexported): broker-internal raw body
        newEmptyNode(),
        newEmptyNode(),
        copyNimTree(stmt.params),
        canonPragma(async),
        newEmptyNode(),
        copyNimTree(stmt.body),
      )
      result.add(implProc)
      var margs: seq[NimNode] = @[]
      for i in 2 ..< p.len: # skip return (0) and self (1)
        margs.add(copyNimTree(p[i]))
      methods.add((verb, capitalizeAscii(verb), margs, payload.repr.strip(), async))
    of nnkEmpty, nnkCommentStmt:
      discard
    else:
      macros.error(
        "BrokerImplement only allows `new` / `init` procs and `method` overrides", stmt
      )

  # Compile-time fulfillment check: every request verb declared in the
  # interface must have a corresponding method override in the implementation.
  let ifaceVerbs = interfaceRequestVerbs(ifaceStr)
  for (verb, typeName) in ifaceVerbs:
    var found = false
    for m in methods:
      if m[0] == verb:
        found = true
        break
    if not found:
      macros.error(
        "BrokerImplement " & implStr & ": missing method override for '" & verb &
          "' (request type " & typeName & ") declared in " & ifaceStr
      )

  # Per-class context allocation state.
  let classCtxVar = ident(implStr & "BrokerClassCtx")
  let instCounter = ident(implStr & "BrokerInstCounter")
  let setupName = ident(implStr & "SetupProviders")
  result.add(
    quote do:
      # classCtx allocated once at module init (immutable -> race-free and
      # gcsafe to read); per-instance instanceCtx from an atomic counter.
      let `classCtxVar` = newClassCtx()
      var `instCounter` {.global.}: Atomic[uint16]
  )

  # setupProviders — register a per-instance provider closure per request that
  # dispatches to the raw `<verb>Impl` body (capturing `self`). This is the only
  # call site of the raw body; the public entry point is the interface's
  # tunneling proc, so all calls route through the broker.
  var setupSrc = "proc " & $setupName & "(self: " & implStr & ") {.gcsafe.} =\n"
  if methods.len == 0:
    setupSrc.add("  discard\n")
  for (verb, brokerName, margs, payload, async) in methods:
    var paramDecls = ""
    var argNames = ""
    for a in margs:
      paramDecls.add((if paramDecls.len > 0: ", " else: "") & a.repr.strip())
      for j in 0 ..< a.len - 2:
        argNames.add((if argNames.len > 0: ", " else: "") & $baseName(a[j]))
    let ret =
      if async:
        "Future[Result[" & payload & ", string]]"
      else:
        "Result[" & payload & ", string]"
    # Pragma must match the broker's generated provider proc type
    # (request_broker `makeProcType`): plain `{.async.}` for async,
    # `{.gcsafe, raises: [CatchableError].}` for sync.
    let prag = if async: "{.async.}" else: "{.gcsafe, raises: [CatchableError].}"
    let call = (if async: "await " else: "") & "self." & verb & "Impl(" & argNames & ")"
    setupSrc.add(
      "  discard " & brokerName & ".setProvider(self.brokerCtx, proc(" & paramDecls &
        "): " & ret & " " & prag & " =\n    " & call & ")\n"
    )
  result.add(parseStmt(setupSrc))

  # Constructor surface (the user authors a natural `proc new` that allocates +
  # returns a BARE instance; our generated wrappers decorate it with ctx binding
  # + provider wiring):
  #   * `Impl.new(args)`              — user-authored, re-emitted verbatim;
  #                                     bare instance, no ctx, no providers.
  #   * `Impl.createUnderContext(ctx, args)` — adopt an externally-supplied ctx
  #                                     (the FFI lib ctx, or a parent's sub-ctx).
  #   * `Impl.create(args)`           — allocate a fresh instance ctx, then
  #                                     decorate via createUnderContext.
  # If the user omits `new`, synthesize a zero-arg default.
  if userNew != nil:
    result.add(userNew)
  else:
    result.add(
      parseStmt(
        "proc new*(T: typedesc[" & implStr & "]): " & implStr & " = " & implStr & "()"
      )
    )

  # Optional post-context init hook, emitted as a private gcsafe proc invoked by
  # createUnderContext after `brokerCtx` is bound (so it may read self.brokerCtx).
  if initBody != nil:
    result.add(
      nnkProcDef.newTree(
        postInitName,
        newEmptyNode(),
        newEmptyNode(),
        nnkFormalParams.newTree(
          newEmptyNode(), newIdentDefs(ident("self"), copyNimTree(implName))
        ),
        nnkPragma.newTree(ident("gcsafe")),
        newEmptyNode(),
        initBody,
      )
    )

  # Forwarded ctor params: ", a: A, b: B" for signatures; "a, b" for the call.
  var ctorParamDecls = ""
  var ctorArgNames = ""
  for a in ctorParams:
    ctorParamDecls.add(", " & a.repr.strip())
    for j in 0 ..< a.len - 2:
      ctorArgNames.add((if ctorArgNames.len > 0: ", " else: "") & $baseName(a[j]))
  let newCallArgs = "(" & ctorArgNames & ")"
  let fwdArgs =
    if ctorArgNames.len > 0:
      ", " & ctorArgNames
    else:
      ""

  # createUnderContext() — adopts `ctx`. gcsafe: the create-instance FFI path
  # constructs sub-instances inside a gcsafe request method body (classCtx is an
  # immutable `let`, instanceCtx an atomic, setupProviders is gcsafe). Requires
  # the user `new` body to be gcsafe (trivial field writes always are).
  var cucSrc =
    "proc createUnderContext*(T: typedesc[" & implStr & "], ctx: BrokerContext" &
    ctorParamDecls & "): " & implStr & " {.gcsafe.} =\n"
  cucSrc.add("  let self = T.new" & newCallArgs & "\n")
  cucSrc.add("  self.brokerCtx = ctx\n")
  if initBody != nil:
    cucSrc.add("  " & $postInitName & "(self)\n")
  cucSrc.add("  " & $setupName & "(self)\n")
  cucSrc.add("  self\n")
  result.add(parseStmt(cucSrc))

  # create() — allocate a fresh per-instance ctx, then decorate.
  var createSrc =
    "proc create*(T: typedesc[" & implStr & "]" & ctorParamDecls & "): " & implStr &
    " {.gcsafe.} =\n"
  createSrc.add(
    "  T.createUnderContext(makeBrokerContext(" & $classCtxVar & ", " & $instCounter &
      ".fetchAdd(1'u16, moRelaxed) + 1'u16)" & fwdArgs & ")\n"
  )
  result.add(parseStmt(createSrc))

  # close() — clear this instance's providers (breaks the refc cycle) and free
  # its ctx. Idempotent.
  var closeSrc = "proc close*(self: " & implStr & ") =\n"
  closeSrc.add("  if self.brokerCtx == DefaultBrokerContext: return\n")
  for (verb, brokerName, margs, payload, async) in methods:
    closeSrc.add("  " & brokerName & ".clearProvider(self.brokerCtx)\n")
  # B2: also drop this instance's event listeners. The interface published its
  # event types via the compile-time registry; guard with `when compiles` so it
  # works whether the event broker is single-thread / mt / API.
  for ev in interfaceEvents(ifaceStr):
    # dropAllListeners clears the listener table synchronously (before its first
    # await), so discarding the Future from sync close() still removes listeners;
    # only the in-flight-cancel await is abandoned (matches teardown semantics).
    closeSrc.add("  when compiles(" & ev & ".dropAllListeners(self.brokerCtx)):\n")
    closeSrc.add(
      "    when typeof(" & ev & ".dropAllListeners(self.brokerCtx)) is void:\n"
    )
    closeSrc.add("      " & ev & ".dropAllListeners(self.brokerCtx)\n")
    closeSrc.add("    else:\n")
    closeSrc.add("      discard " & ev & ".dropAllListeners(self.brokerCtx)\n")
  closeSrc.add("  self.brokerCtx = DefaultBrokerContext\n")
  result.add(parseStmt(closeSrc))

  when defined(brokerDebug):
    writeBrokerDebug("BrokerImplement", implStr, result, header = "of " & ifaceStr)
    when defined(brokerDebugStdout):
      echo result.repr
