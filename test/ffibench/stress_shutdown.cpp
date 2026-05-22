/*
 * stress_shutdown.cpp — shutdown-race stress test.
 *
 * The §6.4 #4 case from doc/CBOR_Refactoring.md: foreign threads issue
 * `addRequest` calls while another thread calls `<lib>_shutdown`. Verifies
 * that every call returns either a valid result OR a clean error code —
 * never a hang, never a crash, never a UAF.
 *
 * Runs several create/shutdown cycles so the courier lifecycle is
 * exercised repeatedly, not just once.
 */
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

#include "benchlib.hpp"

using namespace benchlib;

int main() {
    constexpr int CYCLES = 5;
    constexpr int N_WORKERS = 8;
    constexpr int LET_RUN_MS = 100;

    int64_t grandOk = 0;
    int64_t grandCleanErr = 0;
    int64_t grandMismatch = 0;

    for (int cycle = 0; cycle < CYCLES; ++cycle) {
        Benchlib lib;
        auto cr = lib.createContext();
        if (!cr.isOk()) {
            std::fprintf(stderr, "[cycle %d] createContext failed\n", cycle);
            return 1;
        }

        std::atomic<bool> stop{false};
        std::atomic<int64_t> ok{0};
        std::atomic<int64_t> cleanErr{0}; // expected post-shutdown
        std::atomic<int64_t> mismatch{0};

        auto worker = [&](int tid) {
            int i = 0;
            while (!stop.load(std::memory_order_relaxed)) {
                const int32_t a = tid * 1000003 + i;
                const int32_t b = a + 1;
                auto r = lib.addRequest(a, b);
                if (r.isOk()) {
                    if (r->sum != a + b) {
                        mismatch.fetch_add(1, std::memory_order_relaxed);
                    } else {
                        ok.fetch_add(1, std::memory_order_relaxed);
                    }
                } else {
                    cleanErr.fetch_add(1, std::memory_order_relaxed);
                }
                ++i;
            }
        };

        std::vector<std::thread> ws;
        ws.reserve(N_WORKERS);
        for (int t = 0; t < N_WORKERS; ++t) ws.emplace_back(worker, t);

        // Let calls flow, then shutdown WHILE workers are still hammering.
        // After shutdown returns, new `addRequest` calls hit the inactive
        // ctx → fast-fail with a clean error code, workers loop, see
        // `stop`, exit. No worker should hang or crash.
        std::this_thread::sleep_for(std::chrono::milliseconds(LET_RUN_MS));
        const auto tShutdown0 = std::chrono::steady_clock::now();
        lib.shutdown();
        const auto tShutdown1 = std::chrono::steady_clock::now();
        stop.store(true, std::memory_order_relaxed);
        for (auto& th : ws) th.join();

        const double shutdownMs =
            std::chrono::duration<double, std::milli>(tShutdown1 - tShutdown0).count();
        std::printf("# cycle %d: ok=%" PRId64 " cleanErr=%" PRId64
                    " mismatch=%" PRId64 " shutdown=%.1fms\n",
                    cycle, ok.load(), cleanErr.load(), mismatch.load(),
                    shutdownMs);
        grandOk += ok.load();
        grandCleanErr += cleanErr.load();
        grandMismatch += mismatch.load();
    }

    std::printf("# total: ok=%" PRId64 " cleanErr=%" PRId64
                " mismatch=%" PRId64 "\n",
                grandOk, grandCleanErr, grandMismatch);
    const bool pass = grandMismatch == 0;
    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
