## Multi-Thread Broker Common
## --------------------------
## Shared runtime helpers used by both mt_request_broker and mt_event_broker.
## These are not generated — they are used directly by generated code.

{.push raises: [].}

import chronos
export chronos

# ---------------------------------------------------------------------------
# Thread identity
# ---------------------------------------------------------------------------

var mtThreadIdMarker* {.threadvar.}: bool
  ## Each thread gets its own copy; `addr mtThreadIdMarker` is a unique thread id.

template currentMtThreadId*(): pointer =
  addr mtThreadIdMarker

# ---------------------------------------------------------------------------
# Blocking await for {.thread.} procs
# ---------------------------------------------------------------------------

template blockingAwait*[T](f: Future[T]): T =
  ## Blocking await for use inside non-async `{.thread.}` procs.
  ## Use this instead of `await` (which conflicts with chronos's async-only
  ## `await`) or call `waitFor` directly.
  waitFor(f)
