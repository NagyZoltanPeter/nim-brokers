## Multi-thread broker configuration
## ---------------------------------
## Compile-time config records and macro-argument parsing for the
## multi-thread Event / Request brokers.
##
## The macro entry points accept optional kwargs:
##
##   EventBroker(mt, queueDepth = 1024, slabCapacity = 4096): ...
##   RequestBroker(mt, responseSlots = 64, maxResponseBytes = 4096): ...
##
## When no kwargs are supplied the existing module-level defaults in
## `mt_event_broker.nim` / `mt_request_broker.nim` are used unchanged.

{.push raises: [].}

import std/[macros, strutils]

type
  MtEvtCfg* = object
    ## Resolved EventBroker(mt) capacity config.
    queueDepth*: int ## ring slots per listener bucket (power-of-2)
    slabCapacity*: int ## global slab cell count
    maxPayloadBytes*: int ## per-cell payload bytes
    freeListShards*: int ## sharded free-list partitions
    # Provenance — for the compile-time printout. "default" / "kwarg" /
    # "preset:<name>" / "auto:<reason>".
    queueDepthOrigin*: string
    slabCapacityOrigin*: string
    maxPayloadBytesOrigin*: string
    freeListShardsOrigin*: string

  MtReqCfg* = object
    ## Resolved RequestBroker(mt) capacity config.
    queueDepth*: int
    slabCapacity*: int
    maxPayloadBytes*: int
    responseSlots*: int
    maxResponseBytes*: int
    freeListShards*: int
    queueDepthOrigin*: string
    slabCapacityOrigin*: string
    maxPayloadBytesOrigin*: string
    responseSlotsOrigin*: string
    maxResponseBytesOrigin*: string
    freeListShardsOrigin*: string

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

const
  DefaultMtEvtQueueDepth* = 256
  DefaultMtEvtSlabCapacity* = 1024
  DefaultMtEvtMaxPayloadBytes* = 1024
  DefaultMtEvtFreeListShards* = 4

  DefaultMtReqQueueDepth* = 256
  DefaultMtReqSlabCapacity* = 64
  DefaultMtReqMaxPayloadBytes* = 1024
  DefaultMtReqResponseSlots* = 256
  DefaultMtReqMaxResponseBytes* = 64 * 1024
  DefaultMtReqFreeListShards* = 2

# ---------------------------------------------------------------------------
# Built-in presets
# ---------------------------------------------------------------------------
#
# Named shorthand for capacity profiles. Recognised in the macro as
# `preset = <name>`.
#
#   defaultBalanced  same as omitting `preset`
#   fastBurst        bursty emit/request, small payload — wide ring/slab
#   largePayload    infrequent traffic with big payloads
#   tinyFootprint    rare traffic, embedded / memory-constrained
#
# Individual kwargs supplied alongside `preset =` override the preset's
# values (so you can pick a profile and tweak one field).

type BuiltinPreset* = enum
  bpDefaultBalanced = "defaultBalanced"
  bpFastBurst = "fastBurst"
  bpLargePayload = "largePayload"
  bpTinyFootprint = "tinyFootprint"

proc parseBuiltinPreset(name: string, n: NimNode): BuiltinPreset =
  case name
  of "defaultBalanced":
    bpDefaultBalanced
  of "fastBurst":
    bpFastBurst
  of "largePayload":
    bpLargePayload
  of "tinyFootprint":
    bpTinyFootprint
  else:
    error(
      "Unknown preset '" & name &
        "'. Built-in presets: defaultBalanced, fastBurst, largePayload, " &
        "tinyFootprint. (User-defined presets are not yet supported.)",
      n,
    )
    bpDefaultBalanced

proc applyEvtPreset(cfg: var MtEvtCfg, p: BuiltinPreset) =
  let tag = "preset:" & $p
  case p
  of bpDefaultBalanced:
    discard # already the default
  of bpFastBurst:
    cfg.queueDepth = 4096
    cfg.slabCapacity = 8192
    cfg.maxPayloadBytes = 256
    cfg.freeListShards = 8
  of bpLargePayload:
    cfg.queueDepth = 64
    cfg.slabCapacity = 128
    cfg.maxPayloadBytes = 64 * 1024
    cfg.freeListShards = 2
  of bpTinyFootprint:
    cfg.queueDepth = 32
    cfg.slabCapacity = 32
    cfg.maxPayloadBytes = 256
    cfg.freeListShards = 1
  cfg.queueDepthOrigin = tag
  cfg.slabCapacityOrigin = tag
  cfg.maxPayloadBytesOrigin = tag
  cfg.freeListShardsOrigin = tag

proc applyReqPreset(cfg: var MtReqCfg, p: BuiltinPreset) =
  let tag = "preset:" & $p
  case p
  of bpDefaultBalanced:
    discard
  of bpFastBurst:
    cfg.queueDepth = 4096
    cfg.slabCapacity = 256
    cfg.maxPayloadBytes = 256
    cfg.responseSlots = 1024
    cfg.maxResponseBytes = 4 * 1024
    cfg.freeListShards = 4
  of bpLargePayload:
    cfg.queueDepth = 64
    cfg.slabCapacity = 32
    cfg.maxPayloadBytes = 64 * 1024
    cfg.responseSlots = 64
    cfg.maxResponseBytes = 256 * 1024
    cfg.freeListShards = 2
  of bpTinyFootprint:
    cfg.queueDepth = 16
    cfg.slabCapacity = 8
    cfg.maxPayloadBytes = 256
    cfg.responseSlots = 16
    cfg.maxResponseBytes = 1024
    cfg.freeListShards = 1
  cfg.queueDepthOrigin = tag
  cfg.slabCapacityOrigin = tag
  cfg.maxPayloadBytesOrigin = tag
  cfg.responseSlotsOrigin = tag
  cfg.maxResponseBytesOrigin = tag
  cfg.freeListShardsOrigin = tag

proc defaultMtEvtCfg*(): MtEvtCfg =
  MtEvtCfg(
    queueDepth: DefaultMtEvtQueueDepth,
    slabCapacity: DefaultMtEvtSlabCapacity,
    maxPayloadBytes: DefaultMtEvtMaxPayloadBytes,
    freeListShards: DefaultMtEvtFreeListShards,
    queueDepthOrigin: "default",
    slabCapacityOrigin: "default",
    maxPayloadBytesOrigin: "default",
    freeListShardsOrigin: "default",
  )

proc defaultMtReqCfg*(): MtReqCfg =
  MtReqCfg(
    queueDepth: DefaultMtReqQueueDepth,
    slabCapacity: DefaultMtReqSlabCapacity,
    maxPayloadBytes: DefaultMtReqMaxPayloadBytes,
    responseSlots: DefaultMtReqResponseSlots,
    maxResponseBytes: DefaultMtReqMaxResponseBytes,
    freeListShards: DefaultMtReqFreeListShards,
    queueDepthOrigin: "default",
    slabCapacityOrigin: "default",
    maxPayloadBytesOrigin: "default",
    responseSlotsOrigin: "default",
    maxResponseBytesOrigin: "default",
    freeListShardsOrigin: "default",
  )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isPow2(n: int): bool {.inline.} =
  n > 0 and (n and (n - 1)) == 0

proc intValOrFail(n: NimNode, kw: string): int =
  ## Extract a compile-time int from a kwarg RHS. Errors clearly on
  ## non-int input.
  case n.kind
  of nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit,
      nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit:
    int(n.intVal)
  else:
    error(
      "broker kwarg '" & kw & "' expects an integer literal, got " & $n.kind, n
    )
    0

# ---------------------------------------------------------------------------
# Kwarg parsing — EventBroker(mt)
# ---------------------------------------------------------------------------

const ValidEvtKwargs = [
  "queueDepth", "slabCapacity", "maxPayloadBytes", "freeListShards"
]

proc applyEvtKwarg(cfg: var MtEvtCfg, kw: string, n: NimNode) =
  case kw
  of "queueDepth":
    let v = intValOrFail(n, kw)
    if not isPow2(v):
      error("EventBroker kwarg 'queueDepth' must be power-of-2, got " & $v, n)
    cfg.queueDepth = v
    cfg.queueDepthOrigin = "kwarg"
  of "slabCapacity":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("EventBroker kwarg 'slabCapacity' must be > 0, got " & $v, n)
    cfg.slabCapacity = v
    cfg.slabCapacityOrigin = "kwarg"
  of "maxPayloadBytes":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("EventBroker kwarg 'maxPayloadBytes' must be > 0, got " & $v, n)
    cfg.maxPayloadBytes = v
    cfg.maxPayloadBytesOrigin = "kwarg"
  of "freeListShards":
    let v = intValOrFail(n, kw)
    if v <= 0 or v > 64:
      error(
        "EventBroker kwarg 'freeListShards' must be in 1..64, got " & $v, n
      )
    cfg.freeListShards = v
    cfg.freeListShardsOrigin = "kwarg"
  else:
    error(
      "Unknown EventBroker(mt) kwarg '" & kw &
        "'. Valid: " & ValidEvtKwargs.join(", "),
      n,
    )

proc presetFromKwargRhs(rhs: NimNode): BuiltinPreset =
  ## Extracts a built-in preset name from a kwarg RHS. Accepts identifier
  ## form (`preset = fastBurst`).
  if rhs.kind != nnkIdent:
    error(
      "preset value must be one of the built-in preset names " &
        "(defaultBalanced, fastBurst, largePayload, tinyFootprint), got " &
        $rhs.kind & " — " & rhs.repr,
      rhs,
    )
  parseBuiltinPreset($rhs, rhs)

proc parseMtEvtKwargs*(kwargs: openArray[NimNode]): MtEvtCfg =
  ## Parses kwarg nodes (everything between `mt` and the trailing body).
  ## Each node must be of shape `nnkExprEqExpr` (`name = value`).
  ##
  ## Order of application:
  ##   1. defaultMtEvtCfg()
  ##   2. `preset = <name>` if present (overrides defaults)
  ##   3. individual kwargs (override the preset)
  result = defaultMtEvtCfg()
  for n in kwargs:
    if n.kind != nnkExprEqExpr:
      error(
        "EventBroker(mt) expects kwargs of the form 'name = value', got " &
          $n.kind & " — " & n.repr,
        n,
      )
    let nameNode = n[0]
    if nameNode.kind != nnkIdent:
      error("EventBroker(mt) kwarg name must be an identifier", nameNode)
    if $nameNode == "preset":
      applyEvtPreset(result, presetFromKwargRhs(n[1]))
  for n in kwargs:
    let name = $n[0]
    if name == "preset":
      continue
    applyEvtKwarg(result, name, n[1])

# ---------------------------------------------------------------------------
# Kwarg parsing — RequestBroker(mt)
# ---------------------------------------------------------------------------

const ValidReqKwargs = [
  "queueDepth", "slabCapacity", "maxPayloadBytes",
  "responseSlots", "maxResponseBytes", "freeListShards"
]

proc applyReqKwarg(cfg: var MtReqCfg, kw: string, n: NimNode) =
  case kw
  of "queueDepth":
    let v = intValOrFail(n, kw)
    if not isPow2(v):
      error("RequestBroker kwarg 'queueDepth' must be power-of-2, got " & $v, n)
    cfg.queueDepth = v
    cfg.queueDepthOrigin = "kwarg"
  of "slabCapacity":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'slabCapacity' must be > 0, got " & $v, n)
    cfg.slabCapacity = v
    cfg.slabCapacityOrigin = "kwarg"
  of "maxPayloadBytes":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'maxPayloadBytes' must be > 0, got " & $v, n)
    cfg.maxPayloadBytes = v
    cfg.maxPayloadBytesOrigin = "kwarg"
  of "responseSlots":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'responseSlots' must be > 0, got " & $v, n)
    cfg.responseSlots = v
    cfg.responseSlotsOrigin = "kwarg"
  of "maxResponseBytes":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'maxResponseBytes' must be > 0, got " & $v, n)
    cfg.maxResponseBytes = v
    cfg.maxResponseBytesOrigin = "kwarg"
  of "freeListShards":
    let v = intValOrFail(n, kw)
    if v <= 0 or v > 64:
      error(
        "RequestBroker kwarg 'freeListShards' must be in 1..64, got " & $v, n
      )
    cfg.freeListShards = v
    cfg.freeListShardsOrigin = "kwarg"
  else:
    error(
      "Unknown RequestBroker(mt) kwarg '" & kw &
        "'. Valid: " & ValidReqKwargs.join(", "),
      n,
    )

proc parseMtReqKwargs*(kwargs: openArray[NimNode]): MtReqCfg =
  ## See `parseMtEvtKwargs` for order-of-application rules.
  result = defaultMtReqCfg()
  for n in kwargs:
    if n.kind != nnkExprEqExpr:
      error(
        "RequestBroker(mt) expects kwargs of the form 'name = value', got " &
          $n.kind & " — " & n.repr,
        n,
      )
    let nameNode = n[0]
    if nameNode.kind != nnkIdent:
      error("RequestBroker(mt) kwarg name must be an identifier", nameNode)
    if $nameNode == "preset":
      applyReqPreset(result, presetFromKwargRhs(n[1]))
  for n in kwargs:
    let name = $n[0]
    if name == "preset":
      continue
    applyReqKwarg(result, name, n[1])

# ---------------------------------------------------------------------------
# Splitting varargs into kwargs + body
# ---------------------------------------------------------------------------

proc splitMtArgs*(
    args: NimNode, what: string
): tuple[kwargs: seq[NimNode], body: NimNode] =
  ## Splits a `varargs[untyped]` macro arg list into (kwarg nodes, body
  ## stmt-list). The body is always the last element. Errors if no body.
  if args.len == 0:
    error(what & " requires a body block", args)
  let bodyNode = args[args.len - 1]
  if bodyNode.kind notin {nnkStmtList, nnkTypeDef, nnkTypeSection}:
    error(
      what & " body must be a `:` block of type definitions (got " &
        $bodyNode.kind & ")",
      bodyNode,
    )
  var kw = newSeqOfCap[NimNode](args.len - 1)
  for i in 0 ..< args.len - 1:
    kw.add(args[i])
  (kw, bodyNode)
