# Plan — Option A: correct per-context teardown of the shared event-subs counter

## Background: two teardown scopes, two opposite defects

`g<Lib>Cbor<Event>SubsCount` (`brokers/api_library.nim:649-656`) is a **single
process-global atomic per event type**, shared by every context and sub-instance
in the `.so`. It is purely an emit-side gate ("does *anyone* subscribe to this
event type?", read at `api_library.nim:785`). The broker-level and
registry-level removals are already correctly scoped per-ctx; the bugs are both
in how the *global counter* and the *registry sweep* are handled at teardown.

Intended ownership model (confirmed with user):

| Event | Required scope |
|-------|----------------|
| Sub-instance `close()` (RAII: C++ dtor / Rust Drop / Go Close / Py close) | Drop listeners/providers/subs for **exactly that instance's full ctx**, nothing more |
| Main class `_shutdown(libCtx)` | Drain **all** subs for this lib — including any still-alive sub-instances sharing this `classCtx` — then tear down the lib ctx |
| Ownership | A sub-instance is hard-tied to the one lib ctx it was created under: shares `classCtx` (low16), distinct `instanceCtx` (high16) |

### Gap 1 — sub-instance close *over-reaches* (the reported bug)

`releaseCtxProc(subCtx)` (`api_library.nim:412-431`) calls
`<Event>.dropAllListeners(subCtx)` → fires `dropAllHook` (`api_library.nim:857`)
whose registry remove is correctly scoped to `subCtx`, **but** then does
`subsCountIdent.store(0)` (`:861`) on the *global* counter. The
`_unsubscribe(handle==0)` branch (`:965`) has the same `store(0)`. Tearing down
one instance zeroes the gate for every other live instance/context → their next
emit short-circuits → silent. (Persistence Scenario C: Memory `be.close()`
silences File. The barrier hides it by ordering File's work first.)

### Gap 2 — main class teardown *under*-reaches

`_shutdown(libCtx)` (`api_library.nim:1340`) joins both threads (threadvar broker
buckets die with the processing thread, so broker listeners are implicitly gone),
then calls `subsRegistryFreeForCtx(reg, libCtx)` (`:1379`) which matches
**`cur.ctx == libCtx` exactly** (`api_cbor_subs_registry.nim:339`). It therefore:

- **leaks** every sub-instance bucket (instanceCtx≠0) whose RAII `close()` never
  ran (shared-heap memory), and
- **never decrements the counter** for any of those leftover subs (nor for the
  lib's own direct subs, if any).

The counter leak is in the *safe* direction (over-count → wasted encodes in
other libs, never silences), but it is still a correctness/robustness hole that
grows across create/teardown cycles. Nothing today implements "drain all alive
sub-instances at lib teardown"; there is no `classCtx`-scoped registry sweep and
no tracking of live sub-instance ctxs (`ctxsIdent` holds only top-level lib
entries). The persistence example only stays correct because it calls
`be.close()` *before* `p.shutdown()`.

The global-aggregate counter semantic itself is fine: a cross-ctx false-positive
only costs a wasted CBOR encode dropped at the courier ctx lookup
(`api_library.nim:831-835`). The fix is to keep the counter a *correct running
sum* — decrement by the exact number of subs each teardown removes, never reset.

---

## Changes

### 1. `brokers/internal/api_cbor_subs_registry.nim`

#### 1a. Count-returning single-key remove (for Gap 1)

`subsRegistryRemoveAllForKey` (line 276) returns `0` (existed) / `-2` (not
found). The bucket's `subsCount` is known before `disposeBucket`. Add:

```nim
proc subsRegistryRemoveAllForKeyN*(
    reg: ptr SubsRegistry, ctx: uint32, name: cstring
): int32 {.gcsafe, raises: [].} =
  ## Returns the number of subscriptions removed (>= 0), or -2 if the key
  ## was not found. Teardown paths must decrement the shared per-event
  ## subs-count by the exact number removed (not reset to 0).
  {.cast(gcsafe).}:
    withLock reg.lock:
      let nameLen = cstrLen(name)
      let bucket = findBucket(reg, ctx, name, nameLen)
      if bucket.isNil:
        return -2'i32
      let removed = int32(bucket.subsCount)
      unlinkBucket(reg, bucket)
      disposeBucket(bucket)
      dec reg.entryCount
      return removed
```

(Optionally collapse the old `subsRegistryRemoveAllForKey` to call this and map
`>=0 -> 0`, if `nph` keeps it clean. Otherwise leave the old one untouched.)

#### 1b. classCtx-scoped sweep with per-event callback (for Gap 2)

`subsRegistryFreeForCtx` matches the exact ctx and is counter-blind. Add a
classCtx-scoped variant that reports each disposed bucket's `(eventName, count)`
to a caller-supplied callback so the generated `_shutdown` can decrement the
right per-event counter. The callback must be `{.gcsafe, raises: [].}` and is
invoked **inside** `reg.lock` (it only does an atomic `fetchSub`, no re-entry):

```nim
type SubsFreedCb* = proc(name: cstring, count: int32) {.gcsafe, raises: [].}

proc subsRegistryFreeForClass*(
    reg: ptr SubsRegistry, classCtx: uint16, onFreed: SubsFreedCb
) {.gcsafe, raises: [].} =
  ## Drops every bucket whose ctx's low16 == classCtx (the lib ctx itself,
  ## instanceCtx 0, plus all its sub-instances). For each disposed bucket
  ## invokes `onFreed(eventName, subsCount)` so the caller can decrement the
  ## shared per-event subs-count. Called from `_shutdown` after both threads
  ## are joined, so no concurrent delivery can race this teardown.
  {.cast(gcsafe).}:
    withLock reg.lock:
      for i in 0 ..< reg.bucketsLen:
        var prev: ptr BucketHead = nil
        var cur = reg.buckets[i]
        while not cur.isNil:
          let nxt = cur.next
          if (cur.ctx and 0x0000FFFF'u32) == uint32(classCtx):
            if not onFreed.isNil and cur.subsCount > 0:
              onFreed(cur.eventName, int32(cur.subsCount))
            if prev.isNil:
              reg.buckets[i] = nxt
            else:
              prev.next = nxt
            disposeBucket(cur)
            dec reg.entryCount
          else:
            prev = cur
          cur = nxt
```

(Keep `subsRegistryFreeForCtx` for any other callers; `_shutdown` switches to the
new one. `BucketHead` already carries `ctx`, `eventName`, `subsCount` —
confirmed at `api_cbor_subs_registry.nim:46-52`.)

### 2. `brokers/api_library.nim` — `dropAllHook` (lines 857-863) — Gap 1

```nim
proc dropAllHook(brokerCtx: BrokerContext) {.gcsafe, raises: [].} =
  let removed = subsRegistryRemoveAllForKeyN(
    `subsRegIdent`, uint32(brokerCtx), `eventNameLit`.cstring
  )
  if removed > 0:
    discard `subsCountIdent`.fetchSub(removed, moRelease)
```

### 3. `brokers/api_library.nim` — `_unsubscribe` handle==0 branch (956-966) — Gap 1

```nim
let removed = subsRegistryRemoveAllForKeyN(`subsRegIdent`, ctx, eventNameC)
if removed >= 0:
  if removed > 0:
    let counter = `getEventSubsCountIdent`(name)
    if not counter.isNil:
      discard counter[].fetchSub(removed, moRelease)
  return 0'i32
return removed   # -2 not found (preserves prior nonzero-on-failure contract)
```

### 4. `brokers/api_library.nim` — `_shutdown` (line 1379) — Gap 2

Replace the exact-ctx free with a classCtx sweep that decrements each per-event
counter via the existing name→atomic lookup `getEventSubsCountIdent`:

```nim
# Free this lib's subscription state for the whole class (the lib ctx +
# every still-alive sub-instance sharing its classCtx). Both threads are
# joined, so no concurrent listener can be mid-snapshot. Decrement each
# per-event global subs-count by the exact number of subs removed so the
# shared gate stays a correct running sum for sibling lib contexts.
proc onFreed(name: cstring, count: int32) {.gcsafe, raises: [].} =
  let counter = `getEventSubsCountIdent`($name)
  if not counter.isNil and count > 0:
    discard counter[].fetchSub(count, moRelease)
subsRegistryFreeForClass(`subsRegIdent`, classCtx(BrokerContext(ctx)), onFreed)
```

`getEventSubsCountIdent` (`api_library.nim:681-695`) is already generated, takes a
`string`, returns `ptr Atomic[int]` (nil for unknown names). `$name` allocates a
Nim string on the FFI thread's heap — fine here (post-join, sync context). If we
want zero-alloc, add a `cstring`-keyed variant of the lookup; defer unless it
shows up in teardown profiling.

## Why this satisfies the model

| Scope | After fix |
|-------|-----------|
| Sub-instance `close()` | `dropAllHook(subCtx)` removes only `subCtx`'s buckets and `fetchSub`s only their count → **exactly that instance**, no sibling impact (Gap 1 closed) |
| `_unsubscribe(handle==0)` | Same `fetchSub(removed)` semantics for the direct foreign-caller path |
| Main `_shutdown(libCtx)` | classCtx sweep drains the lib ctx **and every alive sub-instance** under it, decrementing every counter it removes → no bucket leak, no counter leak, no effect on other lib contexts (Gap 2 closed) |

## Concurrency / memory-model notes

- `fetchSub(n, moRelease)` pairs with the emit-side `load(moAcquire)`
  (`api_library.nim:785`) — same ordering subscribe's `fetchAdd` already uses.
- Each remove decrements exactly what its matching add incremented, so the
  counter can never *silence* a live subscriber the way `store(0)` did; worst
  case is a transient over-count (one wasted encode), never an under-count.
- All teardown frees run **after** `joinThread` of both threads (Gap 2 sweep at
  `:1376`+), so no emit/snapshot races the registry mutation — same invariant the
  current `subsRegistryFreeForCtx` relies on.
- The `onFreed` callback runs under `reg.lock` but only does an atomic
  `fetchSub` on a *different* word (the per-event counter), no lock re-entry, no
  allocation inside the lock except `$name` — move the `$name` out by passing the
  owned `cstring` and using a cstring-keyed lookup if lock-hold time matters.
- No refc/ORC divergence: `Atomic[int]` + shared-heap registry, identical under
  both managers; the registry was purpose-built for refc cross-thread safety.

## Verification

1. **Impact analysis first** (CLAUDE.md): `gitnexus_impact` on
   `subsRegistryRemoveAllForKey`, `subsRegistryFreeForCtx`, and the
   `_shutdown` / `_unsubscribe` / `releaseInstance` flows; report blast radius
   before editing.
2. `nimble nphall` (format).
3. `nimble testApi` — codec / subscribe / lifecycle parity matrix (ORC+refc ×
   debug+release).
4. Persistence regression — build the example, run the Rust example with
   `bar.wait()` **removed** from `scenario_concurrent_load`
   (`examples/persistence/rust_example/src/main.rs`): expect File 30/30 and
   Memory 30/30 (Gap 1).
5. Gap 2 regression — add a variant that calls `p.shutdown()` **without** first
   calling `be.close()` while a sibling lib context is live, and assert the
   sibling still delivers. (New test or example scenario — confirm with user
   whether to add to the matrix.)
6. Remove the barrier workaround from all three examples (Rust/Go/Python) once
   green; rely on the no-barrier run + Gap-2 scenario as the regression gate.
7. `gitnexus_detect_changes()` before commit.

## Open questions

- **Gap-2 regression placement:** add a no-`close()` teardown scenario to the
  persistence examples, or a dedicated `test/test_api_*` case? (Recommend a
  focused test case so CI gates it without depending on example timing.)
- **`$name` alloc in `onFreed`:** acceptable (post-join, one-shot), or add a
  cstring-keyed counter lookup to keep the sweep alloc-free? Recommend accept for
  now; revisit only if teardown shows up in profiling.
