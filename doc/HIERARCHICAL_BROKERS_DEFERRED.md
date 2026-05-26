# Hierarchical Brokers — Deferred Items (for review)

Status as of P7-tests. Branch `hierarchical_brokers`. Everything below is
**intentionally deferred** — the implemented-and-verified surface (P1 context
split, P2 RequestBroker sugar + option B across all 5 wrappers, P3
BrokerInterface, P4 BrokerImplement, P5 in-process factory/DI, P6-core FFI
binding) is committed and green. Items are grouped and prioritized so you can
decide what to pull in next.

Legend — **Priority**: 🔴 needed for a complete feature · 🟡 important hardening ·
🟢 nice-to-have / ergonomics.

---

## A. FFI hierarchy & proxy (the rest of P6)

| # | Item | Why deferred | Where | Prio |
|---|------|--------------|-------|------|
| A1 | **Sub-interface ownership hierarchy** — a library with >1 `BrokerInterface(API)`: the *main* interface owns `createContext` + whole-context teardown (threads), sub-interfaces are created by the main impl at runtime and are *instance-local* (their wrappers only close their own instance). Needs a per-class ownership table + cascade `close()` from main → owned subs. | Largest remaining design; the single-interface library is proven first. | `api_library.nim`, `broker_implement.nim` | 🔴 |
| A2 | **Nim-side `IFaceProxy`** — `ref object of IFace` whose request methods forward via CBOR over the foreign `vt.call`, and whose `listen` installs a foreign trampoline via `vt.subscribe`. `create()` returns the real impl (same runtime) or this proxy (separate `.so`), transparently. Carries `isMain` to pick the teardown branch. | Needs the `_call`/`_subscribe` ABI surface (only meaningful once A1/runtime wiring exists). | new `internal/broker_proxy.nim` | 🔴 |
| A3 | **Cross-FFI teardown sequence** — ordered: mark closing → `vt.unsubscribe` (drop FFI subs first) → drop Nim trampoline closures (break cross-boundary refc cycle) → role-dependent: main `vt.shutdown` (threads), sub instance-local close → null `vt`/handle. | Depends on A2. | `broker_proxy.nim` | 🔴 |
| A4 | **InitializeRequest-driven factory lifecycle** — currently the main impl is created at `setupProviders(ctx)` (via `bindToContext`, with `init`, no foreign config). The design option where the impl is *created when `InitializeRequest` fires* (so the foreign config feeds the factory) is not wired. Decide whether we want that exact lifecycle or keep create-at-setup + configure-via-InitializeRequest-method (current). | Current model already yields a working FFI library; this is a lifecycle refinement. | `api_library.nim`, `broker_interface.nim` (factory) | 🟡 |

---

## B. Lifecycle / memory robustness

| # | Item | Why deferred | Where | Prio |
|---|------|--------------|-------|------|
| B1 | **`=destroy` on the impl** — close() is the explicit, working teardown; a destructor calling `close()` when `brokerCtx != Default` is the safety net under `--mm:refc`. Deferred because `=destroy` on a `ref object` pointee is refc/orc-delicate and needs dedicated testing on both managers. | Correctness-sensitive; needs focused refc+orc validation. | `broker_implement.nim` | 🟡 |
| B2 | **Event-listener cleanup in `close()`** — `close()` clears request providers (breaking the instance↔closure cycle) but NOT event listeners: the impl macro doesn't know the interface's event types. Fix: the interface registers a per-interface teardown hook the impl can call. | Providers are the primary cycle; events registered via `self.listen` are usually owned by the caller. | `broker_interface.nim` + `broker_implement.nim` | 🟡 |
| B3 | **gcsafe-hardened `create()` / `new()`** — `new()` touches non-atomic globals (`<Impl>BrokerClassCtx` lazy init) so it isn't gcsafe; `create()` therefore can't be called from a gcsafe async context (only the sync composition root). For the FFI processing-thread factory path we need a gcsafe ctx allocator (e.g. atomic classCtx + once-init). `bindToContext` is already gcsafe (no global access). | In-process DI works from the sync root; only the FFI factory path needs it. | `broker_implement.nim` | 🟡 |
| B4 | **Factory storage cross-thread** — `<IFace>BrokerFactory` is a plain process-global (no lock/threadvar). Fine for single-threaded composition; cross-thread FFI use needs a lock or shared cell. | Tied to B3 / the FFI factory path. | `broker_interface.nim` | 🟡 |
| B5 | **`classCtx` lazy-init race in `new()`** — `if x == 0: x = newClassCtx()` is not atomic; two threads constructing the first instance of a class could double-allocate a classCtx. | In-process single-thread is unaffected; surfaces only under concurrent first-construction. | `broker_implement.nim` | 🟢 |

---

## C. Sugar / type surface

| # | Item | Why deferred | Where | Prio |
|---|------|--------------|-------|------|
| C1 | **Custom error type `E`** — RequestBroker is hardwired to `Result[T, string]` everywhere (the whole broker, not just FFI). Confirmed decision: FFI pins errors to `string`; honoring a custom in-process `E` is also unimplemented and would be a broad change. | Confirmed string-only for now. | `request_broker.nim`, `mt_request_broker.nim`, codecs | 🟢 |
| C2 | **MultiRequestBroker sugar** — proc-sugar + option B only applied to single/mt/API RequestBroker; MultiRequestBroker still legacy-only. | Explicitly deferred at P2. | `multi_request_broker.nim` | 🟢 |
| C3 | **Non-primitive POD payloads over FFI** — a POD payload that is a bare named object / `seq[...]` (no `type` block, no inline fields) registers as a non-emittable tag → wrapper TODO stub. Use the object-form sugar (`type X = object ...`) for object payloads. Primitives (incl. `string`) work. | Matches the legacy limitation; object form is the supported path. | `api_request_broker_cbor.nim` | 🟢 |
| C4 | **`cstring` POD payloads** — intentionally excluded from FFI registration (unsafe to marshal across the CBOR boundary). `string` is allowed. | Intentional safety choice. | `api_request_broker_cbor.nim` | 🟢 (won't-fix) |

---

## D. Testing gaps

| # | Item | Why deferred | Where | Prio |
|---|------|--------------|-------|------|
| D1 | **Formal `examples/ffiapi/hierlib`** across all 5 wrappers (C/C++/Rust/Go/Py) + nimble tasks + CI, mirroring the ffiapi example. The interface→FFI path is currently proven only by a throwaway Python smoke (`/tmp/hb_hier`), not in-repo. | The in-process Nim tests + the smoke prove correctness; the formal multi-wrapper example is volume work. | `examples/ffiapi/hierlib/**`, `brokers.nimble`, `AGENTS.md` | 🔴 |
| D2 | **refc-cycle-actually-freed test** — current `close()` test verifies providers are cleared, not that the instance is GC-freed after close under refc. A `getOccupiedMem`/finalizer-based assertion would close the loop. | Behavioral cycle-break is demonstrated; memory-freed assertion is extra rigor. | `test/test_broker_oop.nim` | 🟡 |
| D3 | **Multi-thread interface dispatch test** — no test exercises an interface instance whose requests/events cross threads (the MT lane under real cross-thread dispatch). `test_broker_interface_api` runs same-thread only. | Same-thread fast path covers the integration; cross-thread is the MT brokers' own tested behavior. | new `test/` | 🟡 |
| D4 | **Compile-fail tests** — no negative tests for: apiName collision (`greeting` vs a `GreetingArg` broker), object-form payload/name mismatch (the rejected "third coupling"), mixed-case sigs in one block. | Error paths exist in code; formal `reject`-style tests not added. | new `test/` | 🟢 |

---

## E. Docs / cosmetics

| # | Item | Why deferred | Where | Prio |
|---|------|--------------|-------|------|
| E1 | **Reconcile the plan doc** — `doc/HIERARCHICAL_BROKERS_PLAN.md` still says the FFI proxy is in P5 and uses the unparsable `BrokerInterface(API) IFace:` form. Update to the as-built reality (proxy in P6-continuation; `(API, IFace)` comma form; `bindToContext`). | Plan was written before implementation surprises. | `doc/HIERARCHICAL_BROKERS_PLAN.md` | 🟢 |
| E2 | **AGENTS.md** — document the new macros (`BrokerInterface`, `BrokerImplement`, sugar) once the surface stabilizes. | Surface still gaining the hierarchy/proxy. | `AGENTS.md` | 🟢 |

---

## Recommended next pull-in order

1. **D1** (formal hierlib example + wrappers) — turns the proven core into a CI-guarded, reviewable artifact.
2. **A1 → A2 → A3** (sub-interface hierarchy → proxy → teardown) — the substantive remaining feature.
3. **B3/B4** (gcsafe factory) — unblocks `create()` on the FFI thread, needed cleanly by A1/A2.
4. **B1/B2** (`=destroy` + event cleanup) — refc safety net.
5. The 🟢 items as polish.
