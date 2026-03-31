## Multi-Thread Broker Common
## --------------------------
## Shared runtime helpers used by both mt_request_broker and mt_event_broker.
## These are not generated — they are used directly by generated code.

{.push raises: [].}

import chronos
import std/atomics
export chronos, atomics

# ---------------------------------------------------------------------------
# Thread identity
# ---------------------------------------------------------------------------

var mtThreadIdMarker* {.threadvar.}: bool
  ## Each thread gets its own copy; `addr mtThreadIdMarker` is a unique thread id.

template currentMtThreadId*(): pointer =
  addr mtThreadIdMarker

# ---------------------------------------------------------------------------
# Thread generation — monotonically increasing, unique per thread incarnation.
# Under refc, threadvar addresses can be reused when threads exit and new
# ones are created. The generation counter disambiguates reused addresses.
# ---------------------------------------------------------------------------

var gMtThreadGenCounter: Atomic[uint64]

var mtThreadGen* {.threadvar.}: uint64
var mtThreadGenInitialized {.threadvar.}: bool

proc currentMtThreadGen*(): uint64 =
  if not mtThreadGenInitialized:
    mtThreadGen = gMtThreadGenCounter.fetchAdd(1, moRelaxed)
    mtThreadGenInitialized = true
  mtThreadGen

# ---------------------------------------------------------------------------
# Blocking await for {.thread.} procs
# ---------------------------------------------------------------------------

template blockingAwait*[T](f: Future[T]): T =
  ## Blocking await for use inside non-async `{.thread.}` procs.
  ## Use this instead of `await` (which conflicts with chronos's async-only
  ## `await`) or call `waitFor` directly.
  waitFor(f)
