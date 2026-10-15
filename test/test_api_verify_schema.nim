## `<lib>_verifySchema` — the allocation-free wrapper/library schema check.
##
## Drives the generated C export directly (the library is inlined, no .so):
## match, mismatch, NULL handling, both opt-out env vars, and that the result
## never gates `<lib>_createContext` (detection, not enforcement).

import std/[os, strutils]
import results
import testutils/unittests
import brokers/[request_broker, broker_context, api_library]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    ok*: bool

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type Ping = object
    value*: int32

  proc signature*(x: int32): Future[Result[Ping, string]] {.async.}

proc setupProviders(ctx: BrokerContext) =
  discard InitializeRequest.setProvider(
    ctx,
    proc(): Future[Result[InitializeRequest, string]] {.closure, async.} =
      return ok(InitializeRequest(initialized: true)),
  )
  discard ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      return ok(ShutdownRequest(ok: true)),
  )
  discard Ping.setProvider(
    ctx,
    proc(x: int32): Future[Result[Ping, string]] {.closure, async.} =
      return ok(Ping(value: x)),
  )

registerBrokerLibrary:
  name:
    "vstest"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

type Hash32 = array[32, char]
type Hash33 = array[33, char]

proc libHash(): Hash33 =
  # NULL wrapperHash: reports -1 but still fills libHashOut.
  check vstest_verifySchema(nil, addr result) == -1'i32

proc asHash32(h: Hash33): Hash32 =
  for i in 0 ..< 32:
    result[i] = h[i]

proc clearEnv() =
  delEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK")
  delEnv("VSTEST_SKIP_SCHEMA_CHECK")

suite "FFI _verifySchema":
  setup:
    clearEnv()
  teardown:
    clearEnv()

  test "library fingerprint is 32 lowercase hex + NUL":
    let h = libHash()
    check h[32] == '\0'
    for i in 0 ..< 32:
      check h[i] in {'0' .. '9', 'a' .. 'f'}

  test "matching fingerprint returns 0 and echoes the library hash":
    var wrapper = libHash().asHash32()
    var outBuf: Hash33
    check vstest_verifySchema(addr wrapper, addr outBuf) == 0'i32
    check outBuf == libHash()

  test "NULL libHashOut is accepted":
    var wrapper = libHash().asHash32()
    check vstest_verifySchema(addr wrapper, nil) == 0'i32

  test "mismatch returns -14 and still reports the library hash":
    var wrapper = libHash().asHash32()
    wrapper[0] = (if wrapper[0] == '0': '1' else: '0')
    var outBuf: Hash33
    check vstest_verifySchema(addr wrapper, addr outBuf) == -14'i32
    check outBuf == libHash()

  test "last byte is compared too":
    var wrapper = libHash().asHash32()
    wrapper[31] = (if wrapper[31] == '0': '1' else: '0')
    check vstest_verifySchema(addr wrapper, nil) == -14'i32

  test "generic opt-out env turns a mismatch into 1":
    var wrapper: Hash32
    for i in 0 ..< 32:
      wrapper[i] = 'z'
    putEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK", "1")
    check vstest_verifySchema(addr wrapper, nil) == 1'i32

  test "per-library opt-out env turns a mismatch into 1":
    var wrapper: Hash32
    for i in 0 ..< 32:
      wrapper[i] = 'z'
    putEnv("VSTEST_SKIP_SCHEMA_CHECK", "yes")
    check vstest_verifySchema(addr wrapper, nil) == 1'i32

  test "opt-out env set to 0 or empty does not skip":
    var wrapper: Hash32
    for i in 0 ..< 32:
      wrapper[i] = 'z'
    putEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK", "0")
    check vstest_verifySchema(addr wrapper, nil) == -14'i32
    putEnv("VSTEST_SKIP_SCHEMA_CHECK", "")
    check vstest_verifySchema(addr wrapper, nil) == -14'i32

  test "opt-out env does not change a match":
    putEnv("BROKERS_FFI_SKIP_SCHEMA_CHECK", "1")
    var wrapper = libHash().asHash32()
    check vstest_verifySchema(addr wrapper, nil) == 0'i32

  test "a mismatch never gates createContext":
    var wrapper: Hash32
    check vstest_verifySchema(addr wrapper, nil) == -14'i32
    var err: cstring = nil
    let ctx = vstest_createContext(addr err)
    check ctx != 0'u32
    check vstest_shutdown(ctx) == 0'i32

  test "discovery payloads carry the same fingerprint":
    let h = libHash()
    var hs = newString(32)
    for i in 0 ..< 32:
      hs[i] = h[i]
    for which in 0 .. 1:
      var buf: pointer = nil
      var len: int32 = 0
      let rc =
        if which == 0:
          vstest_getSchema(addr buf, addr len)
        else:
          vstest_listApis(addr buf, addr len)
      check rc == 0'i32
      var js = newString(len.int)
      if len > 0:
        copyMem(addr js[0], buf, len.int)
      vstest_freeBuffer(buf)
      check ("\"schemaHash\":\"" & hs & "\"") in js
