## Security regression tests — findings M4, M5, M6, M7 (SECURITY_AUDIT_2026-07.md).
##
## M4 — `maxPayloadBytes` does NOT bound the untrusted CBOR request buffer.
##      `RequestBroker(API, maxPayloadBytes = N)` sizes internal MT slab cells;
##      the `_call` gate checks only sign and a hard-coded 64 MiB `bufSizeCap`
##      (`brokers/api_library.nim:374`). An operator who sets a small
##      `maxPayloadBytes` to cap memory still admits a far larger buffer.
##
## M5 — `reqLen` is trusted as the `copyMem` size. `_call` validates only
##      `reqLen >= 0` and `<= 64 MiB`, then the processing thread copies exactly
##      `reqLen` bytes out of the caller's pointer
##      (`brokers/api_library.nim:1391-1393`). A small buffer submitted with a
##      large `reqLen` triggers an out-of-bounds read.
##
## M6 — `_subscribe` / `_unsubscribe` dereference the subscription registry
##      without checking it was initialised (`brokers/api_library.nim:1134-1166`
##      -> `api_cbor_subs_registry.nim:217` `withLock reg.lock`). The registry is
##      nil until `_initialize`, which is only reached via `_createContext`.
##      Calling `_subscribe` first is a NULL-deref that kills the host.
##
## M7 — `_freeBuffer` frees ANY pointer with only a nil check
##      (`brokers/api_library.nim:831-837`). It will happily free the static
##      `_version()` string (documented "must NOT be freed") or a buffer that
##      was already freed.
##
## M5, M6 and M7 crash the process on the pre-fix tree, so each runs in a CHILD
## PROCESS selected by `BROKER_SEC_CHILD`; the parent asserts on exit status.
## M4 is a pure policy assertion and runs in-process.
##
## PRE-FIX EXPECTATION: M4 fails (oversize accepted); M5/M6/M7 fail (child dies
## on a signal, or ASan reports heap-buffer-overflow / bad-free / double-free).
## POST-FIX: all pass.
##
## ---------------------------------------------------------------------------
## OBSERVED PRE-FIX RESULTS — measured 2026-07-30, Linux/amd64, Nim 2.2.4,
## default MM, NO sanitizer. 5 tests: 1 OK, 4 FAILED.
##
##   M4  FAILED — `st was 0`: a 4 KiB CBOR request was ACCEPTED by a broker
##       declared `maxPayloadBytes = 256`. Confirms the knob does not bound the
##       request buffer; only the hard-coded 64 MiB gate applies.
##
##   M5  FAILED — SIGSEGV (exit 139) at
##         api_library.nim(1393) handleCourierMsg
##       i.e. exactly the audited `copyMem(addr nimReq[0], m.reqBuf, m.reqLen)`.
##       A 16-byte buffer submitted with reqLen = 4 MiB is copied wholesale.
##
##   M6  FAILED — SIGSEGV (exit 139) at
##         api_library.nim(1156) secown_subscribe
##           -> locks.nim(83) subsRegistryAdd
##       i.e. the predicted `withLock reg.lock` on a nil registry.
##
##   M7a FAILED — SIGSEGV (exit 139) at
##         api_library.nim(836) secown_freeBuffer
##           -> alloc.nim rawDealloc -> addToSharedFreeListBigChunks
##       Freeing the static `_version()` pointer corrupts the allocator.
##
##   M7b PASSED (bug NOT reproduced in this configuration) — the double free of
##       an `_allocBuffer` pointer was tolerated by the allocator without a
##       fault. It is still a real defect by inspection; reproducing it
##       reliably needs ASan (`-d:useMalloc --passC:-fsanitize=address`).
##       Treat a green M7b WITHOUT ASan as inconclusive, not as evidence.
## ---------------------------------------------------------------------------
##
## Run (ASan strongly recommended — M5 and M7 are silent without it):
##   nim c -r --path:. --outdir:build -d:BrokerFfiApi --threads:on \
##       --nimMainPrefix:secown -d:useMalloc --mm:orc \
##       --passC:-fsanitize=address --passL:-fsanitize=address \
##       test/security/test_m4_m7_ffi_input_ownership.nim

{.used.}

## NOTE: deliberately does NOT import `std/times` / `std/monotimes` — the code
## `registerBrokerLibrary` expands into this module calls chronos'
## `sleepAsync(milliseconds(...))`, and `std/times` makes `milliseconds`
## ambiguous. Timing here is plain `os.sleep` iteration counting.
import std/[os, osproc, strtabs, strutils, streams]
import results
import chronos
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

const TinyPayloadCap = 256
  ## Mirror of the literal below — the broker macro only accepts an integer
  ## literal for `maxPayloadBytes`, so the value is repeated rather than shared.
  ## Deliberately small: M4 asserts this actually bounds the request buffer.

RequestBroker(API, maxPayloadBytes = 256):
  type EchoRequest = object
    length*: int32

  proc signature*(blob: string): Future[Result[EchoRequest, string]] {.async.}

EventBroker(API):
  type TickEvent = object
    seqNo*: int32

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc echoProv(blob: string): Future[Result[EchoRequest, string]] {.async.} =
    return Result[EchoRequest, string].ok(EchoRequest(length: int32(blob.len)))

  ?EchoRequest.setProvider(ctx, echoProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "secown"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

const ChildEnvVar = "BROKER_SEC_CHILD"
const ParentBudgetMs = 20_000

## Status code the `_call` gate returns when it rejects the request framing.
const ApiStatusBadArg = -3'i32

proc noopEventCb(
    ctx: uint32, eventName: cstring, buf: pointer, len: int32, userData: pointer
) {.cdecl.} =
  discard

# ---------------------------------------------------------------------------
# Child scenarios
# ---------------------------------------------------------------------------

proc runChildM5(): int =
  ## Submit a small buffer with a wildly larger `reqLen`.
  secown_initialize()
  var err: cstring = nil
  let ctx = secown_createContext(addr err)
  if ctx == 0'u32:
    return 2

  const RealBytes = 16
  const LiedLen = 4 * 1024 * 1024 # 4 MiB: far below the 64 MiB cap.
  let buf = secown_allocBuffer(int32(RealBytes))
  if buf.isNil:
    return 2
  zeroMem(buf, RealBytes)

  var respBuf: pointer = nil
  var respLen: int32 = 0
  # PRE-FIX: copyMem reads `LiedLen` bytes from a 16-byte allocation.
  let st = secown_call(
    ctx, "echo_request".cstring, buf, int32(LiedLen), addr respBuf, addr respLen
  )
  if not respBuf.isNil:
    secown_freeBuffer(respBuf)
  echo "CHILD-M5: status=", st
  discard secown_shutdown(ctx)
  # The request must be rejected on framing grounds, not serviced via an OOB read.
  return if st == ApiStatusBadArg: 0 else: 4

proc runChildM6(): int =
  ## `_subscribe` BEFORE any `_createContext` — registry is still nil.
  # Deliberately no `secown_initialize()` / `secown_createContext()` here.
  let rc = secown_subscribe(0'u32, "tick_event".cstring, noopEventCb, nil)
  echo "CHILD-M6: subscribe returned ", rc
  let rc2 = secown_unsubscribe(0'u32, "tick_event".cstring, 0'u64)
  echo "CHILD-M6: unsubscribe returned ", rc2
  # Surviving with a defined return is the property; the value itself is free.
  return 0

proc runChildM7a(): int =
  ## Free the static version string — documented as caller-must-NOT-free.
  secown_initialize()
  let v = secown_version()
  echo "CHILD-M7a: version=", v
  # PRE-FIX: deallocShared on static storage -> heap corruption / ASan bad-free.
  secown_freeBuffer(cast[pointer](v))
  echo "CHILD-M7a: survived free of static version pointer"
  return 0

proc runChildM7b(): int =
  ## Double-free a library-allocated buffer.
  secown_initialize()
  let p = secown_allocBuffer(64'i32)
  if p.isNil:
    return 2
  secown_freeBuffer(p)
  # PRE-FIX: second free -> ASan double-free / heap corruption.
  secown_freeBuffer(p)
  echo "CHILD-M7b: survived double free"
  return 0

# ---------------------------------------------------------------------------
# Parent harness
# ---------------------------------------------------------------------------

type ChildResult = object
  timedOut: bool
  exitCode: int
  output: string

proc runChildScenario(tag: string, budgetMs: int = ParentBudgetMs): ChildResult =
  var childEnv = newStringTable()
  for k, v in envPairs():
    childEnv[k] = v
  childEnv[ChildEnvVar] = tag

  let p = startProcess(
    getAppFilename(), args = @[], env = childEnv, options = {poStdErrToStdOut}
  )
  defer:
    p.close()

  var waitedMs = 0
  while p.running() and waitedMs < budgetMs:
    sleep(50)
    waitedMs += 50

  if p.running():
    p.terminate()
    discard p.waitForExit()
    return ChildResult(timedOut: true, exitCode: -1, output: "")

  let code = p.waitForExit()
  let outp =
    try:
      p.outputStream.readAll()
    except CatchableError:
      ""
  ChildResult(timedOut: false, exitCode: code, output: outp)

when isMainModule:
  let childTag = getEnv(ChildEnvVar, "")
  if childTag.len > 0:
    let rc =
      case childTag
      of "m5": runChildM5()
      of "m6": runChildM6()
      of "m7a": runChildM7a()
      of "m7b": runChildM7b()
      else: 99
    quit(rc)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M4 — maxPayloadBytes must bound the untrusted request buffer":
  test "a request larger than maxPayloadBytes is rejected":
    secown_initialize()
    var err: cstring = nil
    let ctx = secown_createContext(addr err)
    require ctx != 0'u32

    # Well-formed CBOR, comfortably over the broker's 256-byte cap but far
    # under the hard-coded 64 MiB gate.
    type EchoArgs = object
      blob*: string

    let big = EchoArgs(blob: repeat('A', 4096))
    let encoded = cborEncode(big)
    require encoded.isOk()
    require encoded.value.len > TinyPayloadCap

    let buf = secown_allocBuffer(int32(encoded.value.len))
    require not buf.isNil
    copyMem(buf, unsafeAddr encoded.value[0], encoded.value.len)

    var respBuf: pointer = nil
    var respLen: int32 = 0
    let st = secown_call(
      ctx,
      "echo_request".cstring,
      buf,
      int32(encoded.value.len),
      addr respBuf,
      addr respLen,
    )
    if not respBuf.isNil:
      secown_freeBuffer(respBuf)

    # PRE-FIX: st == 0 (accepted) because only the 64 MiB cap applies.
    check:
      st == ApiStatusBadArg

    discard secown_shutdown(ctx)

suite "M5/M6/M7 — FFI input validation and buffer ownership":
  test "M5: a lying reqLen must be rejected, not honoured as a copy size":
    let res = runChildScenario("m5")
    if res.timedOut or res.exitCode != 0:
      echo "M5 REPRO: exit=", res.exitCode, " timedOut=", res.timedOut
      echo res.output
    check:
      not res.timedOut
      res.exitCode == 0

  test "M6: _subscribe before _createContext must not crash the host":
    let res = runChildScenario("m6")
    if res.timedOut or res.exitCode != 0:
      echo "M6 REPRO: child died (nil subscription registry deref). exit=",
        res.exitCode
      echo res.output
    check:
      not res.timedOut
      res.exitCode == 0

  test "M7a: _freeBuffer must refuse the static version pointer":
    let res = runChildScenario("m7a")
    if res.timedOut or res.exitCode != 0:
      echo "M7a REPRO: freeing _version() corrupted the heap. exit=", res.exitCode
      echo res.output
    check:
      not res.timedOut
      res.exitCode == 0

  test "M7b: _freeBuffer must refuse an already-freed buffer":
    let res = runChildScenario("m7b")
    if res.timedOut or res.exitCode != 0:
      echo "M7b REPRO: double free. exit=", res.exitCode
      echo res.output
    check:
      not res.timedOut
      res.exitCode == 0
