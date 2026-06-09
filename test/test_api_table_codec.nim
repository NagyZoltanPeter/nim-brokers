## Brokers-side Table[K, V] CBOR round-trip.
##
## Verifies that `api_cbor_tables` provides full scalar-key support against the
## UPSTREAM (unpatched) cbor_serialization — string / int8..64 / char / enum
## (ordinal) / distinct-of-scalar keys, plus object and nested-seq values.

import std/[tables, hashes]
import cbor_serialization
import ../brokers/internal/api_cbor_tables

type
  Color = enum
    cRed = 0
    cGreen = 1
    cBlue = 2

  DeviceId = distinct int32

  Payload = object
    name: string
    score: int32

proc `==`(a, b: DeviceId): bool {.borrow.}
proc hash(x: DeviceId): Hash {.borrow.}

block stringKeys:
  let t = {"a": 1'i32, "b": 2'i32}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[string, int32]) == t

block int32Keys:
  let t = {10'i32: "x", 20'i32: "y"}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[int32, string]) == t

block int8KeysRange:
  let t = {(-5'i8): 1'i32, 127'i8: 2'i32}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[int8, int32]) == t

block int64Keys:
  let t = {9000000000'i64: 1'i32}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[int64, int32]) == t

block charKeys:
  let t = {'a': 1'i32, 'z': 2'i32}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[char, int32]) == t

block enumKeysOrdinal:
  let t = {cRed: 1'i32, cBlue: 3'i32}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[Color, int32]) == t

block distinctKeys:
  var t = initTable[DeviceId, int32]()
  t[DeviceId(7)] = 100'i32
  t[DeviceId(8)] = 200'i32
  let back = Cbor.decode(Cbor.encode(t), Table[DeviceId, int32])
  doAssert back.len == 2
  doAssert back[DeviceId(7)] == 100'i32
  doAssert back[DeviceId(8)] == 200'i32

block objectValue:
  let t = {"p1": Payload(name: "a", score: 1'i32)}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[string, Payload]) == t

block nestedSeqValue:
  let t = {1'i32: @["a", "b"], 2'i32: @["c"]}.toTable
  doAssert Cbor.decode(Cbor.encode(t), Table[int32, seq[string]]) == t

echo "api_cbor_tables round-trip: OK"
