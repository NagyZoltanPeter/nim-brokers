## Security regression tests — findings H1 and H2 (SECURITY_AUDIT_2026-07.md).
##
## H2 — `waitSlot` (`brokers/internal/api_cbor_courier.nim:468-479`) blocks the
##      foreign caller unconditionally:
##          acquire(s.lock)
##          while s.ready == 0: wait(s.cond, s.lock)
##      There is no timeout on the sync `<lib>_call` path (unlike `_callAsync`,
##      which races a chronos timer). A provider that never resolves parks the
##      calling thread forever.
##
## H1 — `<lib>_shutdown` (`brokers/api_library.nim:1748-1800`) drains in-flight
##      calls only BEST-EFFORT for 5 s:
##          while courier.inFlight.load(moAcquire) > 0 and waitedMs < 5000: ...
##      and then UNCONDITIONALLY joins the threads and calls `freeCborCourier`,
##      which `deinitCond`/`deinitLock`/`deallocShared`s every response slot.
##      A caller still parked in `waitSlot` (H2 — it cannot time out) is left
##      waiting on a freed `Cond` while holding a freed `Lock`: use-after-free
##      on the host's thread, and it can never wake.
##
## Both scenarios either CRASH or HANG on the pre-fix tree, so neither can be
## asserted in-process — a crash takes the runner down with it. Each scenario
## therefore runs in a CHILD PROCESS (re-exec of this same binary, selected by
## the `BROKER_SEC_CHILD` env var) and the parent asserts on exit status within
## a wall-clock budget.
##
## PRE-FIX EXPECTATION: both tests FAIL — the child times out. That failure IS
## the proof the bug exists.
## POST-FIX: the child exits 0 promptly, having received a defined status code.
##
## ---------------------------------------------------------------------------
## OBSERVED PRE-FIX BEHAVIOUR — measured 2026-07-30 on Linux/amd64, Nim 2.2.4,
## default MM (no sanitizer). Recorded because the H1 mechanism differs from
## what static reading predicted:
##
##   H2: reaches "issuing sync call to a never-resolving provider", then
##       `secffi_call` NEVER RETURNS. Killed at 25 s. Confirms `waitSlot` has
##       no timeout, exactly as the audit describes.
##
##   H1: reaches "calling shutdown while a sync _call is parked in waitSlot",
##       then `secffi_shutdown` ITSELF NEVER RETURNS. Killed at 45 s.
##       The predicted use-after-free (drain expires -> `freeCborCourier` frees
##       the `Cond`/`Lock` under the parked caller) was NOT observed in this
##       configuration: the process blocks inside `_shutdown` — apparently at
##       one of the `joinThread` calls — BEFORE it can reach the free. So the
##       reachable defect here is an unbounded shutdown DEADLOCK, with the UAF
##       remaining a code-reading concern for configurations where the join
##       does complete. Either way the fix is the same (bounded wait + genuine
##       quiescence), and this test gates both: it demands `_shutdown` return
##       and the caller come back with a defined status.
## ---------------------------------------------------------------------------
##
## Run (plain):
##   nim c -r --path:. --outdir:build -d:BrokerFfiApi --threads:on \
##       --nimMainPrefix:secffi test/security/test_h1_h2_shutdown_uaf.nim
##
## Run (recommended — makes the H1 UAF explicit rather than a hang):
##   nim c -r --path:. --outdir:build -d:BrokerFfiApi --threads:on \
##       --nimMainPrefix:secffi -d:useMalloc --mm:orc \
##       --passC:-fsanitize=address --passL:-fsanitize=address \
##       test/security/test_h1_h2_shutdown_uaf.nim

{.used.}

## NOTE: deliberately does NOT import `std/times` or `std/monotimes`.
## `registerBrokerLibrary` expands generated code into THIS module's scope, and
## that code calls chronos' `sleepAsync(milliseconds(...))`; importing
## `std/times` makes `milliseconds` ambiguous and breaks the library build.
## All timing here is therefore plain `os.sleep` iteration counting.
import std/[os, osproc, strtabs, streams]
import results
import chronos
import testutils/unittests
import brokers/[request_broker, broker_context, api_library]

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

## Provider sleeps well past `<lib>_shutdown`'s 5 s best-effort drain window.
RequestBroker(API):
  type SlowRequest = object
    done*: bool

  proc signature*(): Future[Result[SlowRequest, string]] {.async.}

## Provider never completes — nothing ever calls `completeSlot` for it.
RequestBroker(API):
  type HangRequest = object
    done*: bool

  proc signature*(): Future[Result[HangRequest, string]] {.async.}

const SlowProviderMs = 9_000
  ## Comfortably beyond the hard-coded 5 s `drainTimeoutMs` in `_shutdown`.

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc slowProv(): Future[Result[SlowRequest, string]] {.async.} =
    await sleepAsync(SlowProviderMs)
    return Result[SlowRequest, string].ok(SlowRequest(done: true))

  ?SlowRequest.setProvider(ctx, slowProv)

  proc hangProv(): Future[Result[HangRequest, string]] {.async.} =
    # Never completes: await a future nothing ever finishes.
    let never = newFuture[void]("sec.hangProv.never")
    await never
    return Result[HangRequest, string].ok(HangRequest(done: true))

  ?HangRequest.setProvider(ctx, hangProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "secffi"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Child-process scenarios
# ---------------------------------------------------------------------------

const ChildEnvVar = "BROKER_SEC_CHILD"

proc note(parts: varargs[string, `$`]) =
  ## Unbuffered progress marker. The child is SIGTERM'd on hang, so anything
  ## still sitting in stdio buffers would be lost — which is exactly the
  ## information needed to tell "shutdown blocked" from "caller never woke".
  var line = ""
  for p in parts:
    line.add(p)
  echo line
  flushFile(stdout)

## Budget the CHILD gives itself; the parent's budget is larger so a child that
## overruns is still reported as a timeout rather than a race between the two.
const ChildBudgetMs = 20_000
const ParentBudgetMs = 30_000

type CallOutcome = object
  status: int32
  returned: bool

var gCallOutcome: CallOutcome
var gCallCtx: uint32

proc slowCallThread(unused: bool) {.thread.} =
  ## Issues the SYNC `_call` that parks in `waitSlot`.
  ## The generated C exports are not annotated `gcsafe`; this is a test-only
  ## cast, matching how a real foreign caller thread reaches them.
  {.cast(gcsafe).}:
    var respBuf: pointer = nil
    var respLen: int32 = 0
    let st = secffi_call(
      gCallCtx, "slow_request".cstring, nil, 0'i32, addr respBuf, addr respLen
    )
    gCallOutcome.status = st
    gCallOutcome.returned = true
    if not respBuf.isNil:
      secffi_freeBuffer(respBuf)

proc runChildH2(): int =
  ## H2: a sync `_call` whose provider never resolves must not park forever.
  var err: cstring = nil
  let ctx = secffi_createContext(addr err)
  if ctx == 0'u32:
    note("CHILD-H2: createContext failed")
    return 2

  note("CHILD-H2: ctx created; issuing sync call to a never-resolving provider")

  var respBuf: pointer = nil
  var respLen: int32 = 0
  # PRE-FIX: this call never returns — the child is killed by the parent.
  let st = secffi_call(
    ctx, "hang_request".cstring, nil, 0'i32, addr respBuf, addr respLen
  )
  if not respBuf.isNil:
    secffi_freeBuffer(respBuf)
  note("CHILD-H2: call returned status=", st)
  discard secffi_shutdown(ctx)
  # Any defined status is acceptable; returning at all is the property.
  return 0

proc runChildH1(): int =
  ## H1: shutdown must not free the courier under a still-parked caller.
  var err: cstring = nil
  let ctx = secffi_createContext(addr err)
  if ctx == 0'u32:
    note("CHILD-H1: createContext failed")
    return 2
  gCallCtx = ctx
  gCallOutcome = CallOutcome(status: 0, returned: false)
  note("CHILD-H1: ctx created")

  var callThread: Thread[bool]
  createThread(callThread, slowCallThread, true)

  # Let the call reach `waitSlot` and register in `inFlight`.
  sleep(300)
  note("CHILD-H1: calling shutdown while a sync _call is parked in waitSlot")

  # PRE-FIX: the 5 s drain expires with inFlight > 0, then the courier —
  # including the slot `Cond`/`Lock` the call thread is parked on — is freed.
  let shutStatus = secffi_shutdown(ctx)
  note("CHILD-H1: shutdown returned ", shutStatus)

  # The caller must come back with a defined status. Bound the join so a
  # permanently-parked thread is reported by the parent's timeout instead.
  var waitedMs = 0
  while not gCallOutcome.returned and waitedMs < ChildBudgetMs:
    sleep(20)
    waitedMs += 20

  if not gCallOutcome.returned:
    note("CHILD-H1: caller never returned (parked on freed courier)")
    return 3

  joinThread(callThread)
  note("CHILD-H1: caller returned status=", gCallOutcome.status)
  return 0

# ---------------------------------------------------------------------------
# Parent harness
# ---------------------------------------------------------------------------

type ChildResult = object
  timedOut: bool
  exitCode: int
  output: string

proc runChildScenario(tag: string, budgetMs: int): ChildResult =
  ## Re-executes this binary with BROKER_SEC_CHILD=<tag> and enforces a budget.
  var childEnv = newStringTable()
  for k, v in envPairs():
    childEnv[k] = v
  childEnv[ChildEnvVar] = tag

  let p = startProcess(
    getAppFilename(),
    args = @[],
    env = childEnv,
    options = {poStdErrToStdOut},
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

# ---------------------------------------------------------------------------
# Entry point: child mode short-circuits the test suite.
# ---------------------------------------------------------------------------

when isMainModule:
  let childTag = getEnv(ChildEnvVar, "")
  if childTag.len > 0:
    note("CHILD: entered child mode tag=", childTag)
    secffi_initialize()
    note("CHILD: initialize done")
    let rc =
      case childTag
      of "h1": runChildH1()
      of "h2": runChildH2()
      else:
        echo "unknown child tag: ", childTag
        99
    quit(rc)

suite "H1/H2 — sync call timeout and shutdown quiescence":
  test "H2: sync _call with a never-resolving provider must return":
    let res = runChildScenario("h2", ParentBudgetMs)
    if res.timedOut:
      echo "H2 REPRO: child never returned from secffi_call (waitSlot has no timeout)"
    check:
      not res.timedOut
      res.exitCode == 0

  test "H1: shutdown must not free the courier under a parked caller":
    let res = runChildScenario("h1", ParentBudgetMs)
    if res.timedOut:
      echo "H1 REPRO: child hung — caller parked on a freed courier"
    elif res.exitCode != 0:
      echo "H1 REPRO: child exited ", res.exitCode, " (3 = caller never woke; ",
        "signal/abort = use-after-free on the freed Cond/Lock)"
      echo res.output
    check:
      not res.timedOut
      res.exitCode == 0
