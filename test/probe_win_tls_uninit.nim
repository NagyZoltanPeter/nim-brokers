## Minimal probe for the Windows refc TLS-uninit hazard (LIMITATION.md §2.1).
##
## Hypothesis (see doc/LIMITATION.md §2.1): when chronos' `ThreadSignalPtr.wait()`
## on Windows takes the `RegisterWaitForSingleObject` slow path, the OS dispatches
## the completion callback onto a thread owned by the legacy NT thread pool
## (`ntdll!TppWorkerThread`). That thread was never initialized by Nim
## (`system/threads.nim` / `lib/system/threadlocalstorage.nim`), so refc's
## per-thread TLS — GC frame stack, local heap pointer, exception state — is
## uninitialized. Any allocation from that callback reaches the shared-heap
## allocator path (`system/alloc.nim`) with garbage TLS and corrupts the heap.
##
## This probe isolates the hypothesis from chronos: it calls
## `RegisterWaitForSingleObject` directly from a plain Nim program and has the
## callback allocate Nim memory in a tight loop. No brokers, no chronos.
##
## Expected outcome:
##   * Windows + --mm:refc + --threads:on  → AV / heap corruption / non-zero exit
##   * Windows + --mm:orc  + --threads:on  → exits 0, prints "PROBE OK"
##   * Non-Windows hosts                    → exits 77 (CI "skip" convention)
##
## Build (Windows, refc — expected to crash):
##   nim c --threads:on --mm:refc -d:release --outdir:build \
##       test/probe_win_tls_uninit.nim
##
## Build (Windows, orc — expected to pass):
##   nim c --threads:on --mm:orc  -d:release --outdir:build \
##       test/probe_win_tls_uninit.nim
##
## Caveats:
##   * TLS-uninit crashes are instruction-level racy. The probe runs many
##     iterations to amplify failure rate; under refc on Windows we expect a
##     deterministic crash, but if you see a flake the right next step is to
##     rebuild the refc job with clang-cl + `-fsanitize=address` so silent
##     TLS reads turn into hard ASAN reports.
##   * This probe demonstrates ONE mechanism (alloc-from-foreign-thread). It
##     does not assert chronos hits this exact path in production — it shows
##     that the path, when reached, breaks under refc.

when not defined(windows):
  echo "SKIP probe_win_tls_uninit: Windows-only"
  quit(77)

else:
  import std/[atomics, os]

  # ---------------------------------------------------------------------------
  # Win32 imports — bound by hand so the probe has no external dependencies.
  # ---------------------------------------------------------------------------

  type
    HANDLE = pointer
    BOOL = int32
    DWORD = uint32
    ULONG = uint32
    WaitOrTimerCallback = proc (lpParameter: pointer, timerOrWaitFired: BOOL)
        {.stdcall, gcsafe, raises: [].}

  const
    WT_EXECUTEONLYONCE: ULONG = 0x00000008
    INFINITE: DWORD = 0xFFFF_FFFF'u32
    WAIT_OBJECT_0: DWORD = 0
    EVENT_AUTORESET = false
    EVENT_INITIAL_UNSIGNALED = false

  proc createEventA(lpEventAttributes: pointer, bManualReset, bInitialState: BOOL,
                    lpName: cstring): HANDLE {.stdcall, dynlib: "kernel32",
                                               importc: "CreateEventA".}
  proc setEvent(hEvent: HANDLE): BOOL {.stdcall, dynlib: "kernel32",
                                        importc: "SetEvent".}
  proc closeHandle(hObject: HANDLE): BOOL {.stdcall, dynlib: "kernel32",
                                            importc: "CloseHandle".}
  proc waitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD): DWORD
      {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}
  proc registerWaitForSingleObject(phNewWaitObject: ptr HANDLE, hObject: HANDLE,
                                   callback: WaitOrTimerCallback,
                                   context: pointer, milliseconds: ULONG,
                                   flags: ULONG): BOOL
      {.stdcall, dynlib: "kernel32", importc: "RegisterWaitForSingleObject".}
  proc unregisterWaitEx(waitHandle: HANDLE,
                        completionEvent: HANDLE): BOOL
      {.stdcall, dynlib: "kernel32", importc: "UnregisterWaitEx".}

  # ---------------------------------------------------------------------------
  # Callback — runs on the NT thread-pool wait thread. Under refc, the TLS
  # slots this code paths through were never initialized for this OS-owned
  # thread; the allocations below are the demonstrator.
  # ---------------------------------------------------------------------------

  var gCallbackDone: Atomic[bool]
  var gCallbackIterations: Atomic[int]
  gCallbackDone.store(false)
  gCallbackIterations.store(0)

  # `doneEvent` is signaled by the callback so the main thread can join cleanly.
  var gDoneEvent: HANDLE

  proc waitCallback(lpParameter: pointer, timerOrWaitFired: BOOL)
      {.stdcall, gcsafe, raises: [].} =
    # The body of this proc executes on a TppWorkerThread. We deliberately
    # allocate Nim heap objects to reach `rawNewObj` / `system/alloc.nim`,
    # which under refc consults per-thread TLS for the shared-heap allocator's
    # chunk-cache and freelist bookkeeping.
    {.cast(gcsafe).}:
      try:
        for i in 0 ..< 256:
          # newSeq[byte] takes the shared-heap allocation path.
          var buf = newSeq[byte](1024)
          # Force a write so the compiler cannot elide the allocation.
          buf[0] = byte(i and 0xFF)
          buf[buf.high] = byte(i and 0xFF)
          discard gCallbackIterations.fetchAdd(1)
      except CatchableError:
        # Even reaching the exception machinery under refc on an
        # uninitialized thread is itself part of the failure surface.
        discard
    gCallbackDone.store(true)
    discard setEvent(gDoneEvent)

  # ---------------------------------------------------------------------------
  # Driver — register the wait, signal the trigger event, wait for the
  # callback to complete (or for the process to die trying).
  # ---------------------------------------------------------------------------

  proc runOneRound(round: int) =
    gCallbackDone.store(false)
    gCallbackIterations.store(0)

    let triggerEvent = createEventA(nil,
        BOOL(EVENT_AUTORESET), BOOL(EVENT_INITIAL_UNSIGNALED), nil)
    doAssert triggerEvent != nil, "CreateEventA(trigger) failed"
    gDoneEvent = createEventA(nil,
        BOOL(EVENT_AUTORESET), BOOL(EVENT_INITIAL_UNSIGNALED), nil)
    doAssert gDoneEvent != nil, "CreateEventA(done) failed"

    var waitHandle: HANDLE = nil
    let ok = registerWaitForSingleObject(addr waitHandle, triggerEvent,
        waitCallback, nil, INFINITE, WT_EXECUTEONLYONCE)
    doAssert ok != 0, "RegisterWaitForSingleObject failed"

    # Fire the event — this causes the NT thread pool to schedule
    # `waitCallback` on a TppWorkerThread.
    doAssert setEvent(triggerEvent) != 0, "SetEvent(trigger) failed"

    # Wait for callback completion. 10 s ceiling: under refc the process
    # is far more likely to crash than to hang, but we cap anyway.
    let waitRc = waitForSingleObject(gDoneEvent, 10_000'u32)
    doAssert waitRc == WAIT_OBJECT_0,
      "Callback did not complete in time (rc=" & $waitRc & ")"

    discard unregisterWaitEx(waitHandle, nil)
    discard closeHandle(triggerEvent)
    discard closeHandle(gDoneEvent)
    gDoneEvent = nil

    echo "round=", round,
      " iters=", gCallbackIterations.load(),
      " done=", gCallbackDone.load()

  proc main() =
    # Four rounds × 256 allocations per callback. Empirically: under refc on
    # Windows one round is normally enough; we run four to keep the probe
    # robust against scheduling luck.
    for r in 0 ..< 4:
      runOneRound(r)
    echo "PROBE OK rounds=4 iters_per_round=256"

  main()
