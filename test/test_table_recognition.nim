## Phase 2 recognition unit test: makeFieldDef parsing of Table[K, V].
## Compile-time assertions only — exercises the schema parsing path that the
## FFI codegen consumes, independent of wrapper generation.

import ../brokers/internal/api_schema

static:
  block stringKeyPrimitiveValue:
    let f = makeFieldDef("m", "Table[string, int32]")
    doAssert f.isTable
    doAssert not f.isSeq
    doAssert not f.isArray
    doAssert not f.isCustomObject
    doAssert f.tableKeyType == "string"
    doAssert f.tableValueType == "int32"

  block intKeyObjectValue:
    let f = makeFieldDef("m", "Table[int32, DeviceInfo]")
    doAssert f.isTable
    doAssert f.tableKeyType == "int32"
    doAssert f.tableValueType == "DeviceInfo"

  block seqValueWithInnerComma:
    # value carries its own bracket but no top-level comma
    let f = makeFieldDef("m", "Table[int64, seq[string]]")
    doAssert f.isTable
    doAssert f.tableKeyType == "int64"
    doAssert f.tableValueType == "seq[string]"

  block arrayValueWithInnerComma:
    # value's own comma must NOT be mistaken for the key/value separator
    let f = makeFieldDef("m", "Table[char, array[3, int32]]")
    doAssert f.isTable
    doAssert f.tableKeyType == "char"
    doAssert f.tableValueType == "array[3, int32]"

  block nestedTableValue:
    let f = makeFieldDef("m", "Table[string, Table[int32, string]]")
    doAssert f.isTable
    doAssert f.tableKeyType == "string"
    doAssert f.tableValueType == "Table[int32, string]"

  block keyPrimitiveAllowlist:
    doAssert isAllowedTableKeyPrimitive("string")
    doAssert isAllowedTableKeyPrimitive("int8")
    doAssert isAllowedTableKeyPrimitive("int64")
    doAssert isAllowedTableKeyPrimitive("char")
    doAssert not isAllowedTableKeyPrimitive("int")
    doAssert not isAllowedTableKeyPrimitive("uint32")
    doAssert not isAllowedTableKeyPrimitive("bool")
    doAssert not isAllowedTableKeyPrimitive("float")

echo "table recognition: OK"
