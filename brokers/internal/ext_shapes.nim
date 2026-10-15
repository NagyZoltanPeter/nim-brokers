## EXTAPI wire shapes — the structural form of a Nim type as it travels in
## CBOR, used for the plugin schema hash and the K2 peer comparison (EXTAPI
## review M13).
##
## Grammar (identical on both sides, so a typed shape from this module and a
## shape expanded from a peer's `_getSchema` JSON compare as strings):
##   bool char string cstring int int8..int64 uint uint8..uint64 float32 float64
##   ptr                     raw pointers (K1 inplace only)
##   seq[S] opt[S] table[K,V] array[N,S]
##   obj{f1:S1,f2:S2}        fields sorted by name; type names are not wire data
##   enum{0:a,1:b}           ordinals and names
## alias / distinct / range types are their underlying shape.

{.push raises: [].}

import std/[algorithm, macros, strutils, tables]

const ShapeSep* = "\x1f" ## separates shapes in `extTypeShapes`' result

proc primShape(k: NimTypeKind): string {.compileTime.} =
  case k
  of ntyBool: "bool"
  of ntyChar: "char"
  of ntyString: "string"
  of ntyCString: "cstring"
  of ntyInt: "int"
  of ntyInt8: "int8"
  of ntyInt16: "int16"
  of ntyInt32: "int32"
  of ntyInt64: "int64"
  of ntyUInt: "uint"
  of ntyUInt8: "uint8"
  of ntyUInt16: "uint16"
  of ntyUInt32: "uint32"
  of ntyUInt64: "uint64"
  of ntyFloat, ntyFloat64: "float64"
  of ntyFloat32: "float32"
  of ntyPtr, ntyPointer: "ptr"
  else: ""

proc cat(parts: varargs[NimNode]): NimNode {.compileTime.} =
  ## String concatenation of `parts` (each a string-typed expression).
  result = parts[0]
  for i in 1 ..< parts.len:
    result = infix(result, "&", parts[i])

proc typedShape(t: NimNode, depth: int): NimNode {.compileTime.} =
  ## A constant string expression: literals, plus `$ord(T.field)` for enum
  ## ordinals (the typed enum AST does not carry explicit values).
  if depth > 24:
    return newLit("?")
  # Generic instances the wire treats specially, by their written name.
  let inst = getTypeInst(t)
  if inst.kind == nnkBracketExpr and inst.len >= 2:
    let head = (if inst[0].kind in {nnkSym, nnkIdent}: $inst[0]
    else: "")
    case head
    of "Option", "Opt":
      return cat(newLit("opt["), typedShape(inst[1], depth + 1), newLit("]"))
    of "Table", "OrderedTable":
      if inst.len >= 3:
        return cat(
          newLit("table["),
          typedShape(inst[1], depth + 1),
          newLit(","),
          typedShape(inst[2], depth + 1),
          newLit("]"),
        )
    else:
      discard
  let k = t.typeKind
  let p = primShape(k)
  if p.len > 0:
    return newLit(p)
  let impl = getTypeImpl(t)
  case k
  of ntyDistinct:
    typedShape(impl[0], depth + 1)
  of ntyRange:
    # `range[a .. b]` of an integer type: the base type's shape.
    if impl.kind == nnkBracketExpr and impl.len >= 2 and impl[1].kind == nnkInfix:
      typedShape(getType(impl[1][1]), depth + 1)
    else:
      newLit("int")
  of ntySequence:
    cat(newLit("seq["), typedShape(impl[1], depth + 1), newLit("]"))
  of ntyArray:
    var n = 0
    let idx = impl[1]
    if idx.kind == nnkInfix and idx.len == 3:
      n = int(idx[2].intVal - idx[1].intVal + 1)
    elif idx.kind in {nnkIntLit .. nnkUInt64Lit}:
      n = int(idx.intVal)
    cat(newLit("array[" & $n & ","), typedShape(impl[2], depth + 1), newLit("]"))
  of ntyEnum:
    let tsym = (if inst.kind == nnkSym: inst else: t)
    var parts = @[newLit("enum{")]
    var first = true
    for i in 1 ..< impl.len:
      let f = impl[i]
      let fname = (if f.kind == nnkEnumFieldDef: $f[0] else: $f)
      if not first:
        parts.add(newLit(","))
      first = false
      parts.add(prefix(newCall("ord", newDotExpr(tsym, ident(fname))), "$"))
      parts.add(newLit(":" & fname))
    parts.add(newLit("}"))
    cat(parts)
  of ntyRef:
    typedShape(impl[0], depth + 1)
  of ntyObject:
    var fields: seq[(string, NimNode)]
    let recList = (if impl.kind == nnkObjectTy: impl[2]
    else: newEmptyNode())
    for f in recList:
      if f.kind == nnkIdentDefs:
        for j in 0 ..< f.len - 2:
          fields.add(($f[j], typedShape(f[^2], depth + 1)))
    fields.sort(
      proc(a, b: (string, NimNode)): int =
        cmp(a[0], b[0])
    )
    var parts = @[newLit("obj{")]
    for i, (n, sh) in fields:
      parts.add(newLit((if i > 0: "," else: "") & n & ":"))
      parts.add(sh)
    parts.add(newLit("}"))
    cat(parts)
  else:
    newLit("?" & $k)

macro extTypeShapes*(types: varargs[typed]): string =
  ## The wire shapes of `types`, joined by `ShapeSep`: a constant string
  ## expression, so it can feed a `static string` parameter.
  var parts: seq[NimNode]
  for i, t in types:
    let inst = getTypeInst(t)
    let ty = (if inst.kind == nnkBracketExpr and inst.len == 2: inst[1]
    else: t)
    if i > 0:
      parts.add(newLit(ShapeSep))
    parts.add(typedShape(ty, 0))
  if parts.len == 0:
    return newLit("")
  cat(parts)

proc normPrim(t: string): string =
  case t
  of "byte": "uint8"
  of "float": "float64"
  of "Natural", "Positive": "int"
  of "cint": "int32"
  of "cuint": "uint32"
  of "clonglong": "int64"
  of "culonglong": "uint64"
  of "pointer": "ptr"
  else: t

proc splitTop(s: string): seq[string] =
  ## "a, b[c, d]" -> @["a", "b[c,d]"] (top-level commas only).
  var depth = 0
  var cur = ""
  for ch in s:
    case ch
    of '[':
      inc depth
      cur.add(ch)
    of ']':
      dec depth
      cur.add(ch)
    of ',':
      if depth == 0:
        result.add(cur.strip())
        cur = ""
      else:
        cur.add(ch)
    else:
      cur.add(ch)
  if cur.strip().len > 0:
    result.add(cur.strip())

type
  PeerTypeKind* = enum
    ptkObject
    ptkEnum
    ptkAlias

  PeerType* = object ## A type record from a peer's `_getSchema` JSON.
    kind*: PeerTypeKind
    fields*: seq[(string, string)] ## object: (name, nimType)
    enumValues*: seq[(int, string)] ## enum: (ordinal, name)
    underlying*: string ## alias / distinct

proc peerShape*(t: string, types: Table[string, PeerType], depth = 0): string =
  ## The wire shape of a peer type string, expanded through the peer's own
  ## type records — the same grammar as `extTypeShapes`.
  if depth > 24:
    return "?"
  let s = t.replace(" ", "")
  let br = s.find('[')
  if br > 0 and s.endsWith("]"):
    let head = s[0 ..< br]
    let inner = splitTop(s[br + 1 ..^ 2])
    case head
    of "seq":
      return "seq[" & peerShape(inner[0], types, depth + 1) & "]"
    of "Option", "Opt":
      return "opt[" & peerShape(inner[0], types, depth + 1) & "]"
    of "Table", "OrderedTable":
      if inner.len == 2:
        return
          "table[" & peerShape(inner[0], types, depth + 1) & "," &
          peerShape(inner[1], types, depth + 1) & "]"
    of "array":
      if inner.len == 2:
        var n = inner[0]
        let dots = n.find("..")
        if dots > 0:
          try:
            n = $(parseInt(n[dots + 2 ..^ 1]) - parseInt(n[0 ..< dots]) + 1)
          except ValueError:
            discard
        return "array[" & n & "," & peerShape(inner[1], types, depth + 1) & "]"
    of "ptr":
      return "ptr"
    else:
      discard
  if s in types:
    let rec = types.getOrDefault(s)
    case rec.kind
    of ptkObject:
      var fields: seq[string]
      for (n, ft) in rec.fields:
        fields.add(n & ":" & peerShape(ft, types, depth + 1))
      fields.sort()
      return "obj{" & fields.join(",") & "}"
    of ptkEnum:
      var vals = rec.enumValues
      vals.sort(
        proc(a, b: (int, string)): int =
          cmp(a[0], b[0])
      )
      var parts: seq[string]
      for (o, n) in vals:
        parts.add($o & ":" & n)
      return "enum{" & parts.join(",") & "}"
    of ptkAlias:
      return peerShape(rec.underlying, types, depth + 1)
  if s.startsWith("ptr"):
    return "ptr"
  normPrim(s)

{.pop.}
