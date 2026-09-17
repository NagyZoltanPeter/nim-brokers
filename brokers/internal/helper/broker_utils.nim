import std/[macros, strutils]

type ParsedBrokerType* = object
  ## Result of parsing the single `type` definition inside a broker macro body.
  ##
  ## - `typeIdent`: base identifier for the declared type name
  ## - `objectDef`: exported type definition RHS (inline object fields exported;
  ##   non-object types wrapped in `distinct` unless already distinct)
  ## - `isRefObject`: true only for inline `ref object` definitions
  ## - `hasInlineFields`: true for inline `object` / `ref object`
  ## - `fieldNames`/`fieldTypes`: populated only when `collectFieldInfo = true`
  typeIdent*: NimNode
  objectDef*: NimNode
  isRefObject*: bool
  hasInlineFields*: bool
  isVoid*: bool ## true when the declared RHS is the bare `void` type
  fieldNames*: seq[NimNode]
  fieldTypes*: seq[NimNode]
  docText*: string
    ## Doc-comment text captured for the declared type: standalone `##`
    ## statements written above the `type` section inside the broker block
    ## (joined with newlines). Empty when the user wrote none.
  fieldDocs*: seq[string]
    ## Per-field doc text (trailing `## …` on the field), parallel to
    ## `fieldNames`. Populated only when `collectFieldInfo = true`.

proc toSnakeCase*(name: string): string {.compileTime.} =
  ## Converts PascalCase / camelCase to snake_case. Shared between the
  ## CBOR codegen surface and any kept compile-time helper that needs to
  ## derive a wire name from a Nim identifier.
  result = ""
  for i, ch in name:
    if ch in {'A' .. 'Z'}:
      if i > 0 and name[i - 1] notin {'A' .. 'Z', '_'}:
        result.add('_')
      result.add(chr(ord(ch) + 32))
    else:
      result.add(ch)

# ── doc-comment capture (issue #50) ───────────────────────────────────────
# Standalone `##` lines arrive as nnkCommentStmt nodes (strVal is the text).
# A `##` the parser ATTACHED to a declaration (trailing on an object field,
# indented under a proc signature) is invisible in the node tree —
# std/macros exposes no comment accessor — but survives `copyNimTree` and
# is rendered back by `repr`, so we recover the text from the rendered
# source. Attachment cannot be synthesised on macro-built nodes either;
# `typeDefWithDoc` grafts real content into a parsed skeleton whose
# TypeDef node already carries the comment.

proc joinDocText*(a, b: string): string {.compileTime.} =
  ## Join two doc fragments with a newline, tolerating empty parts.
  if a.len == 0:
    b
  elif b.len == 0:
    a
  else:
    a & "\n" & b

proc attachedDocText*(n: NimNode): string {.compileTime.} =
  ## Recover doc comments the parser attached to `n` (e.g. a trailing
  ## `## …` on a field, or a `##` line indented under a signature proc)
  ## by scanning the node's rendered source for `##` lines.
  result = ""
  var rendered: string
  try:
    rendered = n.repr
  except CatchableError, Defect:
    return ""
  for rawLine in rendered.splitLines():
    let line = rawLine.strip()
    var text = ""
    if line.startsWith("##"):
      text = line[2 .. ^1].strip()
    else:
      let idx = line.find(" ## ")
      if idx >= 0:
        text = line[idx + 4 .. ^1].strip()
      else:
        continue
    result = joinDocText(result, text)

proc fieldDocText*(field: NimNode): string {.compileTime.} =
  ## Doc text attached to an object-field `nnkIdentDefs`. The renderer only
  ## prints attached comments in a declaration context, so wrap the field
  ## into a synthetic single-field type section before scanning its repr.
  if field.kind != nnkIdentDefs:
    return ""
  attachedDocText(
    newTree(
      nnkTypeSection,
      newTree(
        nnkTypeDef,
        ident("TmpFieldDocProbe"),
        newEmptyNode(),
        newTree(
          nnkObjectTy,
          newEmptyNode(),
          newEmptyNode(),
          newTree(nnkRecList, copyNimTree(field)),
        ),
      ),
    )
  )

proc procDocsFromBody*(body: NimNode): seq[(string, string)] {.compileTime.} =
  ## (procName, docText) for each top-level proc in a broker body: the
  ## standalone `##` lines immediately above the proc joined with any doc
  ## the parser attached to the signature itself.
  result = @[]
  var pendingDoc = ""
  for stmt in body:
    case stmt.kind
    of nnkCommentStmt:
      pendingDoc = joinDocText(pendingDoc, stmt.strVal)
    of nnkProcDef:
      let nm = stmt[0]
      let base = (if nm.kind == nnkPostfix: nm[1] else: nm)
      let attached = attachedDocText(newStmtList(copyNimTree(stmt)))
      result.add(($base, joinDocText(pendingDoc, attached)))
      pendingDoc = ""
    else:
      pendingDoc = ""

proc typeDefWithDoc*(td: NimNode, doc: string): NimNode {.compileTime.} =
  ## Rebuild a `nnkTypeDef` so `doc` becomes its attached doc comment,
  ## visible to `nim doc` / IDE hover on the generated type. Comments
  ## cannot be attached to macro-built nodes directly, so parse a skeleton
  ## type definition carrying the comment and graft the real name /
  ## generic params / RHS into it (the comment lives on the TypeDef node,
  ## which is kept).
  if doc.len == 0 or td.kind != nnkTypeDef:
    return td
  var src = "type TmpDocCarrier = int\n"
  for line in doc.splitLines():
    src.add("  ## " & line & "\n")
  var skel: NimNode
  try:
    skel = parseStmt(src)
  except CatchableError, Defect:
    return td
  result = skel[0][0]
  result[0] = td[0]
  result[1] = td[1]
  result[2] = td[2]

proc attachFirstTypeDefDoc*(n: NimNode, doc: string) {.compileTime.} =
  ## Attach `doc` to the first `nnkTypeDef` under `n` — in place. `n` may be
  ## the `nnkTypeSection` itself or a statement list holding one (`quote do`
  ## returns the bare section for a single `type` statement).
  if doc.len == 0:
    return
  var sec = n
  if sec.kind != nnkTypeSection:
    for child in n:
      if child.kind == nnkTypeSection:
        sec = child
        break
  if sec.kind != nnkTypeSection or sec.len == 0 or sec[0].kind != nnkTypeDef:
    return
  sec[0] = typeDefWithDoc(sec[0], doc)

proc sanitizeIdentName*(node: NimNode): string =
  var raw = $node
  var sanitizedName = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_':
      sanitizedName.add(ch)
    else:
      sanitizedName.add('_')
  sanitizedName

proc ensureFieldDef*(node: NimNode) =
  if node.kind != nnkIdentDefs or node.len < 3:
    error("Expected field definition of the form `name: Type`", node)
  let typeSlot = node.len - 2
  if node[typeSlot].kind == nnkEmpty:
    error("Field `" & $node[0] & "` must declare a type", node)

proc exportIdentNode*(node: NimNode): NimNode =
  case node.kind
  of nnkIdent:
    postfix(copyNimTree(node), "*")
  of nnkPostfix:
    node
  else:
    error("Unsupported identifier form in field definition", node)

proc baseTypeIdent*(defName: NimNode): NimNode =
  case defName.kind
  of nnkIdent:
    defName
  of nnkAccQuoted:
    if defName.len != 1:
      error("Unsupported quoted identifier", defName)
    defName[0]
  of nnkPostfix:
    baseTypeIdent(defName[1])
  of nnkPragmaExpr:
    baseTypeIdent(defName[0])
  else:
    error("Unsupported type name in broker definition", defName)

proc ensureDistinctType*(rhs: NimNode): NimNode =
  ## For PODs / aliases / externally-defined types, wrap in `distinct` unless
  ## it's already distinct.
  if rhs.kind == nnkDistinctTy:
    return copyNimTree(rhs)
  newTree(nnkDistinctTy, copyNimTree(rhs))

proc cloneParams*(params: seq[NimNode]): seq[NimNode] =
  ## Deep copy parameter definitions so they can be inserted in multiple places.
  result = @[]
  for param in params:
    result.add(copyNimTree(param))

proc collectParamNames*(params: seq[NimNode]): seq[NimNode] =
  ## Extract all identifier symbols declared across IdentDefs nodes.
  result = @[]
  for param in params:
    assert param.kind == nnkIdentDefs
    for i in 0 ..< param.len - 2:
      let nameNode = param[i]
      if nameNode.kind == nnkEmpty:
        continue
      result.add(ident($nameNode))

# ── bind / rebind provider sugar ──────────────────────────────────────────
# Shared codegen for the `bind<Noun>` / `rebind<Noun>` templates (issue #42).
# Nim has no bound-method values (`self.send` is not a closure), so the sugar
# synthesises — via a generated `template` — the exact forwarding closure the
# user would otherwise write by hand. Purely syntactic: identical codegen,
# identical `self` capture, no new refc/ORC exposure.

proc procTyPragma*(procTy: NimNode): NimNode =
  ## Extract the pragma node from a proc-type / proc-def node so a synthesised
  ## trampoline can carry the *exact* pragma of the slot it fills (matching
  ## calling convention + effects, so the closure is assignable). Returns an
  ## empty node if none is present.
  for child in procTy:
    if child.kind == nnkPragma:
      return copyNimTree(child)
  newEmptyNode()

proc futureVoidTy*(): NimNode =
  ## `Future[void]` — the return type of listener / signal-handler trampolines.
  ## Built by hand (not `quote`) so the source stays parseable by nph.
  newTree(nnkBracketExpr, ident("Future"), ident("void"))

proc makeForwardingLambda*(
    params: seq[NimNode], returnType, pragma: NimNode, awaitCall: bool
): NimNode =
  ## Anonymous trampoline `proc(<params>): <returnType> {.<pragma>.} =
  ## [await] boundCall(<param names>)`. `boundCall` is left as a bare ident so
  ## it binds to the enclosing bind/rebind template's `boundCall` parameter at
  ## instantiation — `boundCall(x)` then expands to `self.method(x)`.
  var formal = newTree(nnkFormalParams, copyNimTree(returnType))
  for p in params:
    formal.add(copyNimTree(p))
  var call = newCall(ident("boundCall"))
  for n in collectParamNames(params):
    call.add(n)
  let inner =
    if awaitCall:
      newTree(nnkCommand, ident("await"), call)
    else:
      call
  newTree(
    nnkLambda,
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    formal,
    copyNimTree(pragma),
    newEmptyNode(),
    newStmtList(inner),
  )

type BindSlot* = object ## One provider/handler arity a bind/rebind template can target.
  params*: seq[NimNode] ## trampoline params (empty for zero-arg / void slots)
  returnType*: NimNode
  pragma*: NimNode

proc bindTemplateDef(
    sugar, typeIdent, body: NimNode, withCtx: bool, payloadName: string = "boundCall"
): NimNode =
  ## `template <sugar>*(_: typedesc[T][; brokerCtx: BrokerContext];
  ##                    <payloadName>: untyped): untyped = body`
  var formal = newTree(nnkFormalParams, ident("untyped"))
  formal.add(
    newTree(
      nnkIdentDefs,
      ident("_"),
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
      newEmptyNode(),
    )
  )
  if withCtx:
    # `brokerCtx` is deliberately `untyped`, not `BrokerContext`: overloading
    # `bind<Noun>` on arity (2-arg no-ctx vs 3-arg ctx) with a *typed* param in
    # the ctx form makes Nim sem-check the bound-method argument (`self.send`)
    # against `BrokerContext` while scoring the losing candidate — and a bare
    # method reference cannot be sem-checked as a value (it is not a closure),
    # yielding a spurious "undeclared field" error. Keeping it `untyped` makes
    # overload resolution arity-only.
    formal.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("untyped"), newEmptyNode())
    )
  formal.add(
    newTree(nnkIdentDefs, ident(payloadName), ident("untyped"), newEmptyNode())
  )
  newTree(
    nnkTemplateDef,
    postfix(copyNimTree(sugar), "*"),
    newEmptyNode(),
    newEmptyNode(),
    formal,
    newEmptyNode(),
    newEmptyNode(),
    copyNimTree(body),
  )

proc buildBindTemplates*(
    typeIdent: NimNode,
    verbName, sugarName: string,
    slots: seq[BindSlot],
    awaitCall: bool,
): NimNode =
  ## Emit the ctx-form + no-ctx-form bind/rebind sugar templates. Each forwards
  ## to `verbName(T, brokerCtx, <trampoline>)`. With more than one slot the
  ## ctx-form disambiguates arity via `when compiles` (first slot whose
  ## trampoline sem-checks wins; the last slot is the unconditional `else`), so
  ## a broker declaring both a zero-arg and an arg signature keeps that
  ## capability without a second call-site name.
  result = newStmtList()
  let verb = ident(verbName)
  let sugar = ident(sugarName)

  proc slotCall(slot: BindSlot): NimNode =
    newCall(
      copyNimTree(verb),
      copyNimTree(typeIdent),
      ident("brokerCtx"),
      makeForwardingLambda(slot.params, slot.returnType, slot.pragma, awaitCall),
    )

  var ctxBody: NimNode
  if slots.len == 1:
    ctxBody = newStmtList(slotCall(slots[0]))
  else:
    var whenStmt = newTree(nnkWhenStmt)
    for i in 0 ..< slots.len - 1:
      let cond = newCall(ident("compiles"), slotCall(slots[i]))
      whenStmt.add(newTree(nnkElifBranch, cond, newStmtList(slotCall(slots[i]))))
    whenStmt.add(newTree(nnkElse, newStmtList(slotCall(slots[^1]))))
    ctxBody = newStmtList(whenStmt)

  result.add(bindTemplateDef(sugar, typeIdent, ctxBody, withCtx = true))

  let delegate = newStmtList(
    newCall(
      copyNimTree(sugar),
      copyNimTree(typeIdent),
      ident("DefaultBrokerContext"),
      ident("boundCall"),
    )
  )
  result.add(bindTemplateDef(sugar, typeIdent, delegate, withCtx = false))

# Shared codegen for the `provideIt` / `reprovideIt` body sugar. The sugar
# splices the user's block as the REAL provider proc body (`return`,
# `result =` and trailing expressions all work), with the declared signature
# arg names injected as zero-arg alias templates. `providerBody` closes the
# one hole real-body semantics open: a body that falls off the end would
# silently return `default(Result)` == err("") — it turns that into a
# positioned compile error instead.

proc containsBreakStmt(n: NimNode): bool =
  ## True when `n` contains a `break` that could escape `n` itself — breaks
  ## inside nested `for`/`while` loops are local and don't count.
  if n.kind == nnkBreakStmt:
    return true
  for c in n:
    if c.kind notin {nnkForStmt, nnkWhileStmt} and containsBreakStmt(c):
      return true
  false

proc isTerminalProviderStmt(n: NimNode): bool =
  ## Conservative "this statement always produces the provider's result or
  ## diverts control": `return` / `raise` / `result = ...` / a break-free
  ## `block` with terminal body / a branching statement whose EVERY branch is
  ## terminal (an `if`/`when` also needs an `else`). A statement list is
  ## terminal when ANY top-level child is: top-level code is straight-line, so
  ## control either reaches that child or was diverted by an earlier one.
  case n.kind
  of nnkReturnStmt, nnkRaiseStmt:
    true
  of nnkAsgn:
    n[0].kind == nnkIdent and n[0].eqIdent("result")
  of nnkStmtList, nnkStmtListExpr:
    for c in n:
      if isTerminalProviderStmt(c):
        return true
    false
  of nnkIfStmt, nnkWhenStmt:
    var hasElse = false
    for br in n:
      case br.kind
      of nnkElifBranch:
        if not isTerminalProviderStmt(br[1]):
          return false
      of nnkElse:
        hasElse = true
        if not isTerminalProviderStmt(br[0]):
          return false
      else:
        discard
    hasElse
  of nnkCaseStmt:
    for i in 1 ..< n.len:
      let br = n[i]
      case br.kind
      of nnkOfBranch, nnkElifBranch:
        if not isTerminalProviderStmt(br[^1]):
          return false
      of nnkElse:
        if not isTerminalProviderStmt(br[0]):
          return false
      else:
        discard
    true
  of nnkTryStmt:
    if not isTerminalProviderStmt(n[0]):
      return false
    for i in 1 ..< n.len:
      if n[i].kind == nnkExceptBranch and not isTerminalProviderStmt(n[i][^1]):
        return false
    true
  of nnkBlockStmt:
    not containsBreakStmt(n[1]) and isTerminalProviderStmt(n[1])
  else:
    false

const definitelyVoidStmtKinds = {
  nnkForStmt, nnkWhileStmt, nnkDiscardStmt, nnkVarSection, nnkLetSection,
  nnkConstSection, nnkTypeSection, nnkProcDef, nnkFuncDef, nnkTemplateDef,
  nnkIteratorDef, nnkMacroDef, nnkConverterDef, nnkImportStmt, nnkExportStmt, nnkPragma,
  nnkDefer, nnkMixinStmt, nnkBindStmt, nnkBreakStmt, nnkContinueStmt, nnkYieldStmt,
}

macro providerBody*(sugarName: static string, body: untyped): untyped =
  ## Guard a provideIt/reprovideIt body against silent fall-through:
  ## 1. a body with a top-level terminal statement is spliced unchanged;
  ## 2. a body ending in a definitely-void statement is a compile error;
  ## 3. anything else ending the body is treated as the intended trailing
  ##    expression and pinned via `result = <expr>` so the type checker must
  ##    match it against the provider's Result type (e.g. a final `echo` can
  ##    no longer compile).
  var stmts =
    if body.kind in {nnkStmtList, nnkStmtListExpr}:
      copyNimTree(body)
    else:
      newStmtList(copyNimTree(body))
  if stmts.len == 0:
    error(sugarName & " body is empty — it must produce a Result value", body)
  if isTerminalProviderStmt(stmts):
    return stmts
  let last = stmts[^1]
  if last.kind in definitelyVoidStmtKinds:
    error(
      sugarName & " body must produce a value on every path: end with `return ok(...)`/" &
        "`return err(...)`, assign to `result`, or end with a Result expression " &
        "(a final if/case/try needs every branch to do so). Otherwise the " &
        "provider would silently answer err(\"\").",
      last,
    )
  if last.kind in {nnkIfStmt, nnkWhenStmt}:
    var hasElse = false
    for br in last:
      if br.kind == nnkElse:
        hasElse = true
    if not hasElse:
      error(
        sugarName & " body ends in an `if` without an `else`: the missing branch would " &
          "silently answer err(\"\"). Add an `else` (or a fallback `return`) " &
          "so every path produces a value.",
        last,
      )
  stmts[^1] = newTree(nnkAsgn, ident("result"), last)
  stmts

proc paramBaseIdent(n: NimNode): NimNode =
  ## Bare name ident of a formal-parameter name node.
  case n.kind
  of nnkPostfix, nnkPragmaExpr:
    paramBaseIdent(n[0])
  else:
    n

proc makeProviderBodyLambda(
    params: seq[NimNode], returnType, pragma: NimNode, sugarName: string
): NimNode =
  ## Anonymous provider `proc(<renamed params>): <returnType> {.<pragma>.}`
  ## whose body re-injects each declared arg name as a zero-arg alias template
  ## (`{.inject.}` on lambda params does not survive template hygiene) and
  ## routes the user's block through `providerBody`. `body` is left as a bare
  ## ident so it binds to the enclosing sugar template's `body` parameter.
  var formal = newTree(nnkFormalParams, copyNimTree(returnType))
  var stmts = newStmtList()
  for p in params:
    let ty = p[p.len - 2]
    var def = newTree(nnkIdentDefs)
    for i in 0 ..< p.len - 2:
      let orig = paramBaseIdent(p[i])
      let renamed = ident($orig & "BrokerArg")
      def.add(renamed)
      stmts.add(
        newTree(
          nnkTemplateDef,
          copyNimTree(orig),
          newEmptyNode(),
          newEmptyNode(),
          newTree(nnkFormalParams, copyNimTree(ty)),
          newTree(nnkPragma, ident("inject"), ident("used")),
          newEmptyNode(),
          newStmtList(renamed),
        )
      )
    def.add(copyNimTree(ty))
    def.add(newEmptyNode())
    formal.add(def)
  stmts.add(newCall(ident("providerBody"), newLit(sugarName), ident("body")))
  newTree(
    nnkLambda,
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    formal,
    copyNimTree(pragma),
    newEmptyNode(),
    stmts,
  )

proc buildProvideTemplates*(
    typeIdent: NimNode, verbName, sugarName: string, slot: BindSlot
): NimNode =
  ## Emit the ctx-form + no-ctx-form `provideIt`-style sugar templates for one
  ## provider slot, forwarding to `verbName(T, brokerCtx, <provider lambda>)`.
  ## Unlike bind/rebind sugar the payload parameter is a `body` block, so slot
  ## selection cannot use `when compiles` (an args-free body is valid for both
  ## slots) — dual-slot brokers get distinct sugar names instead.
  result = newStmtList()
  let sugar = ident(sugarName)
  let lam = makeProviderBodyLambda(slot.params, slot.returnType, slot.pragma, sugarName)
  let ctxBody = newStmtList(
    newCall(ident(verbName), copyNimTree(typeIdent), ident("brokerCtx"), lam)
  )
  result.add(
    bindTemplateDef(sugar, typeIdent, ctxBody, withCtx = true, payloadName = "body")
  )
  let delegate = newStmtList(
    newCall(
      copyNimTree(sugar),
      copyNimTree(typeIdent),
      ident("DefaultBrokerContext"),
      ident("body"),
    )
  )
  result.add(
    bindTemplateDef(sugar, typeIdent, delegate, withCtx = false, payloadName = "body")
  )

# Shared codegen for the `listenIt` / `onSignalIt` body sugar. These used to be
# ONE module-global template per broker family carrying `mixin listen` /
# `mixin onSignal`. `mixin` defers the lookup to the *instantiation* site, and
# an implicitly generic proc (any `proc f(T: typedesc[X], …)` — which is what
# `BrokerImplement` emits for `new` / `create` / `createUnderContext`) is
# instantiated in the scope of whatever module CALLS it. A caller that does not
# import the event's own module therefore has no matching `listen` in scope and
# the sugar failed with a type mismatch raised inside `event_broker.nim`
# (issue #51). Emitting the sugar per type, in the same scope as the `listen` /
# `onSignal` overloads it forwards to, binds the verb at the template's
# DEFINITION site, so the right candidate is always in the set.

proc makeItBodyLambda(
    typeIdent, valueParam, returnType, pragma: NimNode, isVoid: bool
): NimNode =
  ## Anonymous listener/handler `proc([<valueParam>: T]): <returnType>
  ## {.<pragma>.}` whose body injects the event/signal value as `it` (a zero-arg
  ## alias template — `{.inject.}` on a lambda param does not survive template
  ## hygiene) and then splices the user's block verbatim. `body` is left as a
  ## bare ident so it binds to the enclosing sugar template's `body` parameter.
  var formal = newTree(nnkFormalParams, copyNimTree(returnType))
  var stmts = newStmtList()
  if not isVoid:
    formal.add(
      newTree(
        nnkIdentDefs, copyNimTree(valueParam), copyNimTree(typeIdent), newEmptyNode()
      )
    )
    stmts.add(
      newTree(
        nnkTemplateDef,
        ident("it"),
        newEmptyNode(),
        newEmptyNode(),
        newTree(nnkFormalParams, copyNimTree(typeIdent)),
        newTree(nnkPragma, ident("inject"), ident("used")),
        newEmptyNode(),
        newStmtList(copyNimTree(valueParam)),
      )
    )
  stmts.add(ident("body"))
  newTree(
    nnkLambda,
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    formal,
    copyNimTree(pragma),
    newEmptyNode(),
    stmts,
  )

proc buildItSugarTemplates*(
    typeIdent: NimNode,
    verbName, sugarName, valueParamName: string,
    returnType, pragma: NimNode,
    isVoid: bool,
): NimNode =
  ## Emit the ctx-form + no-ctx-form `listenIt`-style sugar templates,
  ## forwarding to `verbName(T, brokerCtx, <listener lambda>)`. No
  ## `providerBody` fall-through guard: a listener/handler body is `void`, so
  ## falling off the end is the normal case.
  result = newStmtList()
  let sugar = ident(sugarName)
  let lam =
    makeItBodyLambda(typeIdent, ident(valueParamName), returnType, pragma, isVoid)
  let ctxBody = newStmtList(
    newCall(ident(verbName), copyNimTree(typeIdent), ident("brokerCtx"), lam)
  )
  result.add(
    bindTemplateDef(sugar, typeIdent, ctxBody, withCtx = true, payloadName = "body")
  )
  let delegate = newStmtList(
    newCall(
      copyNimTree(sugar),
      copyNimTree(typeIdent),
      ident("DefaultBrokerContext"),
      ident("body"),
    )
  )
  result.add(
    bindTemplateDef(sugar, typeIdent, delegate, withCtx = false, payloadName = "body")
  )

proc parseOneTypeDef(
    def: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): ParsedBrokerType =
  ## Parse a single nnkTypeDef node into a ParsedBrokerType.
  ## Internal helper used by both parseSingleTypeDef and parseTypeDefs.
  var fieldNames: seq[NimNode] = @[]
  var fieldTypes: seq[NimNode] = @[]
  var fieldDocs: seq[string] = @[]
  var docText = ""

  let typeIdent = baseTypeIdent(def[0])
  let rhs = def[2]
  var objectDef: NimNode
  var isRefObject = false
  var hasInlineFields = false
  var isVoid = false

  case rhs.kind
  of nnkObjectTy:
    let recList = rhs[2]
    if recList.kind != nnkRecList:
      error(macroName & " object must declare a standard field list", rhs)
    var exportedRecList = newTree(nnkRecList)
    for field in recList:
      case field.kind
      of nnkIdentDefs:
        ensureFieldDef(field)
        if collectFieldInfo:
          let fieldTypeNode = field[field.len - 2]
          let fieldDoc = fieldDocText(field)
          for i in 0 ..< field.len - 2:
            let baseFieldIdent = baseTypeIdent(field[i])
            fieldNames.add(copyNimTree(baseFieldIdent))
            fieldTypes.add(copyNimTree(fieldTypeNode))
            fieldDocs.add(fieldDoc)
        var cloned = copyNimTree(field)
        for i in 0 ..< cloned.len - 2:
          cloned[i] = exportIdentNode(cloned[i])
        exportedRecList.add(cloned)
      of nnkEmpty:
        discard
      of nnkCommentStmt:
        # A `##` doc comment the parser surfaced as its own node inside the
        # field list — fold it into the type's doc text.
        docText = joinDocText(docText, field.strVal)
      else:
        error(
          macroName & " object definition only supports simple field declarations",
          field,
        )
    objectDef =
      newTree(nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList)
    isRefObject = false
    hasInlineFields = true
  of nnkRefTy:
    if rhs.len != 1:
      error(macroName & " ref type must have a single base", rhs)
    if rhs[0].kind == nnkObjectTy:
      let obj = rhs[0]
      let recList = obj[2]
      if recList.kind != nnkRecList:
        error(macroName & " object must declare a standard field list", obj)
      var exportedRecList = newTree(nnkRecList)
      for field in recList:
        case field.kind
        of nnkIdentDefs:
          ensureFieldDef(field)
          if collectFieldInfo:
            let fieldTypeNode = field[field.len - 2]
            let fieldDoc = fieldDocText(field)
            for i in 0 ..< field.len - 2:
              let baseFieldIdent = baseTypeIdent(field[i])
              fieldNames.add(copyNimTree(baseFieldIdent))
              fieldTypes.add(copyNimTree(fieldTypeNode))
              fieldDocs.add(fieldDoc)
          var cloned = copyNimTree(field)
          for i in 0 ..< cloned.len - 2:
            cloned[i] = exportIdentNode(cloned[i])
          exportedRecList.add(cloned)
        of nnkEmpty:
          discard
        of nnkCommentStmt:
          docText = joinDocText(docText, field.strVal)
        else:
          error(
            macroName & " object definition only supports simple field declarations",
            field,
          )
      let exportedObjectType =
        newTree(nnkObjectTy, copyNimTree(obj[0]), copyNimTree(obj[1]), exportedRecList)
      objectDef = newTree(nnkRefTy, exportedObjectType)
      isRefObject = true
      hasInlineFields = true
    elif allowRefToNonObject:
      ## `ref SomeType` (SomeType can be defined elsewhere)
      objectDef = ensureDistinctType(rhs)
      isRefObject = false
      hasInlineFields = false
    else:
      error(macroName & " ref object must wrap a concrete object definition", rhs)
  elif rhs.kind == nnkIdent and rhs.eqIdent("void"):
    ## `void` — a payload-less broker. The bare `void` type cannot name a
    ## broker (every `void` broker would share `typedesc[void]`, colliding
    ## the generated `request` / `setProvider` / `emit` overloads). It is
    ## therefore lowered to a *unique* empty `object` — a unit type — so
    ## each broker keeps a distinct identity. `isVoid` lets broker macros
    ## drop the now-meaningless value parameter from handler / emit
    ## signatures; the request payload is simply the zero-field object.
    objectDef =
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), newTree(nnkRecList))
    isRefObject = false
    hasInlineFields = false
    isVoid = true
  else:
    ## Non-object type / alias.
    objectDef = ensureDistinctType(rhs)
    isRefObject = false
    hasInlineFields = false

  result = ParsedBrokerType(
    typeIdent: typeIdent,
    objectDef: objectDef,
    isRefObject: isRefObject,
    hasInlineFields: hasInlineFields,
    isVoid: isVoid,
    fieldNames: fieldNames,
    fieldTypes: fieldTypes,
    docText: docText,
    fieldDocs: fieldDocs,
  )

proc parseTypeDefs*(
    body: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): seq[ParsedBrokerType] =
  ## Parses all `type` definitions from a broker macro body.
  ## Returns them in declaration order. Supports multiple types in a single
  ## broker block (e.g. supporting types + primary type).
  ##
  ## Callers are responsible for identifying which entry is the "primary" type
  ## (typically the last one, or the one referenced in the signature return type).
  result = @[]
  var pendingDoc = ""
  for stmt in body:
    case stmt.kind
    of nnkCommentStmt:
      # Standalone `##` lines above the `type` section document the type.
      pendingDoc = joinDocText(pendingDoc, stmt.strVal)
    of nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        var parsed =
          parseOneTypeDef(def, macroName, allowRefToNonObject, collectFieldInfo)
        parsed.docText = joinDocText(pendingDoc, parsed.docText)
        pendingDoc = ""
        result.add(parsed)
    else:
      # A comment above e.g. a signature proc documents that proc, not the
      # type — drop any pending text so it is not mis-attributed.
      pendingDoc = ""

  if result.len == 0:
    error(macroName & " body must declare at least one type", body)

proc parseSingleTypeDef*(
    body: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): ParsedBrokerType =
  ## Parses exactly one `type` definition from a broker macro body.
  ## Backward-compatible wrapper around parseTypeDefs that enforces a single type.
  ##
  ## Supported RHS:
  ## - inline `object` / `ref object` (fields are auto-exported)
  ## - non-object types / aliases / externally-defined types (wrapped in `distinct`)
  ## - optionally: `ref SomeType` when `allowRefToNonObject = true`
  let defs = parseTypeDefs(body, macroName, allowRefToNonObject, collectFieldInfo)
  if defs.len > 1:
    error("Only one type may be declared inside " & macroName, body)
  result = defs[0]

# ---------------------------------------------------------------------------
# RequestBroker proc-style sugar (option B — payload decoupled from the
# dispatch tag). Shared by the single-thread, multi-thread, and API
# RequestBroker generators so the surface stays identical across flavors.
# ---------------------------------------------------------------------------

type ParsedRequestSugar* = object
  ## Result of parsing the new proc-style RequestBroker sugar.
  ## - `typeIdent`  : the dispatch-tag type (broker name).
  ## - `objectDef`  : RHS to declare for the tag (the object for the object
  ##                  form, `distinct payload` for the POD form).
  ## - `payloadType`: the value type returned by `request` (decoupled — raw
  ##                  payload for POD, == typeIdent for the object form).
  ## - `fieldTypes` : object field types (object form) for MT auto-config;
  ##                  empty for POD.
  ## - `zeroArgProc`/`argProc`: the parsed signature proc defs (nil if absent).
  ## - `argParams`  : IdentDefs of the arg-based signature.
  typeIdent*: NimNode
  objectDef*: NimNode
  payloadType*: NimNode
  fieldTypes*: seq[NimNode]
  zeroArgProc*: NimNode
  argProc*: NimNode
  argParams*: seq[NimNode]
  verb*: string
    ## The (lowercase) signature verb — the BrokerInterface method name that
    ## `BrokerImplement` overrides (e.g. `getHealth`).
  docText*: string
    ## Doc text for the broker as a whole: standalone `##` lines above the
    ## payload `type` declaration; falls back to the first signature doc
    ## when the block declares no type of its own (POD form).
  zeroArgDoc*: string
    ## Doc text for the zero-argument signature: standalone `##` lines above
    ## the proc plus any `##` the parser attached to the signature itself.
  argDoc*: string ## Doc text for the argument-based signature (same sources).
  parsed*: ParsedBrokerType
    ## Full parse of the dispatch tag over the payload — drives the API/CBOR
    ## schema registration identically to the legacy `type X = ...` path.

proc extractResultOk*(returnType: NimNode, async: bool): NimNode =
  ## Ok payload type T from `Future[Result[T, string]]` (async) or
  ## `Result[T, string]` (sync). Returns nil if the shape is invalid (error
  ## type must be `string`). FFI/in-process errors are pinned to `string`.
  if async:
    if returnType.kind != nnkBracketExpr or returnType.len != 2:
      return nil
    if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
      return nil
    let inner = returnType[1]
    if inner.kind != nnkBracketExpr or inner.len != 3:
      return nil
    if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
      return nil
    if not (inner[2].kind == nnkIdent and inner[2].eqIdent("string")):
      return nil
    return inner[1]
  else:
    if returnType.kind != nnkBracketExpr or returnType.len != 3:
      return nil
    if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Result"):
      return nil
    if not (returnType[2].kind == nnkIdent and returnType[2].eqIdent("string")):
      return nil
    return returnType[1]

proc sugarVerbIdent(p: NimNode): NimNode =
  let nm = p[0]
  if nm.kind == nnkPostfix:
    nm[1]
  else:
    nm

proc parseRequestSugar*(
    body: NimNode, macroName: string, async: bool
): ParsedRequestSugar =
  ## Parse the proc-style sugar form of a RequestBroker body (one broker per
  ## block, two signature slots, payload decoupled from the dispatch tag).
  var typeDecl: NimNode = nil
  var typeDoc = ""
  var procs: seq[NimNode] = @[]
  var procDocs: seq[string] = @[]
  var pendingDoc = ""
  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      procs.add(stmt)
      procDocs.add(
        joinDocText(pendingDoc, attachedDocText(newStmtList(copyNimTree(stmt))))
      )
      pendingDoc = ""
    of nnkTypeSection:
      for d in stmt:
        if d.kind == nnkTypeDef:
          if typeDecl != nil:
            error(macroName & " sugar allows a single payload type", d)
          typeDecl = d
      typeDoc = joinDocText(typeDoc, pendingDoc)
      pendingDoc = ""
    of nnkEmpty:
      discard
    of nnkCommentStmt:
      # `##` doc comment above the type / proc it precedes.
      pendingDoc = joinDocText(pendingDoc, stmt.strVal)
    else:
      error("Unsupported statement inside " & macroName & " definition", stmt)
  if procs.len == 0:
    error(macroName & " requires at least one signature proc", body)

  var verb = ""
  for p in procs:
    if verb.len == 0:
      verb = $sugarVerbIdent(p)
    elif not sugarVerbIdent(p).eqIdent(verb):
      error("All signatures in one " & macroName & " block must share the proc name", p)
  let brokerName = capitalizeAscii(verb)
  result.verb = verb

  if typeDecl != nil:
    let parsedT = parseSingleTypeDef(
      newTree(nnkStmtList, newTree(nnkTypeSection, typeDecl)),
      macroName,
      allowRefToNonObject = true,
      collectFieldInfo = true,
    )
    result.typeIdent = parsedT.typeIdent
    result.objectDef = parsedT.objectDef
    result.fieldTypes = parsedT.fieldTypes
    result.parsed = parsedT
    if not result.typeIdent.eqIdent(brokerName):
      error(
        "Signature `" & verb & "` must pair with type `" & brokerName & "` (got `" &
          $result.typeIdent & "`)",
        typeDecl,
      )
    result.payloadType = copyNimTree(result.typeIdent)
  else:
    # POD form: the broker name is derived solely from the proc verb and is
    # always Capitalized (it is a Nim type / dispatch tag). Warn when we had to
    # capitalize a lowercase verb so the `Broker.request(...)` handle name is
    # not a surprise; writing the proc Capitalized (`proc GetConfig(...)`) is
    # accepted and silences this.
    if verb.len > 0 and verb[0] in {'a' .. 'z'}:
      warning(
        "RequestBroker: broker name is `" & brokerName & "` (capitalized from proc `" &
          verb & "`); call it as `" & brokerName & ".request(...)`. Write `proc " &
          brokerName & "(...)` to name it explicitly and silence this warning.",
        procs[0],
      )
    result.typeIdent = ident(brokerName)

  for pi in 0 ..< procs.len:
    let p = procs[pi]
    let params = p.params
    if params.len == 0:
      error("Signature must declare a return type", p)
    let pl = extractResultOk(params[0], async)
    if pl.isNil:
      error(
        "Signature must return " &
          (if async: "Future[Result[T, string]]" else: "Result[T, string]"),
        p,
      )
    if result.payloadType.isNil:
      result.payloadType = copyNimTree(pl)
    elif result.payloadType.repr != pl.repr:
      error(
        "All signatures of broker `" & brokerName & "` must return the same payload type",
        p,
      )
    let paramCount = params.len - 1
    if paramCount == 0:
      if not result.zeroArgProc.isNil:
        error("Only one zero-argument signature is allowed", p)
      result.zeroArgProc = p
      result.zeroArgDoc = procDocs[pi]
    else:
      if not result.argProc.isNil:
        error("Only one argument-based signature is allowed", p)
      result.argProc = p
      result.argDoc = procDocs[pi]
      result.argParams = @[]
      for idx in 1 ..< params.len:
        let pd = params[idx]
        if pd.kind != nnkIdentDefs:
          error("Signature parameter must be a standard identifier declaration", pd)
        if pd[pd.len - 2].kind == nnkEmpty:
          error("Signature parameter must declare a type", pd)
        result.argParams.add(copyNimTree(pd))

  if typeDecl == nil:
    # POD: synthesize `type <tag> = <payload>` and parse it through the normal
    # path so the dispatch-tag classification (primitive / void / distinct) and
    # the API/CBOR schema registration match the legacy `type X = ...` form.
    let synth = newTree(
      nnkStmtList,
      newTree(
        nnkTypeSection,
        newTree(
          nnkTypeDef,
          copyNimTree(result.typeIdent),
          newEmptyNode(),
          copyNimTree(result.payloadType),
        ),
      ),
    )
    result.parsed = parseSingleTypeDef(
      synth, macroName, allowRefToNonObject = true, collectFieldInfo = true
    )
    result.objectDef = result.parsed.objectDef

  result.docText = joinDocText(typeDoc, result.parsed.docText)
  if result.docText.len == 0:
    # POD form without a documented type: the signature doc is the best
    # broker-level description we have.
    result.docText = if result.zeroArgDoc.len > 0: result.zeroArgDoc else: result.argDoc
  result.parsed.docText = result.docText

# ---------------------------------------------------------------------------
# Compile-time interface -> event-type registry. BrokerInterface records the
# event types it declares; BrokerImplement reads them so the generated
# `close()` can drop the instance's event listeners (the impl macro otherwise
# doesn't know the interface's events).
# ---------------------------------------------------------------------------

var gInterfaceEvents {.compileTime.}: seq[(string, seq[string])] = @[]

proc registerInterfaceEvents*(iface: string, events: seq[string]) {.compileTime.} =
  for i in 0 ..< gInterfaceEvents.len:
    if gInterfaceEvents[i][0] == iface:
      gInterfaceEvents[i][1] = events
      return
  gInterfaceEvents.add((iface, events))

proc interfaceEvents*(iface: string): seq[string] {.compileTime.} =
  for it in gInterfaceEvents:
    if it[0] == iface:
      return it[1]
  @[]

# ---------------------------------------------------------------------------
# Compile-time registry of interface signal types (SignalBroker sub-blocks).
# BrokerImplement reads them to (a) validate every declared signal has a
# handler override, install the per-instance handler, and (b) drop the handler
# in the generated `close()`. Mirrors the event registry above.
# ---------------------------------------------------------------------------

# Each entry: (signalTypeName, isVoid) — isVoid marks a payload-less pulse
# (`type X = void`), whose handler is zero-arg (`proc(): Future[void]`).
var gInterfaceSignals {.compileTime.}: seq[(string, seq[(string, bool)])] = @[]

proc registerInterfaceSignals*(
    iface: string, signals: seq[(string, bool)]
) {.compileTime.} =
  for i in 0 ..< gInterfaceSignals.len:
    if gInterfaceSignals[i][0] == iface:
      gInterfaceSignals[i][1] = signals
      return
  gInterfaceSignals.add((iface, signals))

proc interfaceSignals*(iface: string): seq[(string, bool)] {.compileTime.} =
  for it in gInterfaceSignals:
    if it[0] == iface:
      return it[1]
  @[]

# ---------------------------------------------------------------------------
# Compile-time registry of interface request verbs.
# Records, per interface, the verb name and the associated request type name.
# Used by BrokerImplement to validate that all declared requests are overridden.
# ---------------------------------------------------------------------------

var gInterfaceVerbs {.compileTime.}: seq[(string, seq[(string, string)])] = @[]

proc registerInterfaceVerbs*(
    iface: string, verbs: seq[(string, string)]
) {.compileTime.} =
  for i in 0 ..< gInterfaceVerbs.len:
    if gInterfaceVerbs[i][0] == iface:
      gInterfaceVerbs[i] = (iface, verbs)
      return
  gInterfaceVerbs.add((iface, verbs))

proc interfaceRequestVerbs*(iface: string): seq[(string, string)] {.compileTime.} =
  for it in gInterfaceVerbs:
    if it[0] == iface:
      return it[1]
  @[]

# ---------------------------------------------------------------------------
# Compile-time registry of `BrokerInterface(API)` interfaces (reduced-A, A1).
# Records, per interface, the sanitized request *type* names and event *type*
# names it owns. The flat CBOR request/event entry registries store these same
# type names (CborRequestEntry.responseTypeName / CborEventEntry.typeName), so
# wrapper codegen can partition the flat entry lists per interface by matching
# on type name — no need to replicate the snake/suffix apiName derivation here.
# ---------------------------------------------------------------------------

type ApiInterfaceEntry* = object
  name*: string
  requestTypes*: seq[string] ## sanitized request broker type names
  eventTypes*: seq[string] ## event payload type names
  signalTypes*: seq[string] ## sanitized signal broker type names

var gApiInterfaces {.compileTime.}: seq[ApiInterfaceEntry] = @[]

proc registerApiInterface*(
    name: string, requestTypes, eventTypes, signalTypes: seq[string]
) {.compileTime.} =
  for i in 0 ..< gApiInterfaces.len:
    if gApiInterfaces[i].name == name:
      gApiInterfaces[i].requestTypes = requestTypes
      gApiInterfaces[i].eventTypes = eventTypes
      gApiInterfaces[i].signalTypes = signalTypes
      return
  gApiInterfaces.add(
    ApiInterfaceEntry(
      name: name,
      requestTypes: requestTypes,
      eventTypes: eventTypes,
      signalTypes: signalTypes,
    )
  )

proc apiInterfaces*(): seq[ApiInterfaceEntry] {.compileTime.} =
  gApiInterfaces

proc isApiInterface*(name: string): bool {.compileTime.} =
  for it in gApiInterfaces:
    if it.name == name:
      return true
  false

proc interfaceOwningRequestType*(typeName: string): string {.compileTime.} =
  ## Comma-joined names of every interface that declared the request broker
  ## `typeName` (more than one when two interfaces reuse the same type name —
  ## itself the most common apiName collision), or "" if none.
  var owners: seq[string] = @[]
  for it in gApiInterfaces:
    for rt in it.requestTypes:
      if rt == typeName:
        owners.add(it.name)
  owners.join(", ")

proc interfaceOwningEventType*(typeName: string): string {.compileTime.} =
  var owners: seq[string] = @[]
  for it in gApiInterfaces:
    for et in it.eventTypes:
      if et == typeName:
        owners.add(it.name)
  owners.join(", ")

proc interfaceOwningSignalType*(typeName: string): string {.compileTime.} =
  var owners: seq[string] = @[]
  for it in gApiInterfaces:
    for st in it.signalTypes:
      if st == typeName:
        owners.add(it.name)
  owners.join(", ")
