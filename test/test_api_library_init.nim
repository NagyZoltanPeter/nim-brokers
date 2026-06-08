## Integration tests for the CBOR FFI runtime emitted by
## `registerBrokerLibrary` under `-d:BrokerFfiApi`.
##
## The test binary inlines the broker library (no .so loading) and drives
## the generated C exports as ordinary Nim procs. This exercises:
## - `<lib>_initialize` idempotency
## - `<lib>_createContext` end-to-end (spawn processing thread, run
##   setupProviders, return a usable ctx)
## - `<lib>_allocBuffer` / `<lib>_freeBuffer` ownership conventions
## - `<lib>_call` for zero-arg and arg-based requests, including round-
##   tripping CBOR-encoded request payloads and decoded response envelopes
## - `<lib>_call` framework-error path for unknown apiName
## - `<lib>_shutdown` cleanup

import std/[options, strutils, os, osproc]
import results
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(
    configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

# Regression coverage for the API broker kwargs surface — the
# `(API, ...)` macro must accept the same capacity / preset knobs as
# `(mt, ...)` because the MT lane is what carries the broker
# internally. Two flavours below: a named built-in preset, and
# individual kwargs overriding defaults.
RequestBroker(API, preset = tinyFootprint):
  type GetStatus = object
    online*: bool
    counter*: int32

  proc signature*(): Future[Result[GetStatus, string]] {.async.}

RequestBroker(API, queueDepth = 64, maxPayloadBytes = 256, maxResponseBytes = 512):
  type AddNumbers = object
    sum*: int64

  proc signature*(a: int32, b: int32): Future[Result[AddNumbers, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(
      configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc statusProv(): Future[Result[GetStatus, string]] {.async.} =
    return Result[GetStatus, string].ok(GetStatus(online: true, counter: 99))

  ?GetStatus.setProvider(ctx, statusProv)

  proc addProv(a: int32, b: int32): Future[Result[AddNumbers, string]] {.async.} =
    return Result[AddNumbers, string].ok(AddNumbers(sum: int64(a) + int64(b)))

  ?AddNumbers.setProvider(ctx, addProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "cbtest"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Test helpers — wrap the generated C exports for ergonomic use.
# ---------------------------------------------------------------------------

proc copyToCBuffer(bytes: openArray[byte]): pointer =
  ## Allocates a `<lib>_allocBuffer`-equivalent buffer and copies bytes in.
  ## We call the generated `cbtest_allocBuffer` directly so the buffer
  ## ownership matches what `<lib>_call` expects (Nim-owned, freed inside
  ## `<lib>_call`).
  result = cbtest_allocBuffer(int32(bytes.len))
  if bytes.len > 0:
    copyMem(result, unsafeAddr bytes[0], bytes.len)

proc takeRespBuffer(buf: pointer, len: int32): seq[byte] =
  ## Copies the response buffer into a Nim seq and frees the C-side
  ## allocation, matching the documented caller obligation.
  if buf.isNil or len <= 0:
    return @[]
  result = newSeq[byte](len.int)
  copyMem(addr result[0], buf, len.int)
  cbtest_freeBuffer(buf)

proc callApi(
    ctx: uint32, apiName: string, reqPayload: openArray[byte] = []
): tuple[status: int32, resp: seq[byte]] =
  let inBuf =
    if reqPayload.len > 0:
      copyToCBuffer(reqPayload)
    else:
      nil
  var respBuf: pointer = nil
  var respLen: int32 = 0
  let status = cbtest_call(
    ctx, apiName.cstring, inBuf, int32(reqPayload.len), addr respBuf, addr respLen
  )
  let resp = takeRespBuffer(respBuf, respLen)
  (status, resp)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "API library init (CBOR mode)":
  test "createContext returns a usable ctx and shutdown cleans it up":
    var err: cstring = nil
    let ctx = cbtest_createContext(addr err)
    check ctx != 0'u32
    check err.isNil
    check cbtest_shutdown(ctx) == 0'i32

  test "zero-arg request round-trip (GetStatus)":
    var err: cstring = nil
    let ctx = cbtest_createContext(addr err)
    check ctx != 0'u32

    let (status, resp) = callApi(ctx, "get_status", @[])
    check status == 0'i32
    check resp.len > 0

    let dec = cborDecodeResultEnvelope(resp, GetStatus)
    check dec.isOk()
    check dec.value.online == true
    check dec.value.counter == 99'i32

    discard cbtest_shutdown(ctx)

  test "arg-based request round-trip (AddNumbers)":
    var err: cstring = nil
    let ctx = cbtest_createContext(addr err)
    check ctx != 0'u32

    # Encode the args object that mirrors the proc signature(a, b).
    type AddNumbersCborArgs = object
      a*: int32
      b*: int32

    let args = AddNumbersCborArgs(a: 41'i32, b: 1'i32)
    let argBuf = cborEncode(args)
    check argBuf.isOk()

    let (status, resp) = callApi(ctx, "add_numbers", argBuf.value)
    check status == 0'i32
    check resp.len > 0

    let dec = cborDecodeResultEnvelope(resp, AddNumbers)
    check dec.isOk()
    check dec.value.sum == 42'i64

    discard cbtest_shutdown(ctx)

  test "unknown apiName returns framework error and a UTF-8 message":
    var err: cstring = nil
    let ctx = cbtest_createContext(addr err)
    check ctx != 0'u32

    let (status, resp) = callApi(ctx, "no_such_api", @[])
    check status == -4'i32
    let msg = cast[string](resp)
    check msg.contains("no_such_api")

    discard cbtest_shutdown(ctx)

  test "two contexts coexist and stay independent":
    var err1: cstring = nil
    var err2: cstring = nil
    let ctxA = cbtest_createContext(addr err1)
    let ctxB = cbtest_createContext(addr err2)
    check ctxA != 0'u32
    check ctxB != 0'u32
    check ctxA != ctxB

    let (sA, rA) = callApi(ctxA, "get_status", @[])
    check sA == 0'i32
    check cborDecodeResultEnvelope(rA, GetStatus).isOk()

    let (sB, rB) = callApi(ctxB, "get_status", @[])
    check sB == 0'i32
    check cborDecodeResultEnvelope(rB, GetStatus).isOk()

    check cbtest_shutdown(ctxA) == 0'i32
    check cbtest_shutdown(ctxB) == 0'i32

  test "repeated createContext/shutdown does not leak file descriptors":
    # Regression for the chronos per-thread dispatcher leak: each ctx spawns a
    # processing + delivery thread, each runs a chronos loop that opens one
    # selector fd (kqueue on macOS, epoll on Linux). chronos never closes it;
    # the broker thread procs now reclaim it via closeThreadDispatcherSelector.
    # Without that fix this loop leaks ~2 fds per cycle (~40 over 20 cycles).
    #
    # Counting strategy per platform:
    #   Linux:   walk /proc/self/fd (the walkDir dir-handle cancels out).
    #   macOS:   lsof (kqueue fds are not reliably in /dev/fd).
    #   Windows: GetProcessHandleCount — counts open kernel HANDLEs, which
    #            catches the IOCP-HANDLE leak the same way fds catch the
    #            kqueue/epoll one.
    when defined(windows):
      proc getCurrentProcess(): pointer {.
        stdcall, dynlib: "kernel32", importc: "GetCurrentProcess"
      .}

      proc getProcessHandleCount(
        hProc: pointer, pdwCount: ptr uint32
      ): int32 {.stdcall, dynlib: "kernel32", importc: "GetProcessHandleCount".}

      proc openFdCount(): int =
        var n: uint32 = 0
        if getProcessHandleCount(getCurrentProcess(), addr n) == 0:
          return -1
        result = n.int

    elif defined(linux):
      proc openFdCount(): int =
        result = 0
        for _ in walkDir("/proc/self/fd"):
          inc result

    else:
      proc openFdCount(): int =
        let pid = getCurrentProcessId()
        let (outp, rc) = execCmdEx("lsof -p " & $pid & " 2>/dev/null | wc -l")
        result =
          if rc == 0:
            parseInt(outp.strip())
          else:
            -1

    # Warm up: the first cycle lazily initialises one-time process state
    # (subs registry, ctx lock, foreign-thread GC) that is intentionally not
    # reclaimed. Measure the steady state after it.
    block:
      var e: cstring = nil
      let c = cbtest_createContext(addr e)
      check c != 0'u32
      check cbtest_shutdown(c) == 0'i32

    let before = openFdCount()
    const cycles = 20
    for _ in 0 ..< cycles:
      var e: cstring = nil
      let c = cbtest_createContext(addr e)
      check c != 0'u32
      check cbtest_shutdown(c) == 0'i32
    let after = openFdCount()
    let delta = after - before

    # Diagnostic — surfaced in CI logs so a future failure tells us the
    # actual delta, not just an opaque [FAILED]. Cheap, leave it in.
    echo "[fd-leak] before=",
      before, " after=", after, " delta=", delta, " cycles=", cycles

    # The pre-fix chronos dispatcher leak is exactly `2 * cycles` (one
    # dispatcher handle per processing/delivery thread). Allow a generous
    # slack for steady-state noise — anything well below `cycles` still
    # proves we're not leaking per-cycle.
    when defined(windows) and (NimMajor, NimMinor, NimPatch) == (2, 2, 4):
      # Known Nim 2.2.4 Windows-only runtime leak unrelated to this fix:
      # `joinThread` does not close the OS thread HANDLE, so we leak
      # ~2 HANDLEs per (spawn delivery + spawn processing) cycle. CI
      # diagnostics confirmed `CloseHandle(getIoHandler(disp)) == 1`
      # (success) for every dispatcher, so the chronos IOCP close this
      # test guards is working. The residual leak is fixed in Nim 2.2.10
      # — every other tested matrix (macOS, Linux, Windows + Nim 2.2.10
      # and later) reports delta close to 0.
      echo "[fd-leak] skipping assertion on Nim 2.2.4 + Windows ",
        "(known joinThread/CloseHandle leak, fixed in 2.2.10; ",
        "chronos IOCP close itself verified rc=1)"
    else:
      check delta <= cycles div 2
