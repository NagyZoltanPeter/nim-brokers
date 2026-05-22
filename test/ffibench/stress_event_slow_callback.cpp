/*
 * stress_event_slow_callback.cpp — Part D-5 provider-non-blocking proof.
 *
 * Registers a single foreign callback that sleeps SLOW_CB_MS per
 * invocation, fires K_EMITS events, then concurrently hammers
 * addRequest from N_CALL_WORKERS threads for RUN_MS. Asserts that the
 * request providers keep flowing at roughly their baseline throughput
 * — the slow callback occupies the delivery thread, NOT the processing
 * thread, so provider servicing must continue unaffected.
 *
 * This is the empirical proof that D-1+D-2's delivery-thread restoration
 * was actually needed. Pre-D-1 the per-event handler ran on the
 * processing thread inline with the provider that emitted it, so a 100
 * ms callback blocked request providers for 100 ms each. Post-D-2 the
 * handler runs on the delivery thread; D-3's courier keeps the encode
 * on the processing thread but the foreign-callback fan-out (the
 * sleeping part) still runs on the delivery thread, so providers stay
 * unblocked.
 *
 * Pass criteria:
 *   - addRequest throughput during the slow-callback phase is at least
 *     `MIN_THROUGHPUT_FRACTION` of the baseline (warm-up, no callback).
 *     We pick a conservative 0.5×; in practice the actual ratio should
 *     be ≥ 0.9× because the only shared resource the lanes contend on
 *     is the ctxs lock during the per-event handler's brief courier
 *     lookup.
 *   - The slow callback fired at least K_EMITS times (proves the
 *     events actually traversed the courier and reached the delivery
 *     thread).
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

#include "benchlib.hpp"

using namespace benchlib;

namespace {

constexpr int    SLOW_CB_MS              = 100;
constexpr int    K_EMITS                 = 5;     // 5 × 100 ms = 500 ms occupied delivery time
constexpr int    N_CALL_WORKERS          = 4;
constexpr int    WARMUP_MS               = 200;
constexpr int    RUN_MS                  = 600;   // > total slow-callback time
constexpr double MIN_THROUGHPUT_FRACTION = 0.5;

}  // namespace

int main() {
    Benchlib lib;
    const auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    // Phase 1 — baseline: no callback registered, no emits.
    // Measure addRequest throughput.
    std::atomic<int64_t> baselineCount{0};
    {
        std::atomic<bool> stop{false};
        auto worker = [&](int tid) {
            int i = 0;
            while (!stop.load(std::memory_order_relaxed)) {
                const auto r = lib.addRequest(tid * 9973 + i, i);
                if (r.isOk()) baselineCount.fetch_add(1, std::memory_order_relaxed);
                ++i;
            }
        };
        std::vector<std::thread> ws;
        for (int t = 0; t < N_CALL_WORKERS; ++t) ws.emplace_back(worker, t);
        std::this_thread::sleep_for(std::chrono::milliseconds(WARMUP_MS));
        stop.store(true);
        for (auto& th : ws) th.join();
    }
    const double baselineRate =
        double(baselineCount.load()) / (double(WARMUP_MS) / 1000.0);

    // Phase 2 — register a callback that sleeps SLOW_CB_MS per event,
    // fire K_EMITS events, then drive addRequest workers for RUN_MS.
    // The provider throughput during this phase must not collapse.
    std::atomic<int64_t> slowCbCount{0};
    const auto cbHandle = lib.onPingEvent(
        [&slowCbCount](Benchlib&, int64_t /*seqNo*/) {
            std::this_thread::sleep_for(std::chrono::milliseconds(SLOW_CB_MS));
            slowCbCount.fetch_add(1, std::memory_order_relaxed);
        });

    // Fire the emits BEFORE starting the call workers so the delivery
    // thread is fully occupied by the time addRequest traffic begins.
    const auto emitRes = lib.triggerEmitRequest(K_EMITS);
    if (!emitRes.isOk() || emitRes->emitted != K_EMITS) {
        std::fprintf(stderr, "triggerEmit failed\n");
        return 1;
    }

    std::atomic<int64_t> stressCount{0};
    {
        std::atomic<bool> stop{false};
        auto worker = [&](int tid) {
            int i = 0;
            while (!stop.load(std::memory_order_relaxed)) {
                const auto r = lib.addRequest(tid * 1031 + i, i + 1);
                if (r.isOk()) stressCount.fetch_add(1, std::memory_order_relaxed);
                ++i;
            }
        };
        std::vector<std::thread> ws;
        for (int t = 0; t < N_CALL_WORKERS; ++t) ws.emplace_back(worker, t);
        std::this_thread::sleep_for(std::chrono::milliseconds(RUN_MS));
        stop.store(true);
        for (auto& th : ws) th.join();
    }
    const double stressRate = double(stressCount.load()) / (double(RUN_MS) / 1000.0);
    const double ratio = stressRate / baselineRate;

    // Wait briefly for any in-flight slow callbacks to finish so the
    // count assertion is stable.
    std::this_thread::sleep_for(std::chrono::milliseconds(SLOW_CB_MS * 2));

    lib.offPingEvent(cbHandle);

    bool pass = true;
    if (slowCbCount.load() < K_EMITS) {
        std::fprintf(stderr,
                     "slow callback under-fired: got %lld expected >= %d\n",
                     (long long)slowCbCount.load(), K_EMITS);
        pass = false;
    }
    if (ratio < MIN_THROUGHPUT_FRACTION) {
        std::fprintf(stderr,
                     "provider throughput collapsed: stress=%.0f/s baseline=%.0f/s "
                     "ratio=%.2f (min=%.2f)\n",
                     stressRate, baselineRate, ratio, MIN_THROUGHPUT_FRACTION);
        pass = false;
    }

    std::printf("# slow_callback: baseline=%.0f req/s stress=%.0f req/s "
                "ratio=%.2f slowCbFired=%lld\n",
                baselineRate, stressRate, ratio,
                (long long)slowCbCount.load());
    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
