/*
 * stress_event_drop_overload.cpp — exercise the REAL event-courier drop path.
 *
 * This drives the genuine threaded FFI route end to end, NOT an emulation:
 *
 *   - createContext() spins up the library's processing thread + delivery
 *     thread.
 *   - We register ONE foreign PingEvent callback that sleeps SLOW_CB_MS per
 *     invocation. That callback runs on the DELIVERY thread, so the delivery
 *     thread is effectively stalled — it can drain the courier ring only once
 *     every SLOW_CB_MS.
 *   - triggerEmitRequest(K_EMITS) makes the library emit K_EMITS PingEvents
 *     from the PROCESSING thread in a tight loop. Each emit encodes once and
 *     enqueues into the bounded courier ring (256 seed → 1024 ceiling).
 *
 * With the delivery thread stalled, the ring fills to its 1024 ceiling and
 * every further emit is dropped by `tryEnqueue` — which fires the throttled
 * `warn` in the generated emit handler (api_library.nim). Those WRN lines are
 * printed by the library itself on this process's stdout/stderr:
 *
 *   WRN ... FFI event courier ring full — delivery thread stalled or blocked;
 *           dropping outbound events  event=PingEvent ringCap=1024
 *           totalDropped=... droppedSinceLastLog=...
 *
 * Expect the geometric throttle to collapse ~K_EMITS-1024 drops into only a
 * handful of lines (drop #1, #10, #100, #1000 …).
 *
 * This is a DEMO, not a pass/fail test: its purpose is to make the production
 * drop-logging observable through the real thread boundary.
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>

#include "benchlib.hpp"

using namespace benchlib;

namespace {

constexpr int SLOW_CB_MS = 40;     // per-event delivery-thread occupancy
constexpr int K_EMITS    = 5000;   // far exceeds the 1024 ring ceiling
constexpr int DRAIN_MS   = 300;    // brief settle before teardown

}  // namespace

int main() {
    Benchlib lib;
    const auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    // A single slow subscriber — this stalls the delivery thread so the
    // courier ring backs up to its ceiling and the producer starts dropping.
    std::atomic<int64_t> delivered{0};
    const auto cb = lib.onPingEvent([&delivered](Benchlib&, int64_t /*seqNo*/) {
        std::this_thread::sleep_for(std::chrono::milliseconds(SLOW_CB_MS));
        delivered.fetch_add(1, std::memory_order_relaxed);
    });

    std::printf("# emitting %d PingEvents into a 256->1024 ring with a %d ms/event "
                "stalled consumer\n", K_EMITS, SLOW_CB_MS);
    std::printf("# watch for WRN \"FFI event courier ring full\" lines below:\n");
    std::fflush(stdout);

    // Flood from the processing thread. The provider returns `emitted` =
    // count regardless of drops; the drops are reported via the WRN lines.
    const auto emitRes = lib.triggerEmitRequest(K_EMITS);
    if (!emitRes.isOk()) {
        std::fprintf(stderr, "triggerEmitRequest failed\n");
        return 1;
    }

    // Let a few slow callbacks run so the output interleaves naturally, then
    // tear down (shutdown drains and frees whatever is still queued).
    std::this_thread::sleep_for(std::chrono::milliseconds(DRAIN_MS));
    lib.offPingEvent(cb);

    std::printf("# done: emitted=%d deliveredSoFar=%lld — the difference was dropped "
                "(see WRN lines above)\n",
                emitRes->emitted, (long long)delivered.load());
    return 0;
}
