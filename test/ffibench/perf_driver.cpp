// perf_driver.cpp — FFI perftest from C++.
//
// Mirrors the shape of test/perf_test_multi_thread_*_broker.nim
// (5 worker threads × 500 ops × 512 B payload) but drives the
// traffic across the FFI boundary into a Nim provider / Nim emitter.
//
// Build via:
//     cmake -S test/ffibench -B test/ffibench/cmake-build
//     cmake --build test/ffibench/cmake-build --target perf_driver
//     test/ffibench/build/perf_driver
//
// The Nimble `perftestFfi` task wraps the orc + refc × debug + release
// matrix on top of this binary.
//
// Output is the same `┌─── Cross-Thread Results ─── … └─` boxes the
// Nim-side perftest prints, plus a trailing CSV line per scenario for
// diff-friendly capture.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>

#include "benchlib.hpp"

using namespace benchlib;
using sclock = std::chrono::steady_clock;

// Workload shape — keep aligned with perf_test_multi_thread_*_broker.nim.
static constexpr int kWorkerThreads = 5;
static constexpr int kOpsPerThread = 500;
static constexpr int kPayloadBytes = 512;
static constexpr int kTotalOps = kWorkerThreads * kOpsPerThread;
static constexpr int kVecElements = kPayloadBytes / static_cast<int>(sizeof(int32_t));

// ---------------------------------------------------------------------------
// Output helpers — matches the Nim-side fmtNs / fmtRate formatting so the
// two tables read identically.
// ---------------------------------------------------------------------------

static void fmtNs(char* buf, size_t cap, int64_t ns) {
    if (ns >= 1'000'000'000) {
        std::snprintf(buf, cap, "%.3f s",
                      static_cast<double>(ns) / 1e9);
    } else if (ns >= 1'000'000) {
        std::snprintf(buf, cap, "%.3f ms",
                      static_cast<double>(ns) / 1e6);
    } else if (ns >= 1'000) {
        std::snprintf(buf, cap, "%.1f µs",
                      static_cast<double>(ns) / 1e3);
    } else {
        std::snprintf(buf, cap, "%" PRId64 " ns", ns);
    }
}

static void fmtRate(char* buf, size_t cap, int64_t ops, int64_t ns,
                    const char* unit) {
    const double secs = static_cast<double>(ns) / 1e9;
    if (secs <= 0) {
        std::snprintf(buf, cap, "n/a");
        return;
    }
    const double rate = static_cast<double>(ops) / secs;
    if (rate >= 1e6) {
        std::snprintf(buf, cap, "%.2f M %s/s", rate / 1e6, unit);
    } else if (rate >= 1e3) {
        std::snprintf(buf, cap, "%.2f K %s/s", rate / 1e3, unit);
    } else {
        std::snprintf(buf, cap, "%.2f %s/s", rate, unit);
    }
}

struct LatStats {
    int64_t avgNs = 0;
    int64_t minNs = 0;
    int64_t maxNs = 0;
    int64_t p50Ns = 0;
    int64_t p99Ns = 0;
};

static LatStats summarize(std::vector<int64_t>& samples) {
    LatStats s{};
    if (samples.empty()) return s;
    std::sort(samples.begin(), samples.end());
    s.minNs = samples.front();
    s.maxNs = samples.back();
    int64_t sum = 0;
    for (auto v : samples) sum += v;
    s.avgNs = sum / static_cast<int64_t>(samples.size());
    const size_t p50i = samples.size() / 2;
    const size_t p99i = (samples.size() * 99) / 100;
    s.p50Ns = samples[p50i];
    s.p99Ns = samples[std::min(p99i, samples.size() - 1)];
    return s;
}

// ---------------------------------------------------------------------------
// Scenario A — Request perftest (5 × 500 × 512 B via vecRequest)
// ---------------------------------------------------------------------------

static int runRequestScenario() {
    Benchlib lib;
    auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "FATAL: createContext failed: %s\n",
                     cr.error().c_str());
        return 1;
    }

    // Fixed 512 B payload (128 × int32). Each worker uses an identical
    // local copy so we don't measure shared-vector contention.
    std::vector<int32_t> payload(kVecElements);
    for (int i = 0; i < kVecElements; ++i) payload[i] = i;

    std::vector<std::vector<int64_t>> perThreadLat(kWorkerThreads);
    std::atomic<int64_t> failures{0};

    const auto t0 = sclock::now();

    std::vector<std::thread> workers;
    workers.reserve(kWorkerThreads);
    for (int tid = 0; tid < kWorkerThreads; ++tid) {
        workers.emplace_back([&, tid]() {
            std::vector<int64_t>& lat = perThreadLat[tid];
            lat.reserve(kOpsPerThread);
            std::vector<int32_t> myPayload = payload;
            for (int i = 0; i < kOpsPerThread; ++i) {
                const auto callStart = sclock::now();
                auto r = lib.vecRequest(myPayload);
                const auto callEnd = sclock::now();
                if (!r.isOk()) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }
                if (r->length != kVecElements) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }
                lat.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                  callEnd - callStart)
                                  .count());
            }
        });
    }
    for (auto& w : workers) w.join();
    const auto t1 = sclock::now();

    const int64_t wallNs =
        std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    const int64_t fail = failures.load();
    const int64_t ok = static_cast<int64_t>(kTotalOps) - fail;

    std::vector<int64_t> all;
    all.reserve(static_cast<size_t>(kTotalOps));
    for (auto& v : perThreadLat) all.insert(all.end(), v.begin(), v.end());
    auto stats = summarize(all);

    char rateBuf[64], wallBuf[64], avgBuf[64], minBuf[64], maxBuf[64],
        p50Buf[64], p99Buf[64];
    fmtRate(rateBuf, sizeof(rateBuf), ok, wallNs, "req");
    fmtNs(wallBuf, sizeof(wallBuf), wallNs);
    fmtNs(avgBuf, sizeof(avgBuf), stats.avgNs);
    fmtNs(minBuf, sizeof(minBuf), stats.minNs);
    fmtNs(maxBuf, sizeof(maxBuf), stats.maxNs);
    fmtNs(p50Buf, sizeof(p50Buf), stats.p50Ns);
    fmtNs(p99Buf, sizeof(p99Buf), stats.p99Ns);

    std::printf("\n");
    std::printf("  ┌─── FFI Request Path (C++) ───────────────────────────\n");
    std::printf("  │ Workers        : %d threads × %d ops = %d total\n",
                kWorkerThreads, kOpsPerThread, kTotalOps);
    std::printf("  │ Payload        : %d bytes (%d × int32)\n",
                kPayloadBytes, kVecElements);
    std::printf("  │ Successful     : %" PRId64 " / %d (%" PRId64 " failed)\n",
                ok, kTotalOps, fail);
    std::printf("  │ Wall-clock     : %s\n", wallBuf);
    std::printf("  │ Throughput     : %s\n", rateBuf);
    std::printf("  │ Avg latency    : %s\n", avgBuf);
    std::printf("  │ Min latency    : %s\n", minBuf);
    std::printf("  │ p50 latency    : %s\n", p50Buf);
    std::printf("  │ p99 latency    : %s\n", p99Buf);
    std::printf("  │ Max latency    : %s\n", maxBuf);
    std::printf("  └──────────────────────────────────────────────────────\n");

    // CSV row: scenario,ok,fail,wall_ns,avg_ns,min_ns,p50_ns,p99_ns,max_ns
    std::printf("csv,perftest_ffi,request,%" PRId64 ",%" PRId64
                ",%" PRId64 ",%" PRId64 ",%" PRId64 ",%" PRId64
                ",%" PRId64 ",%" PRId64 "\n",
                ok, fail, wallNs, stats.avgNs, stats.minNs, stats.p50Ns,
                stats.p99Ns, stats.maxNs);

    lib.shutdown();
    return fail == 0 ? 0 : 2;
}

// ---------------------------------------------------------------------------
// Scenario B — Event perftest (5 × 500 emits × 512 B via PingPayloadEvent)
// ---------------------------------------------------------------------------

static int runEventScenario() {
    Benchlib lib;
    auto cr = lib.createContext();
    if (!cr.isOk()) {
        std::fprintf(stderr, "FATAL: createContext failed: %s\n",
                     cr.error().c_str());
        return 1;
    }

    // Latency samples: callback writes to a per-event slot.  Total expected
    // event count = kTotalOps (1 emit per triggerPingPayloadRequest call).
    std::vector<int64_t> latencies;
    latencies.reserve(static_cast<size_t>(kTotalOps));
    std::mutex latMu;
    std::atomic<int64_t> delivered{0};

    auto cbHandle = lib.onPingPayloadEvent(
        [&](Benchlib&, int64_t /*seqNo*/, int64_t emitTimestampNs,
            std::span<const uint8_t> /*bytes*/) noexcept {
            // The Nim provider stamps `emitTimestampNs` from getMonoTime();
            // POSIX clock_gettime(CLOCK_MONOTONIC) and Apple mach_absolute_time
            // both back this. C++ steady_clock is the same domain on
            // glibc / libc++ on the targets we care about, so the delta is
            // a meaningful per-event delivery latency.
            const auto now = std::chrono::steady_clock::now().time_since_epoch();
            const int64_t nowNs =
                std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();
            const int64_t lat = nowNs - emitTimestampNs;
            {
                std::lock_guard<std::mutex> g(latMu);
                latencies.push_back(lat);
            }
            delivered.fetch_add(1, std::memory_order_relaxed);
        });
    if (cbHandle == 0) {
        std::fprintf(stderr, "FATAL: onPingPayloadEvent failed to register\n");
        lib.shutdown();
        return 1;
    }

    std::atomic<int64_t> failures{0};
    const auto t0 = sclock::now();

    std::vector<std::thread> workers;
    workers.reserve(kWorkerThreads);
    for (int tid = 0; tid < kWorkerThreads; ++tid) {
        workers.emplace_back([&]() {
            for (int i = 0; i < kOpsPerThread; ++i) {
                // Capture the emit timestamp in our own clock domain so
                // the callback's latency math stays inside a single
                // clock (steady_clock).  Nim provider passes it through
                // verbatim.
                const auto stampNs =
                    std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now().time_since_epoch())
                        .count();
                auto r = lib.triggerPingPayloadRequest(1, kPayloadBytes,
                                                       stampNs);
                if (!r.isOk() || r->emitted != 1) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }
    for (auto& w : workers) w.join();
    const auto tEmitDone = sclock::now();

    // Wait for the courier + foreign callback to drain.  5 s ceiling matches
    // the Nim-side perftest's tolerance for slow delivery on debug builds.
    constexpr auto kDrainTimeout = std::chrono::seconds(5);
    const auto drainDeadline = sclock::now() + kDrainTimeout;
    while (delivered.load(std::memory_order_relaxed) < kTotalOps &&
           sclock::now() < drainDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    const auto t1 = sclock::now();

    lib.offPingPayloadEvent(cbHandle);

    const int64_t emitNs =
        std::chrono::duration_cast<std::chrono::nanoseconds>(tEmitDone - t0)
            .count();
    const int64_t wallNs =
        std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    const int64_t fail = failures.load();
    const int64_t got = delivered.load();
    const int64_t dropped = static_cast<int64_t>(kTotalOps) - got;

    std::vector<int64_t> snap;
    {
        std::lock_guard<std::mutex> g(latMu);
        snap = std::move(latencies);
    }
    auto stats = summarize(snap);

    char emitRateBuf[64], deliveryRateBuf[64], emitWindowBuf[64], wallBuf[64];
    char avgBuf[64], minBuf[64], maxBuf[64], p50Buf[64], p99Buf[64];
    fmtRate(emitRateBuf, sizeof(emitRateBuf),
            static_cast<int64_t>(kTotalOps) - fail, emitNs, "evt");
    fmtRate(deliveryRateBuf, sizeof(deliveryRateBuf), got, wallNs, "evt");
    fmtNs(emitWindowBuf, sizeof(emitWindowBuf), emitNs);
    fmtNs(wallBuf, sizeof(wallBuf), wallNs);
    fmtNs(avgBuf, sizeof(avgBuf), stats.avgNs);
    fmtNs(minBuf, sizeof(minBuf), stats.minNs);
    fmtNs(maxBuf, sizeof(maxBuf), stats.maxNs);
    fmtNs(p50Buf, sizeof(p50Buf), stats.p50Ns);
    fmtNs(p99Buf, sizeof(p99Buf), stats.p99Ns);

    std::printf("\n");
    std::printf("  ┌─── FFI Event Path (C++) ─────────────────────────────\n");
    std::printf("  │ Workers        : %d trigger-threads × %d emits = %d\n",
                kWorkerThreads, kOpsPerThread, kTotalOps);
    std::printf("  │ Payload        : %d bytes\n", kPayloadBytes);
    std::printf("  │ Emitted        : %d (%" PRId64 " trigger failures)\n",
                static_cast<int>(kTotalOps - fail), fail);
    std::printf("  │ Delivered      : %" PRId64 " / %d (%" PRId64 " dropped)\n",
                got, kTotalOps, dropped);
    std::printf("  │ Emit window    : %s\n", emitWindowBuf);
    std::printf("  │ Total wall     : %s\n", wallBuf);
    std::printf("  │ Emit rate      : %s (offered)\n", emitRateBuf);
    std::printf("  │ Delivery rate  : %s (received)\n", deliveryRateBuf);
    std::printf("  │ Avg latency    : %s\n", avgBuf);
    std::printf("  │ Min latency    : %s\n", minBuf);
    std::printf("  │ p50 latency    : %s\n", p50Buf);
    std::printf("  │ p99 latency    : %s\n", p99Buf);
    std::printf("  │ Max latency    : %s\n", maxBuf);
    std::printf("  └──────────────────────────────────────────────────────\n");

    std::printf("csv,perftest_ffi,event,%" PRId64 ",%" PRId64
                ",%" PRId64 ",%" PRId64 ",%" PRId64 ",%" PRId64
                ",%" PRId64 ",%" PRId64 ",%" PRId64 ",%" PRId64 "\n",
                static_cast<int64_t>(kTotalOps) - fail, got, dropped, wallNs,
                stats.avgNs, stats.minNs, stats.p50Ns, stats.p99Ns,
                stats.maxNs, emitNs);

    lib.shutdown();
    // Fail the run on dropped events or trigger failures — these signal a
    // real regression (courier overflow, listener registration race, etc.)
    // rather than a slow run.
    return (fail == 0 && dropped == 0) ? 0 : 2;
}

int main() {
    std::printf("FFI perftest from C++ — benchlib via CBOR\n");
    std::printf("  Workload: %d threads × %d ops × %d B payload\n",
                kWorkerThreads, kOpsPerThread, kPayloadBytes);

    int rc = 0;
    rc |= runRequestScenario();
    rc |= runEventScenario();
    return rc;
}
