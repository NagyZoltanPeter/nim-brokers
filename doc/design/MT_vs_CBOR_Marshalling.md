# MT Marshalling vs. CBOR Marshalling — Honest Comparison

Status: analysis / reference. Not a change proposal.
Scope: how a request payload crosses a thread boundary, compared between
the multi-thread (MT) broker's preallocated-cell codec and CBOR
serialization. Companion to `doc/CBOR_Refactoring.md`.

Evidence base: `mt_codec.nim`, `mt_queue.nim`, `mt_request_broker.nim`,
`mt_config.nim`, `MT_BROKER_CONFIG.md`, `MT_BROKER_REFACTOR_RETROSPECTIVE.md`,
and the CBOR `_call` path trace in `CBOR_Refactoring.md` §2.2.

---

## 1. The two mechanisms in one line

- **MT marshalling** — a recursive byte codec (`mt_codec.nim`) serializes a
  typed message *inline* into a **fixed-size, preallocated** shared cell;
  the consumer thread deserializes into fresh GC values.
- **CBOR marshalling** — a self-describing codec serializes into a
  **variable-length, per-call-allocated** shared buffer; the consumer
  decodes into fresh GC values.

Both produce a self-contained byte image, copy it across the thread
boundary, and allocate fresh on the consumer thread — so **both are
equally thread/GC-safe**: no GC block is shared, no cross-thread
`=destroy`/`=copy` occurs. Safety is a wash. The real differences are
**speed** and **memory flexibility**.

---

## 2. Performance

| Aspect | MT marshalling | CBOR (map) | CBOR positional (FASTAPI) |
|--------|----------------|------------|---------------------------|
| POD / scalar payload | single `copyMem` — memcpy speed | type tag + varint per field, 2-pass sizing | tag + varint per field, 1-pass |
| `string` / `seq` payload | 4-byte len + bulk `copyMem` | len + bulk copy + per-field tags/keys | len + bulk copy, no keys |
| Per-call allocator traffic | **none on the hot path** — cell taken from a preallocated slab | `allocShared0` + `deallocShared` every call | same |
| Field-name strings on the wire | none (positional, schema-locked) | yes (map keys) | none |

**MT marshalling is genuinely faster** for equivalent data. A scalar
message is one `copyMem` with zero allocator traffic; CBOR always writes
type tags + varints and pays an `allocShared`/`deallocShared` per call.
The gap is widest for small/scalar payloads and **narrows for large
`seq`/`string` payloads**, where both paths are dominated by the same bulk
byte copy.

**Caveat that matters for the FFI path.** An FFI request *arrives already
CBOR-encoded* (the foreign caller encoded it). Routing it through MT cells
would be a **second, redundant serialization** (CBOR → typed → MT-bytes →
typed). So "MT is faster per-transform" does **not** mean "MT is faster for
FFI" — for FFI, fewer *total* transforms wins. That is why the courier
design in `CBOR_Refactoring.md` §6 carries the CBOR blob directly.

---

## 3. Memory flexibility — the decisive difference

| Aspect | MT marshalling | CBOR |
|--------|----------------|------|
| Payload size ceiling | **hard fixed ceiling** per broker type | none — buffer sized to actual payload |
| Cell size | `cfg.maxPayloadBytes` — **one size for every cell of that type** | n/a — each call allocates exactly what it needs |
| Auto-sizing when undeclared | `classifyFieldsMax`: scalar 64 B / string 4 KB / `seq[string]` 16 KB / `seq[byte]` 64 KB / **unclassifiable 8 KB + compile warning** | n/a |
| Oversized payload at runtime | **hard fail** — `err("request payload too large")`; no spill, no fallback | allocates a bigger buffer |
| Fixed footprint | `queueDepth×24 + slabCap×align8(hdr+maxPayload) + respSlots×align8(hdr+maxResp)` — at defaults the 256×64 KB response pool alone ≈ **16 MB per bucket** | none — memory tracks live traffic |
| Per-type inflation | one big field inflates **every** cell × `slabCapacity` | none |

### The prediction tax

The MT design forces the developer to one of three choices: (a) declare
`maxPayloadBytes` accurately, (b) trust `classifyFieldsMax`'s coarse class,
or (c) accept a runtime `err` when a real payload overshoots. For a broker
whose payload is genuinely unpredictable — a `seq[Object]` of unknown
length, a user-supplied blob — there is **no good answer**:

- **Under-provision** → requests fail at runtime under exactly the
  conditions (large input) you least want them to fail.
- **Over-provision** → every one of `slabCapacity` cells carries the
  worst-case size, multiplied across every `(type, context, thread)`
  bucket. The 16 MB-per-bucket default response pool shows how fast this
  compounds.
- The `classifyFieldsMax` fallback emits a **compile-time warning** for
  "unclassifiable" types — the codebase itself acknowledges it cannot
  size these well.

CBOR has none of this. A surprise 5 MB payload allocates 5 MB for that one
call and frees it. Memory scales with *actual* traffic, not a worst-case
projection. **This is the user-facing flexibility cost of the preallocated
MPSC design.**

---

## 4. Failure modes — a real trade, not just a downside

MT's fixed ceiling buys **predictable, bounded memory and fail-fast
behavior**: ring-full and slab-exhausted both return `err` immediately —
never block, never grow. For a soft-real-time system that prefers a clean,
bounded failure over a latency spike or an unbounded allocation, that is a
*feature*.

CBOR's flexibility is also its risk: a per-call buffer has **no natural
backpressure on payload size** — an unbounded payload allocates freely
until OOM. If a size cap is wanted on the CBOR path, it must be added
explicitly.

---

## 5. Type support

Both are byte serializers, but the *boundary* each serves dictates what
limits its type support — and the limits are fundamentally different in
kind.

### 5.1 MT codec — supported set (`mt_codec.nim`, verified)

`mtMarshalValue` / `mtUnmarshalValue` walk arbitrary payload types at
compile time via `supportsCopyMem` + `fieldPairs`:

| Type | Handling |
|------|----------|
| POD — scalars, enums, `distinct`-of-POD, all-POD objects, fixed POD arrays | single `copyMem(sizeof(T))` |
| `string` | 4-byte LE length + bytes |
| `seq[U]` (nested ok) | length + bulk `copyMem` (POD `U`) or per-element recursion |
| `array[N, U]` with non-POD `U` | per-element recursion |
| `object` / `tuple` (arbitrarily nested) | `fieldPairs` recursion |
| `distinct` over a structural base (`distinct seq[byte]`, `distinct string`) | unwrap to base, recurse |
| `ptr` / `pointer` / `cstring` | **bytewise-copied** — deliberate escape hatch for shared structures (e.g. `ThreadSignalPtr`); caller owns the pointee's lifetime |
| custom per-type | `mixin` allows user-supplied marshal overloads for an element/field type |
| `ref T` | **compile-time `{.error.}`** — rejected |
| closures / anything else | falls to the `else` branch → compile-time `{.error.}` |

> Correction to an earlier draft: only `ref T` is explicitly rejected.
> `ptr`/`pointer`/`cstring` are *not* rejected — they are copied bytewise
> on purpose. `Option[T]` is just a Nim `object`, so it rides the
> `fieldPairs` branch with no special support.

### 5.2 CBOR (FFI) — supported set

The CBOR *wire format* can encode any value. The **effective** limit is
not the codec — it is the **wrapper codegen across C++/Python/Rust/Go**.
That is why the CBOR FFI surface ships with an explicit *parity matrix*:

- Covered: primitives, enums, `distinct`/alias, `seq[primitive|string|Object]`,
  `array[N, primitive]`, `object` (including object-as-parameter), nested
  objects, `Option[T]`, `seq[byte]` byte-strings, tuples (via
  `bindCborTupleMap`).
- Not supported: `ref` types, raw `ptr`/`pointer`/`cstring` — meaningless
  across a language boundary.

### 5.3 The fundamental difference

| Dimension | MT codec | CBOR (FFI) |
|-----------|----------|------------|
| What bounds type support | "is it a byte-copyable Nim value tree (no `ref`)" — one uniform compile-time rule | "does every one of the 5 language wrappers have a mapping" — a per-language codegen matrix |
| Foreign-language mapping needed | **no** — both ends are the same compiled Nim binary | **yes** — per language |
| Raw pointers / `cstring` | allowed (bytewise, caller-owned) | not meaningful |
| Failure mode for an unsupported type | compile-time `{.error.}` | codegen gap / `// TODO` stub |
| Portability of a supported type | in-process only | same type works across 5 languages **and** across versions |
| Schema evolution | positional, schema-locked (fine in-process — same binary both sides) | self-describing map → additive evolution, optional fields, introspection |

### 5.4 Verdict on type support

Neither dominates:

- **Nim-to-nim → MT codec has the broader set.** No foreign mapping is
  required, so *any* non-`ref` value tree works — arbitrarily nested
  objects/seqs/arrays/tuples, structural distincts, even raw pointers for
  shared structures. The rule is uniform and enforced at compile time.
- **FFI → CBOR's set is bounded by the wrapper codegen**, not the wire.
  It is narrower in principle (the parity matrix exists precisely because
  some shapes need per-language work) but every supported type is
  **portable across 5 languages and evolvable across versions** — which
  MT marshalling can never be.

This is the same theme as performance and memory: MT is the better
*in-process* choice, CBOR the better *boundary-crossing* choice.

---

## 6. Verdict

The two are **not competitors** — they are tuned for different boundaries:

| Boundary | Use | Why |
|----------|-----|-----|
| Nim-to-nim, same process, predictable payloads | **MT marshalling** | faster (copyMem, no hot-path allocator), bounded, fail-fast |
| FFI / cross-language / cross-version / unpredictable or large payloads | **CBOR** | no size ceiling, per-call sizing, self-describing, evolvable |

This validates the courier design in `CBOR_Refactoring.md` §6: by carrying
the **variable-length CBOR buffer by pointer** across the thread hop, the
FFI path gets cross-thread transport **without** inheriting MT
marshalling's fixed-cell ceiling. FFI payloads stay flexible; the MT cell
ceiling only ever constrains genuine nim-to-nim brokers.

---

## 7. Option — a spill path for MT marshalling

If the MT cell ceiling becomes painful for **nim-to-nim** brokers too, MT
marshalling could gain a **spill path**: when a payload exceeds the cell,
`allocShared` an overflow buffer, store `(ptr, len)` in the cell, and have
the consumer free it after unmarshal — the exact ownership-transfer
pattern the FFI courier uses.

- **Benefit:** removes the hard ceiling; the prediction tax disappears.
- **Cost:** one heap allocation on the slow (oversized) path only — the
  fast path is unchanged.
- **Risk:** the `MT_BROKER_REFACTOR_RETROSPECTIVE` shows the team
  deliberately avoided pointer-crossing (bugs §2.2 refc `=copy` race,
  §2.6 ORC slot-payload UAF). A spill path reintroduces a cross-thread
  shared-heap pointer and **must** replicate the courier's strict
  single-owner / transfer-on-receive discipline. Needs careful review and
  a dedicated ASAN/valgrind stress test before adoption.

Recorded here as a viable middle ground, not a recommendation.
