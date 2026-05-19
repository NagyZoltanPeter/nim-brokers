/*
 * bench_driver.cpp — Phase 0 FFI microbenchmark driver.
 * See doc/CBOR_Refactoring.md §7.3.
 *
 * Compiled twice via CMake against the generated benchlib.hpp wrapper:
 *   - USE_CBOR off  -> native ABI build
 *   - USE_CBOR on   -> CBOR ABI build
 *
 * Times the FFI request path: a simple all-scalar request (AddRequest)
 * and a variable-size payload request (VecRequest) across payload sizes.
 * Output is CSV on stdout: mode,scenario,payload_bytes,ns_per_call
 */
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "benchlib.hpp"

using namespace benchlib;
using sclock = std::chrono::steady_clock;

#ifdef USE_CBOR
static const char* kMode = "cbor";
#else
static const char* kMode = "native";
#endif

// Every result is isOk()-checked: a fast-failed call (e.g. MT cell
// overflow returning err) must never be timed as if it were a real
// round-trip. Any failure aborts the whole run.
static double timeAdd(Benchlib& lib, int iterations) {
    int64_t acc = 0;
    const auto t0 = sclock::now();
    for (int i = 0; i < iterations; ++i) {
        auto r = lib.addRequest(static_cast<int32_t>(i),
                                static_cast<int32_t>(i + 1));
        if (!r.isOk()) {
            std::fprintf(stderr, "FATAL: addRequest failed — not a real call\n");
            std::exit(2);
        }
        acc += r->sum;
    }
    const auto t1 = sclock::now();
    volatile int64_t sink = acc;
    (void)sink;
    return std::chrono::duration<double, std::nano>(t1 - t0).count()
           / static_cast<double>(iterations);
}

static double timeVec(Benchlib& lib, int elems, int iterations) {
    std::vector<int32_t> payload(static_cast<size_t>(elems));
    for (int i = 0; i < elems; ++i) payload[static_cast<size_t>(i)] = i;
    int64_t acc = 0;
    const auto t0 = sclock::now();
    for (int i = 0; i < iterations; ++i) {
        auto r = lib.vecRequest(payload);
        if (!r.isOk()) {
            std::fprintf(stderr,
                "FATAL: vecRequest(%d elems) failed — not a real call "
                "(MT cell overflow?)\n", elems);
            std::exit(2);
        }
        if (r->length != elems) {
            std::fprintf(stderr,
                "FATAL: vecRequest round-trip mismatch: got length=%d want=%d\n",
                r->length, elems);
            std::exit(2);
        }
        acc += r->checksum;
    }
    const auto t1 = sclock::now();
    volatile int64_t sink = acc;
    (void)sink;
    return std::chrono::duration<double, std::nano>(t1 - t0).count()
           / static_cast<double>(iterations);
}

int main() {
    Benchlib lib;
    auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "createContext failed\n");
        return 1;
    }

    // warmup
    for (int i = 0; i < 5000; ++i) {
        auto r = lib.addRequest(i, i);
        (void)r;
    }

    std::printf("# benchlib FFI microbenchmark — mode=%s\n", kMode);
    std::printf("# mode,scenario,payload_bytes,ns_per_call\n");
    std::fflush(stdout);

    const double addNs = timeAdd(lib, 20000);
    std::printf("%s,add_scalar,8,%.1f\n", kMode, addNs);
    std::fflush(stdout);

    // Capped under the 4 KiB MT cell (seq[int32] API-broker classification).
    const int sizes[] = {64, 256, 512, 1024, 2048, 3072};
    for (int s : sizes) {
        const int elems = s / 4; // int32 elements
        const double ns = timeVec(lib, elems, 5000);
        std::printf("%s,vec_payload,%d,%.1f\n", kMode, s, ns);
        std::fflush(stdout);
    }

    lib.shutdown();
    return 0;
}
