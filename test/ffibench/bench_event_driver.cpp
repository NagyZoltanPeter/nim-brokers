/*
 * bench_event_driver.cpp — Part D-6 event-dispatch microbenchmark driver.
 * See doc/CBOR_Round2_PartD_EventCourier.md §11 (D-6) and the captured
 * numbers in doc/bench_baseline.md.
 *
 * Four scenarios on a single EventBroker(API) (`PingEvent`):
 *
 *   (a) no_foreign_no_nim        — atomic-counter fast-path
 *   (b) one_foreign              — full courier path × 1 callback
 *   (c) many_foreign             — full courier path × M callbacks
 *                                  (encode amortized over fan-out)
 *   (d) nim_only_same_thread     — Lane 1 cost in isolation
 *
 * Each scenario does N_EMITS_PER_RUN emits via a single
 * `triggerEmitRequest(N)` call, then waits until every audience has
 * received N events. Total wall-clock time / N gives `ns_per_emit`.
 *
 * Output is CSV on stdout: scenario,audience_size,n_emits,ns_per_emit
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

#include "benchlib.hpp"

using namespace benchlib;
using sclock = std::chrono::steady_clock;

namespace {

constexpr int N_EMITS_PER_RUN  = 20000;
constexpr int REPS_PER_SCENARIO = 3;
constexpr int MAX_WAIT_MS      = 30000;

// Many-foreign fan-out width.
constexpr int M_FOREIGN = 8;
// Same-thread Nim audience width for scenario (d).
constexpr int K_NIM_SAME = 4;

// Returns ns per emit for a single (already-set-up) run.
double measureOneRun(Benchlib& lib,
                     const int n_emits,
                     std::vector<std::atomic<int64_t>>* foreignCounts,
                     bool expectNim,
                     int64_t nimBaselineSame,
                     int kNimSame) {
    // Snapshot pre-run nim counters via the stats RPC.
    int64_t targetSame = nimBaselineSame + int64_t(kNimSame) * int64_t(n_emits);

    // Reset foreign counters in-place.
    if (foreignCounts) {
        for (auto& c : *foreignCounts) c.store(0, std::memory_order_relaxed);
    }

    const auto t0 = sclock::now();
    const auto emit = lib.triggerEmitRequest(n_emits);
    if (!emit.isOk() || emit->emitted != n_emits) {
        std::fprintf(stderr, "FATAL: triggerEmitRequest failed\n");
        std::exit(2);
    }

    // Wait until every audience has received n_emits events. Sleep
    // briefly between probes to avoid burning CPU on the call thread
    // (which would steal cycles from the delivery thread doing fan-out).
    bool done = false;
    while (!done) {
        done = true;

        if (foreignCounts) {
            for (auto& c : *foreignCounts) {
                if (c.load(std::memory_order_relaxed) < int64_t(n_emits)) {
                    done = false;
                    break;
                }
            }
        }
        if (done && expectNim) {
            const auto st = lib.getStatsRequest();
            if (!st.isOk() || st->sameThreadCount < targetSame) {
                done = false;
            }
        }
        if (!done) {
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                sclock::now() - t0).count();
            if (ms >= MAX_WAIT_MS) {
                std::fprintf(stderr,
                             "FATAL: audience did not settle within %d ms\n",
                             MAX_WAIT_MS);
                std::exit(2);
            }
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        }
    }
    const auto t1 = sclock::now();
    return std::chrono::duration<double, std::nano>(t1 - t0).count()
           / double(n_emits);
}

double medianOf(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

}  // namespace

int main() {
    std::printf("scenario,audience_size,n_emits,ns_per_emit\n");

    // -------- (a) no_foreign_no_nim --------
    {
        Benchlib lib;
        if (!lib.createContext().isOk()) {
            std::fprintf(stderr, "createContext (a) failed\n");
            return 1;
        }
        std::vector<double> samples;
        for (int rep = 0; rep < REPS_PER_SCENARIO; ++rep) {
            samples.push_back(measureOneRun(
                lib, N_EMITS_PER_RUN, /*foreignCounts*/ nullptr,
                /*expectNim*/ false, /*nimBaselineSame*/ 0,
                /*kNimSame*/ 0));
        }
        std::printf("no_foreign_no_nim,0,%d,%.1f\n",
                    N_EMITS_PER_RUN, medianOf(samples));
    }

    // -------- (b) one_foreign --------
    {
        Benchlib lib;
        if (!lib.createContext().isOk()) {
            std::fprintf(stderr, "createContext (b) failed\n");
            return 1;
        }
        std::vector<std::atomic<int64_t>> counts(1);
        counts[0].store(0);
        const auto handle = lib.onPingEvent(
            [&counts](Benchlib&, int64_t) {
                counts[0].fetch_add(1, std::memory_order_relaxed);
            });
        std::vector<double> samples;
        for (int rep = 0; rep < REPS_PER_SCENARIO; ++rep) {
            samples.push_back(measureOneRun(
                lib, N_EMITS_PER_RUN, &counts,
                /*expectNim*/ false, 0, 0));
        }
        std::printf("one_foreign,1,%d,%.1f\n",
                    N_EMITS_PER_RUN, medianOf(samples));
        lib.offPingEvent(handle);
    }

    // -------- (c) many_foreign --------
    {
        Benchlib lib;
        if (!lib.createContext().isOk()) {
            std::fprintf(stderr, "createContext (c) failed\n");
            return 1;
        }
        std::vector<std::atomic<int64_t>> counts(M_FOREIGN);
        std::vector<uint64_t> handles;
        handles.reserve(M_FOREIGN);
        for (int i = 0; i < M_FOREIGN; ++i) {
            counts[i].store(0);
            auto* cnt = &counts[i];
            handles.push_back(lib.onPingEvent(
                [cnt](Benchlib&, int64_t) {
                    cnt->fetch_add(1, std::memory_order_relaxed);
                }));
        }
        std::vector<double> samples;
        for (int rep = 0; rep < REPS_PER_SCENARIO; ++rep) {
            samples.push_back(measureOneRun(
                lib, N_EMITS_PER_RUN, &counts,
                /*expectNim*/ false, 0, 0));
        }
        std::printf("many_foreign,%d,%d,%.1f\n",
                    M_FOREIGN, N_EMITS_PER_RUN, medianOf(samples));
        for (auto h : handles) lib.offPingEvent(h);
    }

    // -------- (d) nim_only_same_thread --------
    {
        Benchlib lib;
        if (!lib.createContext().isOk()) {
            std::fprintf(stderr, "createContext (d) failed\n");
            return 1;
        }
        const auto inst =
            lib.installSameThreadNimListenersRequest(K_NIM_SAME);
        if (!inst.isOk() || inst->installed != K_NIM_SAME) {
            std::fprintf(stderr, "installSameThread (d) failed\n");
            return 1;
        }
        // Snapshot the baseline (counter is process-global and survives
        // across createContext cycles within one driver run).
        int64_t baselineSame = 0;
        const auto st0 = lib.getStatsRequest();
        if (st0.isOk()) baselineSame = st0->sameThreadCount;

        std::vector<double> samples;
        for (int rep = 0; rep < REPS_PER_SCENARIO; ++rep) {
            const double ns = measureOneRun(
                lib, N_EMITS_PER_RUN, /*foreignCounts*/ nullptr,
                /*expectNim*/ true, baselineSame, K_NIM_SAME);
            samples.push_back(ns);
            baselineSame += int64_t(K_NIM_SAME) * int64_t(N_EMITS_PER_RUN);
        }
        std::printf("nim_only_same_thread,%d,%d,%.1f\n",
                    K_NIM_SAME, N_EMITS_PER_RUN, medianOf(samples));
    }

    return 0;
}
