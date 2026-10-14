## api_schema_hash
## ---------------
## Wire-schema fingerprint for the CBOR FFI surface.
##
## `registerBrokerLibrary` reduces the library's request / event / signal
## entries and the type registry to one canonical text that captures only what
## is ABI (names, wire types, enum ordinals, interface membership, the codec
## convention version) and hashes it with FNV-1a-128 into 32 lowercase hex
## chars. The same value is burned into the library (`<lib>_verifySchema`) and
## into every generated wrapper, so a wrapper can detect at runtime that it was
## generated against a different schema than the loaded library.
##
## Deliberately excluded (rebuilding with these changed keeps the hash): doc
## comments, the `version:` string, capacity / timeout knobs, generated
## adapter identifiers, `mainClass`, and object field order (objects travel
## as CBOR maps keyed by field name).
##
## Not a security property — the threat is accidental mismatch.

{.push raises: [].}

import std/[algorithm, sequtils, strutils]
import ./api_common
import ./helper/broker_utils

const SchemaHashLen* = 32 ## hex chars in a schema fingerprint

proc mulAdd64(a, b: uint64): tuple[hi, lo: uint64] =
  ## Full 64x64 -> 128 multiply via 32-bit halves (compile-time-VM-safe).
  let
    aLo = a and 0xFFFF_FFFF'u64
    aHi = a shr 32
    bLo = b and 0xFFFF_FFFF'u64
    bHi = b shr 32
    ll = aLo * bLo
    lh = aLo * bHi
    hl = aHi * bLo
    hh = aHi * bHi
    mid = (ll shr 32) + (lh and 0xFFFF_FFFF'u64) + (hl and 0xFFFF_FFFF'u64)
  result.lo = (mid shl 32) or (ll and 0xFFFF_FFFF'u64)
  result.hi = hh + (lh shr 32) + (hl shr 32) + (mid shr 32)

proc fnv1a128Hex*(s: string): string =
  ## FNV-1a-128 of `s`, as 32 lowercase hex chars (high limb first).
  ## prime = 2^88 + 0x13B; offset basis per the FNV spec.
  var
    hi = 0x6c62272e07bb0142'u64
    lo = 0x62b821756295c58d'u64
  for ch in s:
    lo = lo xor uint64(ord(ch))
    # (hi:lo) * (2^88 + 0x13B) mod 2^128
    let m = mulAdd64(lo, 0x13B'u64)
    let newHi = hi * 0x13B'u64 + m.hi + (lo shl 24)
    lo = m.lo
    hi = newHi
  result = toHex(hi).toLowerAscii() & toHex(lo).toLowerAscii()

proc normSchemaType(t: string, aliases: seq[(string, string)], depth = 0): string =
  ## Strip whitespace, spell `Opt` as `Option` (same wire form), and resolve
  ## alias / distinct names to their underlying type (wire-transparent).
  var i = 0
  while i < t.len:
    let c = t[i]
    if c in IdentChars:
      var j = i
      while j < t.len and t[j] in IdentChars:
        inc j
      let tok = t[i ..< j]
      var resolved = false
      if depth < 16:
        for (name, underlying) in aliases:
          if name == tok:
            result.add(normSchemaType(underlying, aliases, depth + 1))
            resolved = true
            break
      if not resolved:
        result.add(if tok == "Opt": "Option" else: tok)
      i = j
    else:
      if c notin Whitespace:
        result.add(c)
      inc i

proc buildSchemaCanonical*(
    libName: string,
    requests: seq[CborRequestEntry],
    events: seq[CborEventEntry],
    signals: seq[CborSignalEntry],
    types: seq[ApiTypeEntry],
): string {.compileTime.} =
  ## The canonical ABI text hashed by `computeSchemaHash`. Every section is
  ## sorted so registration order never matters.
  var aliases: seq[(string, string)] = @[]
  for t in types:
    if t.kind in {atkAlias, atkDistinct}:
      aliases.add((t.name, t.underlyingType))

  var lines: seq[string] = @[]
  for r in requests:
    var args: seq[string] = @[]
    for (n, ty) in r.argFields:
      args.add(n & ":" & normSchemaType(ty, aliases))
    args.sort()
    lines.add(
      "req:" & r.apiName & "(" & args.join(",") & ")->" &
        normSchemaType(r.responseTypeName, aliases) & "@" &
        interfaceOwningRequestType(r.responseTypeName) & "|" & r.returnsInterface
    )
  for e in events:
    lines.add(
      "evt:" & e.apiName & ":" & normSchemaType(e.typeName, aliases) & "@" &
        interfaceOwningEventType(e.typeName)
    )
  for s in signals:
    lines.add(
      "sig:" & s.apiName & ":" & normSchemaType(s.typeName, aliases) & "@" &
        interfaceOwningSignalType(s.typeName)
    )
  for t in types:
    case t.kind
    of atkObject:
      var fields: seq[string] = @[]
      for f in t.fields:
        fields.add(f.name & ":" & normSchemaType(f.nimType, aliases))
      fields.sort()
      lines.add("type:" & t.name & "=obj{" & fields.join(",") & "}")
    of atkEnum:
      var vals = t.enumValues
      vals.sort(
        proc(a, b: ApiEnumValue): int =
          cmp(a.ordinal, b.ordinal)
      )
      var parts: seq[string] = @[]
      for v in vals:
        parts.add($v.ordinal & ":" & v.name)
      lines.add("type:" & t.name & "=enum{" & parts.join(",") & "}")
    of atkAlias, atkDistinct:
      discard # resolved into their uses
  lines.sort()
  lines = lines.deduplicate(isSorted = true)

  result = "brokers-wire:" & $BrokerFfiWireVersion & "\nlib:" & libName & "\n"
  result.add(lines.join("\n"))

proc computeSchemaHash*(
    libName: string,
    requests: seq[CborRequestEntry],
    events: seq[CborEventEntry],
    signals: seq[CborSignalEntry],
    types: seq[ApiTypeEntry],
): string {.compileTime.} =
  ## 32 lowercase hex chars identifying the library's wire schema.
  fnv1a128Hex(buildSchemaCanonical(libName, requests, events, signals, types))

{.pop.}
