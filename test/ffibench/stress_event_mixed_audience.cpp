/*
 * stress_event_mixed_audience.cpp — Part D-4 dispatch-contract stress test.
 *
 * Drives all three dispatch lanes on the same EventBroker(API) at the same
 * time and asserts every audience receives every event with no cross-talk:
 *
 *   Lane 1 (same-thread Nim)   — K listeners installed on the processing
 *                                thread via installSameThreadNimListeners
 *   Lane 2 (cross-thread Nim)  — 1 listener installed on a Nim-spawned
 *                                helper thread via installCrossThreadNimListener
 *   Lane 3 (FFI fanout)        — N foreign callbacks registered via onPingEvent
 *
 * After EMIT_COUNT emits from the processing thread, assertions:
 *   - sameThreadCount  == K * EMIT_COUNT
 *   - crossThreadCount == 1 * EMIT_COUNT
 *   - each foreign callback received EMIT_COUNT events
 *
 * The mixed-audience proof: lanes don't cross-talk. Lane 1's same-thread
 * fast path doesn't accidentally swallow events meant for Lane 3; the
 * Lane 3 atomic-counter discriminator doesn't suppress encoding when Nim
 * audiences are present; etc.
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

constexpr int K_SAME_THREAD = 3;       // Lane 1 listeners
constexpr int N_FOREIGN     = 4;       // Lane 3 foreign callbacks
constexpr int EMIT_COUNT    = 200;     // emits per cycle
constexpr int MAX_WAIT_MS   = 2000;    // delivery deadline after emit

}  // namespace

int main() {
    Benchlib lib;
    const auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    // Lane 3 — register N foreign callbacks, each with its own counter.
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

    // Lane 1 — ask the library to install K same-thread Nim listeners.
    const auto installSame = lib.installSameThreadNimListenersRequest(K_SAME_THREAD);
    if (!installSame.isOk() || installSame->installed != K_SAME_THREAD) {
        std::fprintf(stderr, "installSameThread failed: installed=%d\n",
                     installSame.isOk() ? installSame->installed : -1);
        return 1;
    }

    // Lane 2 — install one cross-thread Nim listener.
    const auto installCross = lib.installCrossThreadNimListenerRequest();
    if (!installCross.isOk() || installCross->installed != 1) {
        std::fprintf(stderr, "installCrossThread failed\n");
        return 1;
    }

    // Trigger emits on the processing thread.
    const auto emit = lib.triggerEmitRequest(EMIT_COUNT);
    if (!emit.isOk() || emit->emitted != EMIT_COUNT) {
        std::fprintf(stderr, "triggerEmit failed\n");
        return 1;
    }

    // Wait for all audiences to settle. Poll the Nim counters via the
    // stats request and the foreign counters directly. Cap with a deadline
    // so a missing-event bug surfaces as a deterministic failure rather
    // than a hang.
    const int64_t expectedSame  = int64_t(K_SAME_THREAD) * EMIT_COUNT;
    const int64_t expectedCross = int64_t(1)             * EMIT_COUNT;
    const int64_t expectedForeignEach = int64_t(EMIT_COUNT);

    const auto t0 = std::chrono::steady_clock::now();
    auto elapsedMs = [&]() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now() - t0).count();
    };

    int64_t same = 0, cross = 0;
    bool allForeignReady = false;
    while (elapsedMs() < MAX_WAIT_MS) {
        const auto st = lib.getStatsRequest();
        if (st.isOk()) {
            same  = st->sameThreadCount;
            cross = st->crossThreadCount;
        }
        allForeignReady = true;
        for (int i = 0; i < N_FOREIGN; ++i) {
            if (foreignCounts[i].load(std::memory_order_relaxed) < expectedForeignEach) {
                allForeignReady = false;
                break;
            }
        }
        if (same >= expectedSame && cross >= expectedCross && allForeignReady) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    bool pass = true;
    if (same != expectedSame) {
        std::fprintf(stderr,
                     "Lane 1 (same-thread Nim) mismatch: got %lld, expected %lld\n",
                     (long long)same, (long long)expectedSame);
        pass = false;
    }
    if (cross != expectedCross) {
        std::fprintf(stderr,
                     "Lane 2 (cross-thread Nim) mismatch: got %lld, expected %lld\n",
                     (long long)cross, (long long)expectedCross);
        pass = false;
    }
    for (int i = 0; i < N_FOREIGN; ++i) {
        const int64_t got = foreignCounts[i].load(std::memory_order_relaxed);
        if (got != expectedForeignEach) {
            std::fprintf(stderr,
                         "Lane 3 (foreign cb %d) mismatch: got %lld, expected %lld\n",
                         i, (long long)got, (long long)expectedForeignEach);
            pass = false;
        }
    }

    std::printf("# mixed_audience: K=%d N=%d emits=%d same=%lld cross=%lld\n",
                K_SAME_THREAD, N_FOREIGN, EMIT_COUNT,
                (long long)same, (long long)cross);
    for (int i = 0; i < N_FOREIGN; ++i) {
        std::printf("#   foreign[%d]=%lld\n",
                    i, (long long)foreignCounts[i].load(std::memory_order_relaxed));
    }

    for (auto h : handles) {
        lib.offPingEvent(h);
    }

    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
