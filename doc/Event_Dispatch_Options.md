# `EventBroker(API)` Dispatch — Design Options

Status: **EXPLORATORY** — laying out the design space. No option is
chosen yet. Companion to `doc/CBOR_Refactoring_Round2.md` Part D.

## 1. The cost we want to spare

Today every FFI event traverses **six** transformations / crossings:

```
provider thread:                              delivery thread:
1. typed EventPayload (Nim object)
2. → MT EventBroker marshals typed fields
   into MT slab cell (allocShared,
   field-by-field copy)
                ───── crossing #1 (typed slab) ─────►
                                              3. unmarshal slab → typed Nim
                                                 EventPayload (mirror copy)
                                              4. → cborEncodeShared(payload)
                                                 → shared-heap buffer
                                              5. foreign callback(buf, len)
                                                 (still on delivery thread)
                                  foreign side:
                                              6. wrapper decodes CBOR → typed
                                                 host-language value
```

The two costs we know we don't want:

- **Steps 2 + 3** (typed marshal / unmarshal across the MT slab).
  We're about to throw the typed shape away anyway — every byte of
  field-by-field copying is pure overhead.
- **Two copies of the payload alive at once** on the delivery thread
  (the typed Nim mirror + the shared-heap CBOR buffer).

The two costs we likely **do** still want to pay:

- **Step 4** (one CBOR encode per event) — required to talk to the
  foreign callback at all. Question is *where* it runs, not *whether*.
- **Step 5 / 6** — the foreign callback invocation + foreign decode are
  the contract with the wrapper; out of scope to compress.

## 2. The constraints any option must honor

1. **Foreign callbacks fire on a stable, predictable thread.** Today
   that thread is the delivery thread. Foreign code (Python, C++ users
   acquiring locks) cares which thread it's called from; rotating the
   thread per event would break reasonable expectations.
2. **The MT EventBroker stays intact for genuine pure-Nim cross-thread
   `.emit` callers.** Round 1's request courier was additive in
   exactly this way; the equivalent on the event side is the
   non-negotiable starting point.
3. **`.emit` from a provider stays fire-and-forget** (`Future[void]`,
   `asyncSpawn` semantics). Backpressure surfaces as an `err(...)` to
   the provider, not as a block.
4. **Subscriber set is snapshot-and-cloned at fan-out time** — same
   discipline the single-thread broker already uses for `dropListener`
   / `dropAllListeners` correctness.
5. **No GC object crosses a thread.** Shared-heap buffer pointers
   only; typed Nim values stay thread-local.
6. **Refcount / ownership of any cross-thread buffer is exactly one
   alloc, exactly one free.** Mandatory ASAN-clean property.

## 3. The options

Six candidates, sketched + tradeoffs. None are recommendations — these
are the rails for the design conversation.

### Option A — Encode on provider, courier to delivery (mirror the request path)

```
provider thread:                          delivery thread:
  .emit(Payload{...})
  cborEncodeShared(payload)
  enqueue (evtId, buf, len, refcount = N) into per-lib MPSC ring
  fireBrokerSignal()
                 ────►
                                          courier-events poller dequeues
                                          snapshot subscribers for evtId
                                          for each sub: foreignCb(buf, len)
                                          refcount-- ; final free
```

The exact shape `doc/CBOR_Refactoring_Round2.md` §3 sketched.

- **Honors all 6 constraints** straight out of the box.
- Reuses `mt_broker_common.nim` (`registerBrokerPoller`,
  `brokerDispatchLoop`, `fireBrokerSignal`, MPSC ring from
  cc481c8). No new core primitives.
- Pure-Nim cross-thread listeners on the *same* `EventBroker(API)` type
  still go through MT EventBroker as today; the FFI path forks
  upstream of the MT slab. Two listener tables (one MT-typed, one
  FFI-CBOR) sharing the same event type identity.
- Cost saved per event: one slab marshal + one slab unmarshal +
  one typed-Nim-object copy on the delivery thread.
- Cost added: refcounted-buffer fan-out discipline; an event-side
  shutdown drain mirroring the request-side one.

**Risk**: subscriber-set / shutdown races during in-flight fan-out
(snapshot-and-clone fixes the former; teardown ordering the latter).

### Option B — Encode on delivery, but bypass the typed MT slab

```
provider thread:                          delivery thread:
  .emit(Payload{...})
  enqueue typed payload by VALUE-MOVE into per-lib SPSC ring
  (no marshal, no GC ownership — payload is plain `object` with
  shallow-copyable fields; if not, fallback to Option A)
                 ────►
                                          poller dequeues typed payload
                                          cborEncodeShared(payload)
                                          fan out to subscribers
                                          drop buffer when last cb returns
```

Skips the MT slab; transfers the typed Nim payload across by raw
`copyMem` of the object's bytes (assuming the payload is
copy-trivial — no `seq`/`string`/`ref` fields).

- **Honors 1, 2, 3, 4, 6.** Constraint 5 (no GC object crosses)
  needs a stronger compile-time check than today: payloads with
  `seq[T]`, `string`, `ref T`, `Option[T]` cannot be moved by
  `copyMem`. The codegen would have to either:
  - **B-trivial**: reject non-trivially-copyable payload types →
    falls back to Option A for those events. Two paths in one codegen.
  - **B-encode-still**: encode CBOR on the provider anyway, but
    enqueue the buffer alongside or instead of the typed payload.
    That collapses to Option A.
- Lower memory pressure for scalar-only events. No win for any
  event carrying `seq[byte]` / `string` (which is most of them).
- Two codegen paths per event type. More moving parts; uneven cost
  profile makes profiling harder.

### Option C — Status quo with lazy encode (no MT slab change)

Keep the existing flow but short-circuit the typed marshal/unmarshal
on the slab when the only listeners registered for the event are
foreign (no pure-Nim listeners present).

- Honors all constraints.
- Smallest diff; can be done without touching MT broker internals.
- Wins disappear the moment a single pure-Nim listener registers
  (back to full path). Real-world Status libraries mix both kinds, so
  the win is conditional.
- **Doesn't address the user's specific objection** — typed
  marshalling still happens whenever a Nim listener exists, which is
  the normal case in tests.

### Option D — Drop the delivery thread; same-thread inline dispatch

```
provider thread:
  .emit(Payload{...})
  cborEncodeShared(payload)
  snapshot subscribers
  for each sub: foreignCb(buf, len)     ← runs ON the provider thread
  free buf
```

No cross-thread crossing. The "delivery thread" model goes away
entirely. Foreign callbacks run on the processing/provider thread.

- Maximal cost reduction. No queue, no signal, no refcount.
- **Violates constraint 1** unless we promote "callbacks fire on the
  provider thread" as the new contract. That breaks:
  - any wrapper that today acquires a per-callback mutex assuming
    serial delivery-thread invocation;
  - reentrancy via `<lib>_call` from inside a callback (the callback
    is running on the very thread that services `_call`, so the call
    will block the provider until the courier services it — deadlock
    if `.emit` is still on the stack; the courier poller doesn't run
    until control returns).
  - Python GIL acquisition from a thread that wasn't blessed —
    `ensureForeignThreadGc()` works, but the provider thread already
    has Nim GC state attached and re-entering it through a Python
    bridge is uglier.
- Tempting for in-process tests; **likely a non-starter for the
  product surface**.

### Option E — Mixed dispatch: pure-Nim listeners on emit-thread; foreign listeners on delivery thread

```
provider thread:
  .emit(Payload{...})
  for each nim listener: asyncSpawn handler(payload)   ← same thread,
                                                        no crossing
  if any foreign listener registered:
     cborEncodeShared(payload)
     enqueue (evtId, buf, len, refcount = K_foreign) into ring
     fireBrokerSignal()
                 ────►
                                          delivery thread fans out to
                                          foreign listeners only
```

Two listener tables explicitly. Recognizes that nim listeners and
foreign listeners want *different* dispatch contracts.

- **Honors all 6 constraints.**
- Best cost profile per listener kind:
  - Nim listeners: identical to single-thread EventBroker (no MT
    slab, no CBOR).
  - Foreign listeners: one CBOR encode (regardless of count), one
    cross-thread crossing, no typed marshal.
- Adds an explicit "listener kind" registration distinction in the
  codegen. The user-facing macro (`Type.listen(...)`) is Nim-side
  only and already separate from the FFI `on_<Event>` surface — so
  the split is naturally where the codegen already lives.
- Diverges from MT EventBroker for FFI events specifically. Genuine
  pure-Nim *cross-thread* `.emit` (Nim user calling `.emit` from
  thread X with a Nim listener on thread Y) still needs MT broker —
  which means three paths total (same-thread Nim, cross-thread Nim,
  FFI). The codegen has to know which to emit.

### Option F — MT broker carries opaque CBOR bytes (typed marshal replaced, not added)

Modify MT EventBroker so its slab cells can carry **either** a typed
payload **or** an opaque `seq[byte]` / `ptr UncheckedArray[byte]`
payload, with the consumer side dispatching on the variant.

```
provider thread:                          delivery thread:
  .emit(Payload{...})
  cborEncodeShared(payload)
  marshal MT cell with variant = "cbor bytes" and buf ptr
                ────►
                                          MT broker unmarshals cell
                                          dispatches by variant:
                                            - typed listener: decode bytes
                                              → typed payload (rare path)
                                            - foreign listener:
                                              foreignCb(buf, len) directly
```

- Reuses MT broker's existing channel, ThreadSignalPtr, and bucket
  registry. No new courier infrastructure.
- **Invasive**: introduces a variant to MT broker's wire format. MT
  broker today is "carry a typed T across threads". This makes it
  "carry T or a (CBOR-bytes, typeId) pair across threads". Affects
  every MT EventBroker template generated, not just FFI ones.
- Pure-Nim cross-thread listeners on the same event must pay a
  CBOR-decode round-trip (the worst case for nim-to-nim dispatch).
- Conceptually elegant; in practice probably the hardest to ship
  cleanly because the MT broker macros and the parity matrix all
  exercise the typed path.

## 4. Decision dimensions

Use these to argue between A / E / F (the three serious candidates):

| Dimension | A (courier mirror) | E (two-tier listeners) | F (MT broker carries bytes) |
|---|---|---|---|
| Cost when 0 nim listeners + N foreign | 1 encode + 1 cross-thread + 1 fan-out | 1 encode + 1 cross-thread + 1 fan-out | 1 encode + 1 MT-slab marshal + 1 cross-thread + 1 fan-out |
| Cost when N nim listeners + 0 foreign | 1 MT marshal + 1 MT unmarshal | 0 (single-thread `asyncSpawn`) | 1 MT marshal + 1 MT unmarshal |
| Cost when both kinds present | both costs | both costs (each kind takes its path) | MT marshal + encode bytes; decode on nim side too |
| New core infrastructure | event MPSC ring (mirror of req courier) | event MPSC ring + dual-listener registry | MT broker variant payload (invasive) |
| Impact on MT broker module | none | none | substantial |
| Codegen complexity | low (one path) | medium (kind discriminator) | medium-high (MT macro changes) |
| Risk profile | shutdown-race / refcount (familiar from req courier) | three dispatch paths to keep in sync | MT broker correctness regression risk |
| Buffer lifetime | single ref to a fan-out buffer | foreign-only buffer; nim path none | MT-managed buffer with variant disposal |

## 5. Open questions

These should be answered before the option is fixed:

1. **Is "pure-Nim listener on an `EventBroker(API)` type" a real use
   case** in the Status libraries? If brokers tagged `(API)` are *only*
   ever consumed via FFI, Option A collapses elegantly: drop the MT
   broker for `(API)` events entirely and use the courier ring as the
   sole dispatch.
2. **Same-thread vs cross-thread `.emit` for `(API)` brokers** — does
   any provider live on the same thread as the foreign callback (i.e.
   the delivery thread)? If not, "delivery thread" can be renamed
   "FFI dispatch thread" and Option E becomes the natural shape.
3. **Foreign callback execution time bounds.** If callbacks are
   guaranteed short (≤ 1ms), Option D becomes thinkable for a
   subset of brokers (a `RequestBroker(API, sync)`-analog annotation
   for events).
4. **Multi-context dispatch** — when a library has K contexts
   simultaneously alive (multiple `<lib>_createContext()` calls),
   should each context have its own dispatch thread? Today: yes,
   one delivery thread per context. Round 2 design should preserve
   that.
5. **Shutdown semantics during in-flight fan-out** — the request
   courier's drain-and-fail discipline gives every blocked `_call` a
   clean error envelope. Events are fire-and-forget; do we drop them
   silently on shutdown, or surface a `[dropped]` marker through some
   side channel (e.g. a discovery / introspection probe)?

## 6. What's NOT being proposed here

- No change to MT EventBroker's pure-Nim semantics (single-thread or
  cross-thread Nim listeners get exactly today's behavior under every
  option above).
- No change to `RequestBroker(API)` (Round 1 §6 already handled it).
- No `FASTAPI`-style scalar-only optimization (still deferred).
- No change to the foreign callback's wrapper-side decode path
  (whatever wrapper generates today: cbor2 / jsoncons / ciborium /
  fxamacker — unchanged).
