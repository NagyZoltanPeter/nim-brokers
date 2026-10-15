{.used.}

## EXTAPI schema checks (review M13, M14):
## - the plugin schema hash covers the wire shape of nested types (golden);
## - a K2 peer whose type differs in a field (same type name) is refused;
## - `BROKERS_FFI_SKIP_SCHEMA_CHECK` / `<PLUGIN>_SKIP_SCHEMA_CHECK` let a
##   mismatching `open` through, like `<lib>_verifySchema`.

import testutils/unittests
import chronos
import std/[options, os, osproc, strutils, tables]

import brokers/[request_broker, ext_plugin, broker_context]
import brokers/internal/ext_runtime

const repoRoot = currentSourcePath.parentDir.parentDir

# --- a plugin whose hash is pinned (golden) ---------------------------------
# Foreign plugins get generated wrappers, which map inline payload fields
# only; nested object shapes are exercised by the K2 test below.

RequestBroker(EXTAPI[shapegold]):
  type ShapeReq = object
    tags*: seq[string]
    blob*: seq[byte]
    maybe*: Option[int32]
    counts*: Table[string, int32]

  proc signature*(key: string, n: int32): Future[Result[ShapeReq, string]] {.async.}

registerExtPlugin(shapegold)

# Canonical text (ext_shapes grammar, "brokers-ext:2"):
#   enkRequest:shape_req(key:string,n:int32)->obj{blob:seq[uint8],
#     counts:table[string,int32],maybe:opt[int32],tags:seq[string]}
const ShapeGoldHash = "622a4cb849160566a4e1a2b0d8ce5476"

# --- K2: a consumer whose PeerEcho has a different field type ---------------

when defined(macosx):
  const peerLib = repoRoot & "/build/libpeerlib_schema.dylib"
else:
  const peerLib = repoRoot & "/build/libpeerlib_schema.so"

RequestBroker(EXTAPI[peerbad], importLib = "peerlib", dynlib = peerLib):
  type PeerEcho = object
    text*: int32 # the peer publishes `text: string`

  proc signature*(text: string): Future[Result[PeerEcho, string]] {.async.}

registerExtPlugin(peerbad)

proc hashOf(plugin: string): string =
  let t = ExtHost.table
  var buf: array[33, char]
  if t.schemaHash(t.host, cstring(plugin), addr buf[0]) != ExtOk:
    return ""
  $cast[cstring](addr buf[0])

proc noInvoke(
    user: pointer,
    id: uint64,
    nameIdx: uint32,
    name: cstring,
    buf: ptr uint8,
    len: csize_t,
) {.cdecl, gcsafe, raises: [].} =
  discard

proc openWith(plugin, hash: string): (int32, uint64) =
  let t = ExtHost.table
  var impl = ExtImplDesc(
    abiVersion: ExtAbiVersion,
    plugin: cstring(plugin),
    schemaHash: cstring(hash),
    caps: ExtCapNonBlocking,
    invoke: noInvoke,
  )
  var port: uint64
  let rc = t.open(t.host, uint32(DefaultBrokerContext), addr impl, addr port)
  (rc, port)

suite "EXTAPI schema":
  test "the plugin hash covers nested wire shapes (M13, golden)":
    check ExtHost.start().isOk
    let h = hashOf("shapegold")
    check h.len == 32
    check h == ShapeGoldHash
    check ExtHost.stop().isOk

  test "a K2 peer type differing in a field is refused (M13)":
    when defined(windows):
      skip()
    else:
      let mm = (when defined(gcOrc): "orc" else: "refc")
      let cmd =
        "nim c --hints:off --app:lib -d:BrokerFfiApi --threads:on --mm:" & mm &
        " --nimMainPrefix:peerlib --path:" & repoRoot & " --outdir:" & repoRoot &
        "/build/peerlib_schema_out -o:" & peerLib & " " & repoRoot &
        "/test/ext/peerlib.nim"
      check execCmd(cmd) == 0
      check ExtHost.start().isOk
      let r = ExtPlugin.load("peerbad", NewBrokerContext())
      check r.isErr
      check "schema differs" in ExtPlugin.loadError("peerbad")
      check ExtHost.stop().isOk

  test "skip-schema env vars let a mismatching open through (M14)":
    check ExtHost.start().isOk
    let wrong = "0123456789abcdef0123456789abcdef"
    delEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK")
    delEnv("SHAPEGOLD_SKIP_SCHEMA_CHECK")
    check openWith("shapegold", wrong)[0] == ExtSchemaMismatch
    putEnv("SHAPEGOLD_SKIP_SCHEMA_CHECK", "0") # "0" = not set
    check openWith("shapegold", wrong)[0] == ExtSchemaMismatch
    putEnv("SHAPEGOLD_SKIP_SCHEMA_CHECK", "1")
    let (rc1, p1) = openWith("shapegold", wrong)
    check rc1 == ExtOk
    delEnv("SHAPEGOLD_SKIP_SCHEMA_CHECK")
    putEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK", "yes")
    let (rc2, p2) = openWith("shapegold", wrong)
    check rc2 == ExtOk
    delEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK")
    let t = ExtHost.table
    discard t.close(t.host, p1)
    discard t.close(t.host, p2)
    check openWith("shapegold", hashOf("shapegold"))[0] == ExtOk # the right hash
    check ExtHost.stop().isOk
