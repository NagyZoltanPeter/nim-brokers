## Unit tests for the CBOR codec primitives shared by the CBOR FFI strategy.
##
## Round-trip every supported Nim type and confirm the response-envelope
## helpers cleanly map `Result[T, string]` to CBOR and back.

import std/[options]
import results
import testutils/unittests
import brokers/internal/api_cbor_codec

type
  Color = enum
    cRed
    cGreen
    cBlue

  Point = object
    x: int32
    y: int32

  Player = object
    name: string
    score: uint64
    favorite: Color
    pos: Point

# Round-trip helpers are written as standalone procs (one per concrete type)
# rather than a generic template. testutils' `test` macro re-introduces a
# generic context that mishandles nested template expansions of generic
# helpers — concrete procs sidestep the issue entirely.

proc rtInt32(v: int32): int32 =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, int32)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtUInt64(v: uint64): uint64 =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, uint64)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtBool(v: bool): bool =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, bool)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtString(v: string): string =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, string)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtFloat64(v: float64): float64 =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, float64)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtSeqInt32(v: seq[int32]): seq[int32] =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, seq[int32])
  doAssert dec.isOk(), dec.error
  dec.value

proc rtSeqString(v: seq[string]): seq[string] =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, seq[string])
  doAssert dec.isOk(), dec.error
  dec.value

proc rtColor(v: Color): Color =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, Color)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtPlayer(v: Player): Player =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, Player)
  doAssert dec.isOk(), dec.error
  dec.value

proc rtOptInt32(v: Option[int32]): Option[int32] =
  let enc = cborEncode(v)
  doAssert enc.isOk(), enc.error
  let dec = cborDecode(enc.value, Option[int32])
  doAssert dec.isOk(), dec.error
  dec.value

suite "api_cbor_codec":
  test "round-trip primitives":
    check rtInt32(42) == 42
    check rtUInt64(0xdeadbeef'u64) == 0xdeadbeef'u64
    check rtBool(true) == true
    check rtBool(false) == false
    check rtString("hello, broker") == "hello, broker"
    check rtFloat64(3.14) == 3.14

  test "round-trip seq[T]":
    let s = @[1'i32, 2, 3, 4, 5]
    check rtSeqInt32(s) == s
    let strs = @["alpha", "beta", "gamma"]
    check rtSeqString(strs) == strs
    let empty: seq[int32] = @[]
    check rtSeqInt32(empty) == empty

  test "round-trip enum":
    check rtColor(cGreen) == cGreen

  test "round-trip nested object":
    let p = Player(name: "Ada", score: 9000, favorite: cBlue, pos: Point(x: -1, y: 7))
    let r = rtPlayer(p)
    check r.name == p.name
    check r.score == p.score
    check r.favorite == p.favorite
    check r.pos.x == p.pos.x
    check r.pos.y == p.pos.y

  test "round-trip Option[T]":
    let some42 = some(int32(42))
    check rtOptInt32(some42) == some42
    let noneI: Option[int32] = none(int32)
    check rtOptInt32(noneI) == noneI

  test "Result envelope - ok with payload":
    let r = Result[int32, string].ok(7)
    let enc = cborEncodeResultEnvelope(r)
    check enc.isOk()
    let dec = cborDecodeResultEnvelope(enc.value, int32)
    check dec.isOk()
    check dec.value == 7

  test "Result envelope - err with message":
    let r = Result[int32, string].err("provider rejected request")
    let enc = cborEncodeResultEnvelope(r)
    check enc.isOk()
    let dec = cborDecodeResultEnvelope(enc.value, int32)
    check dec.isErr()
    check dec.error == "provider rejected request"

  test "Result envelope - object payload":
    let r = Result[Player, string].ok(
      Player(name: "Bob", score: 1, favorite: cRed, pos: Point(x: 0, y: 0))
    )
    let enc = cborEncodeResultEnvelope(r)
    check enc.isOk()
    let dec = cborDecodeResultEnvelope(enc.value, Player)
    check dec.isOk()
    check dec.value.name == "Bob"
    check dec.value.favorite == cRed

  test "Result envelope - void payload via CborUnit":
    let r = Result[CborUnit, string].ok(CborUnit())
    let enc = cborEncodeResultEnvelope(r)
    check enc.isOk()
    let dec = cborDecodeResultEnvelope(enc.value, CborUnit)
    check dec.isOk()

  test "decode rejects malformed bytes":
    let badBuf = @[0xff'u8, 0xff, 0xff]
    let dec = cborDecode(badBuf, int32)
    check dec.isErr()

  test "envelope decode rejects buffer that is not an envelope":
    let plainBytes = cborEncode(int32(99)).value
    let dec = cborDecodeResultEnvelope(plainBytes, int32)
    # A bare CBOR int does not satisfy the envelope object schema; expect err.
    check dec.isErr()
