## Unit tests for the CBOR FFI schema fingerprint (`api_schema_hash.nim`).
##
## The fingerprint must change on every wire-relevant schema change and stay
## stable across everything else (docs, field order, knobs). All hashes are
## computed at compile time from synthetic registries, mirroring how
## `registerBrokerLibrary` computes them.

import testutils/unittests
import brokers/internal/api_schema_hash
import brokers/internal/api_common

proc fld(name, ty: string, doc = ""): ApiFieldDef {.compileTime.} =
  ApiFieldDef(name: name, nimType: ty, doc: doc)

proc baseTypes(): seq[ApiTypeEntry] {.compileTime.} =
  @[
    ApiTypeEntry(
      name: "Device",
      kind: atkObject,
      fields: @[fld("id", "int64"), fld("name", "string"), fld("tags", "seq[string]")],
    ),
    ApiTypeEntry(
      name: "Priority",
      kind: atkEnum,
      enumValues:
        @[ApiEnumValue(name: "low", ordinal: 0), ApiEnumValue(name: "high", ordinal: 1)],
    ),
    ApiTypeEntry(name: "DeviceId", kind: atkDistinct, underlyingType: "int64"),
  ]

proc baseReqs(): seq[CborRequestEntry] {.compileTime.} =
  @[
    CborRequestEntry(
      apiName: "get_device",
      adapterProc: "getDeviceAdapter",
      responseTypeName: "Device",
      argFields: @[("id", "DeviceId"), ("verbose", "bool")],
    )
  ]

proc baseEvts(): seq[CborEventEntry] {.compileTime.} =
  @[CborEventEntry(apiName: "device_changed", typeName: "Device")]

proc baseSigs(): seq[CborSignalEntry] {.compileTime.} =
  @[CborSignalEntry(apiName: "ping", typeName: "Priority")]

proc h(
    reqs = baseReqs(),
    evts = baseEvts(),
    sigs = baseSigs(),
    types = baseTypes(),
    lib = "testlib",
): string {.compileTime.} =
  computeSchemaHash(lib, reqs, evts, sigs, types)

const base = h()

# ---- must stay the same --------------------------------------------------
const docEdit = block:
  var t = baseTypes()
  t[0].doc = "A device."
  t[0].fields[1].doc = "Display name."
  var r = baseReqs()
  r[0].doc = "Fetch one device."
  h(reqs = r, types = t)

const fieldReorder = block:
  var t = baseTypes()
  t[0].fields = @[t[0].fields[2], t[0].fields[0], t[0].fields[1]]
  h(types = t)

const argReorder = block:
  var r = baseReqs()
  r[0].argFields = @[r[0].argFields[1], r[0].argFields[0]]
  h(reqs = r)

const adapterRename = block:
  var r = baseReqs()
  r[0].adapterProc = "somethingElse"
  h(reqs = r)

const registrationOrder = block:
  var t = baseTypes()
  t = @[t[2], t[1], t[0]]
  h(types = t)

const distinctInlined = block:
  # `DeviceId` is wire-transparent: spelling the arg as its underlying type
  # is the same schema.
  var r = baseReqs()
  r[0].argFields[0] = ("id", "int64")
  h(reqs = r)

const optSpelling = block:
  var t = baseTypes()
  t[0].fields.add(fld("alias", "Option[string]"))
  let a = h(types = t)
  t[0].fields[^1] = fld("alias", "Opt[ string ]")
  (a, h(types = t))

# ---- must change ---------------------------------------------------------
const fieldType = block:
  var t = baseTypes()
  t[0].fields[0] = fld("id", "int32")
  h(types = t)

const optionWrap = block:
  var t = baseTypes()
  t[0].fields[1] = fld("name", "Option[string]")
  h(types = t)

const fieldAdded = block:
  var t = baseTypes()
  t[0].fields.add(fld("extra", "bool"))
  h(types = t)

const fieldRenamed = block:
  var t = baseTypes()
  t[0].fields[1] = fld("label", "string")
  h(types = t)

const enumOrdinal = block:
  var t = baseTypes()
  t[1].enumValues[1].ordinal = 2
  h(types = t)

const enumName = block:
  var t = baseTypes()
  t[1].enumValues[1].name = "urgent"
  h(types = t)

const apiRenamed = block:
  var r = baseReqs()
  r[0].apiName = "fetch_device"
  h(reqs = r)

const requestAdded = block:
  var r = baseReqs()
  r.add(CborRequestEntry(apiName: "list_devices", responseTypeName: "Device"))
  h(reqs = r)

const argTypeChanged = block:
  var r = baseReqs()
  r[0].argFields[1] = ("verbose", "int32")
  h(reqs = r)

const eventPayload = block:
  var e = baseEvts()
  e[0].typeName = "Priority"
  h(evts = e)

const signalRemoved = h(sigs = @[])

const libRenamed = h(lib = "otherlib")

const returnsIface = block:
  var r = baseReqs()
  r[0].returnsInterface = "IWidget"
  h(reqs = r)

suite "FFI schema fingerprint":
  test "FNV-1a-128 reference vectors":
    check fnv1a128Hex("") == "6c62272e07bb014262b821756295c58d"
    check fnv1a128Hex("a") == "d228cb696f1a8caf78912b704e4a8964"
    check fnv1a128Hex("foobar") == "343e1662793c64bf6f0d3597ba446f18"

  test "compile-time and runtime FNV agree":
    const ct = fnv1a128Hex("brokers-wire")
    check fnv1a128Hex("brokers-wire") == ct

  test "fingerprint is 32 lowercase hex chars":
    check base.len == SchemaHashLen
    for c in base:
      check c in {'0' .. '9', 'a' .. 'f'}

  test "non-ABI changes keep the fingerprint":
    check docEdit == base
    check fieldReorder == base
    check argReorder == base
    check adapterRename == base
    check registrationOrder == base
    check distinctInlined == base
    check optSpelling[0] == optSpelling[1]

  test "ABI changes alter the fingerprint":
    for changed in [
      fieldType, optionWrap, fieldAdded, fieldRenamed, enumOrdinal, enumName,
      apiRenamed, requestAdded, argTypeChanged, eventPayload, signalRemoved, libRenamed,
      returnsIface,
    ]:
      check changed != base
