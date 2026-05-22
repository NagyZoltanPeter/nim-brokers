/*
 * stress_event_no_foreign.cpp — Part D-4 dispatch-contract stress test.
 *
 * Pure-Nim audience: K same-thread Nim listeners + 1 cross-thread Nim
 * listener, ZERO foreign callbacks via _subscribe. Asserts that Lanes 1
 * and 2 fire end-to-end without any FFI registration.
 *
 * This proves the FFI-lane atomic-counter discriminator (subsCount==0)
 * doesn't suppress events for the Nim audiences — the lanes are
 * independent. The "zero CBOR encodes happen on emit" instrumented
 * assertion from the original D-4 scope is deferred to D-6 (bench
 * harness has internal counters anyway); this driver is the
 * correctness-only contract test.
 */

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>

#include "benchlib.hpp"

using namespace benchlib;

namespace {

constexpr int K_SAME_THREAD = 5;
constexpr int EMIT_COUNT    = 500;
constexpr int MAX_WAIT_MS   = 2000;

}  // namespace

int main() {
    Benchlib lib;
    const auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    // Deliberately do NOT call onPingEvent — no foreign subscribers.

    const auto installSame = lib.installSameThreadNimListenersRequest(K_SAME_THREAD);
    if (!installSame.isOk() || installSame->installed != K_SAME_THREAD) {
        std::fprintf(stderr, "installSameThread failed\n");
        return 1;
    }
    const auto installCross = lib.installCrossThreadNimListenerRequest();
    if (!installCross.isOk() || installCross->installed != 1) {
        std::fprintf(stderr, "installCrossThread failed\n");
        return 1;
    }

    const auto emit = lib.triggerEmitRequest(EMIT_COUNT);
    if (!emit.isOk() || emit->emitted != EMIT_COUNT) {
        std::fprintf(stderr, "triggerEmit failed\n");
        return 1;
    }

    const int64_t expectedSame  = int64_t(K_SAME_THREAD) * EMIT_COUNT;
    const int64_t expectedCross = int64_t(1)             * EMIT_COUNT;

    int64_t same = 0, cross = 0;
    const auto t0 = std::chrono::steady_clock::now();
    while (true) {
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        const auto st = lib.getStatsRequest();
        if (st.isOk()) {
            same  = st->sameThreadCount;
            cross = st->crossThreadCount;
        }
        if (same >= expectedSame && cross >= expectedCross) break;
        if (ms >= MAX_WAIT_MS) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    bool pass = true;
    if (same != expectedSame) {
        std::fprintf(stderr,
                     "Lane 1 mismatch: got %lld expected %lld\n",
                     (long long)same, (long long)expectedSame);
        pass = false;
    }
    if (cross != expectedCross) {
        std::fprintf(stderr,
                     "Lane 2 mismatch: got %lld expected %lld\n",
                     (long long)cross, (long long)expectedCross);
        pass = false;
    }

    std::printf("# no_foreign: K=%d emits=%d same=%lld cross=%lld\n",
                K_SAME_THREAD, EMIT_COUNT,
                (long long)same, (long long)cross);
    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
