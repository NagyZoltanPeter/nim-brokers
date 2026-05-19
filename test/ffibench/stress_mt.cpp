/*
 * stress_mt.cpp — MT hammer test for the CBOR courier.
 *
 * K foreign threads × M concurrent `addRequest` calls into ONE Benchlib
 * context. Verifies (a) no crash / hang, (b) every call returns isOk(),
 * (c) every result matches its caller's inputs (no slot cross-talk).
 *
 * Built by test/ffibench/CMakeLists.txt; run after the CBOR benchlib
 * shared library is in place.
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
    constexpr int N_THREADS = 16;
    constexpr int CALLS_PER_THREAD = 5000;
    const int64_t TOTAL = static_cast<int64_t>(N_THREADS) * CALLS_PER_THREAD;

    Benchlib lib;
    auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    std::atomic<int64_t> okCount{0};
    std::atomic<int64_t> failCount{0};
    std::atomic<int64_t> mismatchCount{0};

    auto worker = [&](int tid) {
        for (int i = 0; i < CALLS_PER_THREAD; ++i) {
            const int32_t a = tid * 1000003 + i;
            const int32_t b = a + 1;
            auto r = lib.addRequest(a, b);
            if (!r.isOk()) {
                failCount.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            if (r->sum != a + b) {
                mismatchCount.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            okCount.fetch_add(1, std::memory_order_relaxed);
        }
    };

    const auto t0 = std::chrono::steady_clock::now();
    std::vector<std::thread> ts;
    ts.reserve(N_THREADS);
    for (int t = 0; t < N_THREADS; ++t) ts.emplace_back(worker, t);
    for (auto& th : ts) th.join();
    const auto t1 = std::chrono::steady_clock::now();

    const double secs = std::chrono::duration<double>(t1 - t0).count();
    std::printf("# stress_mt: %d threads × %d calls = %" PRId64
                " total in %.2fs (%.0f ns/call wall)\n",
                N_THREADS, CALLS_PER_THREAD, TOTAL, secs,
                secs * 1e9 / static_cast<double>(TOTAL));
    std::printf("# ok=%" PRId64 " fail=%" PRId64 " mismatch=%" PRId64 "\n",
                okCount.load(), failCount.load(), mismatchCount.load());

    lib.shutdown();

    const bool pass = okCount.load() == TOTAL
                      && failCount.load() == 0
                      && mismatchCount.load() == 0;
    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
