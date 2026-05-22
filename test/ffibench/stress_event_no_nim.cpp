/*
 * stress_event_no_nim.cpp — Part D-4 dispatch-contract stress test.
 *
 * Pure-foreign audience: N foreign callbacks via _subscribe / onPingEvent,
 * ZERO Nim listeners. Asserts Lane 3 (FFI fan-out via the event courier
 * ring) works end-to-end without any Nim audience.
 *
 * This proves Nim-lane infrastructure (MT EventBroker buckets, typed
 * slabs) isn't a prerequisite for foreign delivery — the FFI lane forks
 * upstream of any Nim listener registration. The "MT slab is not
 * touched" instrumented assertion from the original D-4 scope is
 * deferred to D-6 (bench harness); this driver is the correctness-only
 * contract test.
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

constexpr int N_FOREIGN  = 6;
constexpr int EMIT_COUNT = 300;
constexpr int MAX_WAIT_MS = 2000;

}  // namespace

int main() {
    Benchlib lib;
    const auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    std::vector<std::atomic<int64_t>> foreignCounts(N_FOREIGN);
    std::vector<uint64_t> handles;
    handles.reserve(N_FOREIGN);
    for (int i = 0; i < N_FOREIGN; ++i) {
        foreignCounts[i].store(0);
        auto* cnt = &foreignCounts[i];
        handles.push_back(lib.onPingEvent(
            [cnt](Benchlib&, int64_t /*seqNo*/) {
                cnt->fetch_add(1, std::memory_order_relaxed);
            }));
    }

    // Deliberately do NOT call installSameThread/installCrossThread.
    // The only audience is the N foreign callbacks above.

    const auto emit = lib.triggerEmitRequest(EMIT_COUNT);
    if (!emit.isOk() || emit->emitted != EMIT_COUNT) {
        std::fprintf(stderr, "triggerEmit failed\n");
        return 1;
    }

    const int64_t expectedEach = int64_t(EMIT_COUNT);
    bool allReady = false;
    const auto t0 = std::chrono::steady_clock::now();
    while (true) {
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        allReady = true;
        for (int i = 0; i < N_FOREIGN; ++i) {
            if (foreignCounts[i].load(std::memory_order_relaxed) < expectedEach) {
                allReady = false;
                break;
            }
        }
        if (allReady) break;
        if (ms >= MAX_WAIT_MS) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    // Also confirm the Nim audience counters stayed at zero (no spurious
    // Nim delivery via shared infrastructure).
    int64_t same = 0, cross = 0;
    const auto st = lib.getStatsRequest();
    if (st.isOk()) {
        same  = st->sameThreadCount;
        cross = st->crossThreadCount;
    }

    bool pass = true;
    if (same != 0) {
        std::fprintf(stderr, "Lane 1 leaked: same=%lld\n", (long long)same);
        pass = false;
    }
    if (cross != 0) {
        std::fprintf(stderr, "Lane 2 leaked: cross=%lld\n", (long long)cross);
        pass = false;
    }
    for (int i = 0; i < N_FOREIGN; ++i) {
        const int64_t got = foreignCounts[i].load(std::memory_order_relaxed);
        if (got != expectedEach) {
            std::fprintf(stderr,
                         "foreign[%d] mismatch: got %lld expected %lld\n",
                         i, (long long)got, (long long)expectedEach);
            pass = false;
        }
    }

    std::printf("# no_nim: N=%d emits=%d same=%lld cross=%lld\n",
                N_FOREIGN, EMIT_COUNT, (long long)same, (long long)cross);
    for (int i = 0; i < N_FOREIGN; ++i) {
        std::printf("#   foreign[%d]=%lld\n",
                    i, (long long)foreignCounts[i].load(std::memory_order_relaxed));
    }

    for (auto h : handles) lib.offPingEvent(h);

    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
