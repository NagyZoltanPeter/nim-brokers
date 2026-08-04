## Security regression test — finding M3 (SECURITY_AUDIT_2026-07.md).
##
## `readValue[T: enum]` in `brokers/internal/api_cbor_codec.nim:98-107` validates
## a decoded enum only against the `[ord(T.low), ord(T.high)]` RANGE, not against
## actual set membership:
##
##   if i < ord(T.low) or i > ord(T.high):
##     raise ... "out of range"
##   value = T(i)
##
## For a HOLEY enum (`A = 0, B = 2, C = 5`) an attacker-supplied wire integer of
## 1, 3 or 4 sits inside the range but is not a member. It is accepted and
## `T(i)` constructs an INVALID enum value, which is undefined behaviour to use
## downstream (`case`, array indexing on a jump table).
##
## The Table-KEY path already does this correctly — `toKey[T: enum]` in
## `api_cbor_tables.nim:86-93` walks the members and raises `ValueError`,
## commented "validate against the actual values so holey enums and corrupt
## input raise a catchable ValueError". These tests assert the value path
## behaves the same way.
##
## PRE-FIX EXPECTATION: the `holey` cases FAIL (decode returns ok on a
## non-member). POST-FIX: all pass. The contiguous-enum and Table-key cases
## must pass both before and after — they guard against over-correction.
##
## Run:
##   nim c -r --path:. --outdir:build test/security/test_m3_holey_enum.nim

{.used.}

import std/tables
import results
import testutils/unittests
import brokers/internal/api_cbor_codec

type
  # Holey: ordinals 1, 3 and 4 are inside [0, 5] but are NOT members.
  HoleyPriority = enum
    hpLow = 0
    hpMedium = 2
    hpHigh = 5

  # Contiguous control: every ordinal in [0, 2] is a member.
  DenseColor = enum
    dcRed = 0
    dcGreen = 1
    dcBlue = 2

  HoleyField = object
    priority: HoleyPriority

  HoleyKeyed = object
    byPriority: Table[HoleyPriority, int32]

## CBOR encoding of a bare unsigned int small enough for the immediate form
## (major type 0, additional info = value) — one byte for 0..23.
proc cborUInt(n: byte): seq[byte] =
  doAssert n <= 23, "only the immediate-form encoding is needed here"
  @[n]

suite "M3 — holey enum decode must validate membership, not just range":
  test "bare enum: non-member ordinal inside the range is rejected":
    # 1, 3, 4 are all within [ord(hpLow)=0, ord(hpHigh)=5] but are not members.
    for bogus in [1'u8, 3'u8, 4'u8]:
      let decoded = cborDecode(cborUInt(bogus), HoleyPriority)
      check:
        decoded.isErr()

  test "bare enum: every real member still round-trips":
    for member in [hpLow, hpMedium, hpHigh]:
      let encoded = cborEncode(member)
      require encoded.isOk()
      let decoded = cborDecode(encoded.value, HoleyPriority)
      check:
        decoded.isOk()
        decoded.value == member

  test "bare enum: ordinals outside the range are still rejected":
    # Guards the existing range check is not lost by the membership fix.
    let decoded = cborDecode(cborUInt(6), HoleyPriority)
    check:
      decoded.isErr()

  test "object field: non-member ordinal is rejected":
    # Same hazard reached through an object field rather than a bare value.
    let encoded = cborEncode(HoleyField(priority: hpMedium))
    require encoded.isOk()
    # Rewrite the encoded ordinal 2 -> 3 (a non-member still inside the range).
    var tampered = encoded.value
    var patched = false
    for i in 0 ..< tampered.len:
      if tampered[i] == 2'u8:
        tampered[i] = 3'u8
        patched = true
        break
    require patched
    let decoded = cborDecode(tampered, HoleyField)
    check:
      decoded.isErr()

  test "contiguous enum is unaffected (no over-correction)":
    for member in [dcRed, dcGreen, dcBlue]:
      let encoded = cborEncode(member)
      require encoded.isOk()
      let decoded = cborDecode(encoded.value, DenseColor)
      check:
        decoded.isOk()
        decoded.value == member
    # One past the top is still out of range.
    check:
      cborDecode(cborUInt(3), DenseColor).isErr()

  test "control: Table-key path already validates membership":
    # api_cbor_tables.nim:86-93 — this is the behaviour the value path should
    # match. Passes before AND after the fix; if it ever fails, the reference
    # implementation regressed.
    var t: Table[HoleyPriority, int32]
    t[hpMedium] = 7'i32
    let encoded = cborEncode(HoleyKeyed(byPriority: t))
    require encoded.isOk()
    let decoded = cborDecode(encoded.value, HoleyKeyed)
    check:
      decoded.isOk()
      decoded.value.byPriority.getOrDefault(hpMedium) == 7'i32
