/* bench_e2e_driver — full end-to-end throughput scaling over a real payload.
 *
 * Drives the ACTUAL foreign path: this C++ process -> generated benchlib.hpp
 * wrapper (CBOR encode) -> libbenchlib C ABI -> courier -> Nim processing
 * thread, which FNV-1a-hashes every 500 B payload. Three scenarios:
 *
 *   1. signal    C++ -> Nim            one-way signal `_call`; the clock runs
 *                                      until the Nim handler has PROCESSED all
 *                                      messages (polled via e2eStatsRequest),
 *                                      so this is drain throughput, not submit.
 *   2. async     C++ -> Nim -> C++     `_callAsync` turnaround returning the
 *                                      hash; clock stops at the last callback.
 *   3. sync      C++ -> Nim -> C++     blocking `_call` turnaround; each
 *                                      thread's calls are serial round trips.
 *
 * Correctness is enforced per scenario: the aggregate hash accumulator
 * (scenario 1) / every returned hash (2, 3) must match the C++-computed
 * expectation, and completion counts must match exactly.
 *
 * Each scenario runs in two payload families:
 *   hash    — 500 B byte payload, handler FNV-1a-hashes it (copy-heavy)
 *   scalar  — 2 x int64 + 1 x float64 in, bool out, parity predicate
 *             (framing/dispatch cost isolated from the payload copy+hash)
 *
 * Env knobs: BROKER_E2E_PER_THREAD (default 10000), BROKER_E2E_ITERS (3,
 * median reported), BROKER_E2E_THREADS ("1,2,4,8,16,32,64"),
 * BROKER_E2E_PAYLOAD (500 bytes; hash family only).
 */

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "benchlib.hpp"

using namespace benchlib;
using sclock = std::chrono::steady_clock;

static uint64_t fnv1a64(const uint8_t* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < n; ++i) {
        h = (h ^ p[i]) * 0x100000001b3ull;
    }
    return h;
}

static int envInt(const char* name, int def) {
    const char* v = std::getenv(name);
    if (v == nullptr || *v == '\0') return def;
    return std::atoi(v);
}

static std::vector<int> envThreads() {
    const char* v = std::getenv("BROKER_E2E_THREADS");
    std::string s = (v != nullptr && *v != '\0') ? v : "1,2,4,8,16,32,64";
    std::vector<int> out;
    size_t pos = 0;
    while (pos < s.size()) {
        size_t comma = s.find(',', pos);
        if (comma == std::string::npos) comma = s.size();
        out.push_back(std::atoi(s.substr(pos, comma - pos).c_str()));
        pos = comma + 1;
    }
    return out;
}

[[noreturn]] static void fatal(const char* what, const std::string& detail) {
    std::fprintf(stderr, "FATAL: %s: %s\n", what, detail.c_str());
    std::exit(2);
}

struct IterOut {
    double msgPerSec = 0.0;
    uint64_t retries = 0;
};

// Shared per-run state (rebuilt per iteration).
struct RunCfg {
    int threads = 1;
    int perThread = 0;
    const Bytes* payload = nullptr;  // hash family only
    uint64_t perMsgHash = 0;         // hash family only
};

// Scalar family inputs, derived per message index i (identical formula in the
// Nim provider's `scalarPred`, so results are exactly predictable here).
static int64_t scalarA(int64_t i) { return i; }
static int64_t scalarB(int64_t i) { return 3 * i + 1; }
static double scalarX(int64_t i) { return 0.5 * static_cast<double>(i); }
static bool scalarPred(int64_t i) {
    return ((scalarA(i) + scalarB(i) + static_cast<int64_t>(scalarX(i))) & 1) == 0;
}
static uint64_t scalarTruesUpTo(int64_t n) {
    uint64_t trues = 0;
    for (int64_t i = 0; i < n; ++i)
        if (scalarPred(i)) ++trues;
    return trues;
}

// ---------------------------------------------------------------------------
// Scenario 1 — one-way signal, drain-timed.
// ---------------------------------------------------------------------------
static IterOut runSignal(const RunCfg& cfg) {
    Benchlib lib;
    if (auto cr = lib.createContext(); !cr.isOk()) fatal("createContext", cr.error());

    auto base = lib.e2eStatsRequest();
    if (!base.isOk()) fatal("e2eStatsRequest(base)", base.error());

    const uint64_t total =
        static_cast<uint64_t>(cfg.threads) * static_cast<uint64_t>(cfg.perThread);
    std::atomic<bool> start{false};
    std::atomic<uint64_t> retries{0};

    std::vector<std::thread> producers;
    producers.reserve(cfg.threads);
    for (int t = 0; t < cfg.threads; ++t) {
        producers.emplace_back([&] {
            uint64_t myRetries = 0;
            while (!start.load(std::memory_order_acquire)) {}
            for (int i = 0; i < cfg.perThread; ++i) {
                for (;;) {
                    auto r = lib.hashSignal(*cfg.payload);
                    if (r.isOk()) break;
                    if (r.error().rfind("EAGAIN", 0) == 0) {
                        ++myRetries;
                        std::this_thread::yield();  // let the consumer drain
                        continue;
                    }
                    fatal("hashSignal", r.error());
                }
            }
            retries.fetch_add(myRetries, std::memory_order_relaxed);
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& th : producers) th.join();

    // Drain phase: the run is over only when the Nim handler has processed
    // every message. Poll the stats request (a sync `_call`, negligible next
    // to the volume).
    const auto deadline = sclock::now() + std::chrono::seconds(120);
    int64_t processedDelta = 0;
    int64_t hashDelta = 0;
    for (;;) {
        auto s = lib.e2eStatsRequest();
        if (!s.isOk()) fatal("e2eStatsRequest(poll)", s.error());
        processedDelta = s->processed - base->processed;
        hashDelta = s->hashAcc - base->hashAcc;
        if (processedDelta >= static_cast<int64_t>(total)) break;
        if (sclock::now() > deadline) fatal("signal drain", "timeout waiting for drain");
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    const auto t1 = sclock::now();

    if (processedDelta != static_cast<int64_t>(total))
        fatal("signal correctness", "processed != submitted");
    const uint64_t expectedAcc = cfg.perMsgHash * total;  // wrapping, matches Nim
    if (static_cast<uint64_t>(hashDelta) != expectedAcc)
        fatal("signal correctness", "aggregate hash mismatch");

    const double sec = std::chrono::duration<double>(t1 - t0).count();
    return IterOut{static_cast<double>(total) / sec,
                   retries.load(std::memory_order_relaxed)};
}

// ---------------------------------------------------------------------------
// Scenario 2 — `_callAsync` turnaround, callback-timed.
// ---------------------------------------------------------------------------
static IterOut runAsync(const RunCfg& cfg) {
    Benchlib lib;
    if (auto cr = lib.createContext(); !cr.isOk()) fatal("createContext", cr.error());

    const uint64_t total =
        static_cast<uint64_t>(cfg.threads) * static_cast<uint64_t>(cfg.perThread);
    std::atomic<bool> start{false};
    std::atomic<uint64_t> retries{0};
    std::atomic<uint64_t> done{0};
    std::atomic<uint64_t> bad{0};

    const int64_t expected = static_cast<int64_t>(cfg.perMsgHash);
    auto cb = [&done, &bad, expected](Result<HashRequest> r) {
        if (!r.isOk() || r->hash != expected) bad.fetch_add(1, std::memory_order_relaxed);
        done.fetch_add(1, std::memory_order_release);
    };

    std::vector<std::thread> producers;
    producers.reserve(cfg.threads);
    for (int t = 0; t < cfg.threads; ++t) {
        producers.emplace_back([&] {
            uint64_t myRetries = 0;
            while (!start.load(std::memory_order_acquire)) {}
            for (int i = 0; i < cfg.perThread; ++i) {
                for (;;) {
                    const int32_t rc = lib.hashRequestAsync(*cfg.payload, cb);
                    if (rc == 0) break;
                    if (rc == Benchlib::asyncAgain) {
                        ++myRetries;
                        std::this_thread::yield();  // in-flight window full
                        continue;
                    }
                    fatal("hashRequestAsync", "rc=" + std::to_string(rc));
                }
            }
            retries.fetch_add(myRetries, std::memory_order_relaxed);
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& th : producers) th.join();

    const auto deadline = sclock::now() + std::chrono::seconds(120);
    while (done.load(std::memory_order_acquire) < total) {
        if (sclock::now() > deadline) fatal("async drain", "timeout waiting for callbacks");
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    const auto t1 = sclock::now();

    if (bad.load() != 0) fatal("async correctness", "hash mismatch in callbacks");

    const double sec = std::chrono::duration<double>(t1 - t0).count();
    return IterOut{static_cast<double>(total) / sec,
                   retries.load(std::memory_order_relaxed)};
}

// ---------------------------------------------------------------------------
// Scenario 3 — blocking `_call` turnaround; per-thread serial round trips.
// ---------------------------------------------------------------------------
static IterOut runSync(const RunCfg& cfg) {
    Benchlib lib;
    if (auto cr = lib.createContext(); !cr.isOk()) fatal("createContext", cr.error());

    const uint64_t total =
        static_cast<uint64_t>(cfg.threads) * static_cast<uint64_t>(cfg.perThread);
    std::atomic<bool> start{false};
    std::atomic<uint64_t> retries{0};
    const int64_t expected = static_cast<int64_t>(cfg.perMsgHash);

    std::vector<std::thread> producers;
    producers.reserve(cfg.threads);
    for (int t = 0; t < cfg.threads; ++t) {
        producers.emplace_back([&] {
            uint64_t myRetries = 0;
            while (!start.load(std::memory_order_acquire)) {}
            for (int i = 0; i < cfg.perThread; ++i) {
                for (;;) {
                    auto r = lib.hashRequest(*cfg.payload);
                    if (r.isOk()) {
                        if (r->hash != expected) fatal("sync correctness", "hash mismatch");
                        break;
                    }
                    if (r.error().rfind("EAGAIN", 0) == 0) {
                        ++myRetries;
                        std::this_thread::yield();
                        continue;
                    }
                    fatal("hashRequest", r.error());
                }
            }
            retries.fetch_add(myRetries, std::memory_order_relaxed);
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& th : producers) th.join();  // blocking calls: join == all done
    const auto t1 = sclock::now();

    const double sec = std::chrono::duration<double>(t1 - t0).count();
    return IterOut{static_cast<double>(total) / sec,
                   retries.load(std::memory_order_relaxed)};
}

// ---------------------------------------------------------------------------
// Scalar family — same three lanes, (int64, int64, float64) -> bool.
// ---------------------------------------------------------------------------
static IterOut runScalarSignal(const RunCfg& cfg) {
    Benchlib lib;
    if (auto cr = lib.createContext(); !cr.isOk()) fatal("createContext", cr.error());

    auto base = lib.e2eStatsRequest();
    if (!base.isOk()) fatal("e2eStatsRequest(base)", base.error());

    const uint64_t total =
        static_cast<uint64_t>(cfg.threads) * static_cast<uint64_t>(cfg.perThread);
    std::atomic<bool> start{false};
    std::atomic<uint64_t> retries{0};

    std::vector<std::thread> producers;
    producers.reserve(cfg.threads);
    for (int t = 0; t < cfg.threads; ++t) {
        producers.emplace_back([&] {
            uint64_t myRetries = 0;
            while (!start.load(std::memory_order_acquire)) {}
            for (int64_t i = 0; i < cfg.perThread; ++i) {
                for (;;) {
                    auto r = lib.scalarSignal(scalarA(i), scalarB(i), scalarX(i));
                    if (r.isOk()) break;
                    if (r.error().rfind("EAGAIN", 0) == 0) {
                        ++myRetries;
                        std::this_thread::yield();
                        continue;
                    }
                    fatal("scalarSignal", r.error());
                }
            }
            retries.fetch_add(myRetries, std::memory_order_relaxed);
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& th : producers) th.join();

    const auto deadline = sclock::now() + std::chrono::seconds(120);
    int64_t processedDelta = 0;
    int64_t trueDelta = 0;
    for (;;) {
        auto s = lib.e2eStatsRequest();
        if (!s.isOk()) fatal("e2eStatsRequest(poll)", s.error());
        processedDelta = s->scalarProcessed - base->scalarProcessed;
        trueDelta = s->scalarTrue - base->scalarTrue;
        if (processedDelta >= static_cast<int64_t>(total)) break;
        if (sclock::now() > deadline)
            fatal("scalar signal drain", "timeout waiting for drain");
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    const auto t1 = sclock::now();

    if (processedDelta != static_cast<int64_t>(total))
        fatal("scalar signal correctness", "processed != submitted");
    const uint64_t expectedTrues =
        scalarTruesUpTo(cfg.perThread) * static_cast<uint64_t>(cfg.threads);
    if (static_cast<uint64_t>(trueDelta) != expectedTrues)
        fatal("scalar signal correctness", "predicate count mismatch");

    const double sec = std::chrono::duration<double>(t1 - t0).count();
    return IterOut{static_cast<double>(total) / sec,
                   retries.load(std::memory_order_relaxed)};
}

static IterOut runScalarAsync(const RunCfg& cfg) {
    Benchlib lib;
    if (auto cr = lib.createContext(); !cr.isOk()) fatal("createContext", cr.error());

    const uint64_t total =
        static_cast<uint64_t>(cfg.threads) * static_cast<uint64_t>(cfg.perThread);
    std::atomic<bool> start{false};
    std::atomic<uint64_t> retries{0};
    std::atomic<uint64_t> done{0};
    std::atomic<uint64_t> bad{0};

    std::vector<std::thread> producers;
    producers.reserve(cfg.threads);
    for (int t = 0; t < cfg.threads; ++t) {
        producers.emplace_back([&] {
            uint64_t myRetries = 0;
            while (!start.load(std::memory_order_acquire)) {}
            for (int64_t i = 0; i < cfg.perThread; ++i) {
                const bool expected = scalarPred(i);
                auto cb = [&done, &bad, expected](Result<ScalarCheckRequest> r) {
                    if (!r.isOk() || r->ok != expected)
                        bad.fetch_add(1, std::memory_order_relaxed);
                    done.fetch_add(1, std::memory_order_release);
                };
                for (;;) {
                    const int32_t rc = lib.scalarCheckRequestAsync(
                        scalarA(i), scalarB(i), scalarX(i), cb);
                    if (rc == 0) break;
                    if (rc == Benchlib::asyncAgain) {
                        ++myRetries;
                        std::this_thread::yield();
                        continue;
                    }
                    fatal("scalarCheckRequestAsync", "rc=" + std::to_string(rc));
                }
            }
            retries.fetch_add(myRetries, std::memory_order_relaxed);
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& th : producers) th.join();

    const auto deadline = sclock::now() + std::chrono::seconds(120);
    while (done.load(std::memory_order_acquire) < total) {
        if (sclock::now() > deadline)
            fatal("scalar async drain", "timeout waiting for callbacks");
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    const auto t1 = sclock::now();

    if (bad.load() != 0) fatal("scalar async correctness", "predicate mismatch");

    const double sec = std::chrono::duration<double>(t1 - t0).count();
    return IterOut{static_cast<double>(total) / sec,
                   retries.load(std::memory_order_relaxed)};
}

static IterOut runScalarSync(const RunCfg& cfg) {
    Benchlib lib;
    if (auto cr = lib.createContext(); !cr.isOk()) fatal("createContext", cr.error());

    const uint64_t total =
        static_cast<uint64_t>(cfg.threads) * static_cast<uint64_t>(cfg.perThread);
    std::atomic<bool> start{false};
    std::atomic<uint64_t> retries{0};

    std::vector<std::thread> producers;
    producers.reserve(cfg.threads);
    for (int t = 0; t < cfg.threads; ++t) {
        producers.emplace_back([&] {
            uint64_t myRetries = 0;
            while (!start.load(std::memory_order_acquire)) {}
            for (int64_t i = 0; i < cfg.perThread; ++i) {
                for (;;) {
                    auto r = lib.scalarCheckRequest(scalarA(i), scalarB(i), scalarX(i));
                    if (r.isOk()) {
                        if (r->ok != scalarPred(i))
                            fatal("scalar sync correctness", "predicate mismatch");
                        break;
                    }
                    if (r.error().rfind("EAGAIN", 0) == 0) {
                        ++myRetries;
                        std::this_thread::yield();
                        continue;
                    }
                    fatal("scalarCheckRequest", r.error());
                }
            }
            retries.fetch_add(myRetries, std::memory_order_relaxed);
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& th : producers) th.join();
    const auto t1 = sclock::now();

    const double sec = std::chrono::duration<double>(t1 - t0).count();
    return IterOut{static_cast<double>(total) / sec,
                   retries.load(std::memory_order_relaxed)};
}

// ---------------------------------------------------------------------------
// Sweep driver
// ---------------------------------------------------------------------------
static double median(std::vector<double> xs) {
    std::sort(xs.begin(), xs.end());
    const size_t n = xs.size();
    return (n % 2 == 1) ? xs[n / 2] : (xs[n / 2 - 1] + xs[n / 2]) / 2.0;
}

static void runScenario(const char* name, IterOut (*fn)(const RunCfg&),
                        const std::vector<int>& threadCounts, int perThread,
                        int iters, const Bytes& payload, uint64_t perMsgHash,
                        int bytesPerMsg) {
    std::printf("── %s — %d msgs/thread (median of %d) ──────\n", name, perThread,
                iters);
    std::printf("  %-9s%-11s%-13s%-11s%-12s%s\n", "threads", "msgs", "msg/s",
                "MB/s", "vs 1-thread", "again-retries");
    double base = 0.0;
    for (int k : threadCounts) {
        RunCfg cfg;
        cfg.threads = k;
        cfg.perThread = perThread;
        cfg.payload = &payload;
        cfg.perMsgHash = perMsgHash;
        std::vector<double> rates;
        uint64_t retries = 0;
        for (int i = 0; i < iters; ++i) {
            const IterOut out = fn(cfg);
            rates.push_back(out.msgPerSec);
            retries += out.retries;
        }
        const double med = median(rates);
        if (base == 0.0) base = med;
        char mbs[32];
        if (bytesPerMsg > 0)
            std::snprintf(mbs, sizeof(mbs), "%.2f",
                          med * static_cast<double>(bytesPerMsg) / 1e6);
        else
            std::snprintf(mbs, sizeof(mbs), "-");
        std::printf("  %-9d%-11llu%-13.0f%-11s%-12s%llu\n", k,
                    static_cast<unsigned long long>(
                        static_cast<uint64_t>(k) * static_cast<uint64_t>(perThread)),
                    med, mbs,
                    (std::to_string(med / base).substr(0, 4) + "x").c_str(),
                    static_cast<unsigned long long>(retries));
        std::fflush(stdout);
    }
    std::printf("\n");
}

int main() {
    const int perThread = envInt("BROKER_E2E_PER_THREAD", 10000);
    const int iters = envInt("BROKER_E2E_ITERS", 3);
    const int payloadSize = envInt("BROKER_E2E_PAYLOAD", 500);
    const std::vector<int> threadCounts = envThreads();
    if (perThread < 1 || iters < 1 || payloadSize < 1 || threadCounts.empty()) {
        std::fprintf(stderr, "invalid BROKER_E2E_* configuration\n");
        return 2;
    }

    Bytes payload;
    payload.resize(static_cast<size_t>(payloadSize));
    for (size_t i = 0; i < payload.size(); ++i)
        payload[i] = static_cast<uint8_t>(i & 0xFF);
    const uint64_t perMsgHash = fnv1a64(payload.data(), payload.size());

    std::printf("# benchlib FFI e2e throughput — hash family: payload=%dB "
                "handler=fnv1a64; scalar family: (i64,i64,f64)->bool parity\n\n",
                payloadSize);
    const std::string tag = " [" + std::to_string(payloadSize) + "B hash]";
    runScenario(("signal C++ -> Nim (one-way _call, drain-timed)" + tag).c_str(),
                runSignal, threadCounts, perThread, iters, payload, perMsgHash,
                payloadSize);
    runScenario(("async request C++ -> Nim -> C++ (_callAsync turnaround)" + tag).c_str(),
                runAsync, threadCounts, perThread, iters, payload, perMsgHash,
                payloadSize);
    runScenario(("sync request C++ -> Nim -> C++ (blocking _call turnaround)" + tag).c_str(),
                runSync, threadCounts, perThread, iters, payload, perMsgHash,
                payloadSize);

    runScenario("signal C++ -> Nim (one-way _call, drain-timed) [scalar]",
                runScalarSignal, threadCounts, perThread, iters, payload, perMsgHash,
                0);
    runScenario("async request C++ -> Nim -> C++ (_callAsync turnaround) [scalar]",
                runScalarAsync, threadCounts, perThread, iters, payload, perMsgHash,
                0);
    runScenario("sync request C++ -> Nim -> C++ (blocking _call turnaround) [scalar]",
                runScalarSync, threadCounts, perThread, iters, payload, perMsgHash,
                0);

    std::printf(
        "  correctness: all counts, hashes and predicates matched expectations.\n");
    return 0;
}
