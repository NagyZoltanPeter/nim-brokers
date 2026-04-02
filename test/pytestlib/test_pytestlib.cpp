/**
 * test_pytestlib.cpp
 * ==================
 * C++ port of test_pytestlib.py — covers every Nim→C→C++ type mapping
 * through the generated C++ wrapper (pytestlib.hpp).
 *
 * Type mapping coverage:
 *   Scalars:    bool, int32, int64, float64, string
 *   Enum:       Priority
 *   Distinct:   JobId (int32), Timestamp (int64)
 *   seq result: seq[byte], seq[string], seq[int64], seq[Tag]
 *   seq params: seq[Tag], seq[string], seq[int64]
 *   array:      array[4, int32]
 *   Events:     all of the above in callback fields
 *
 * Build (from repo root):
 *   nimble buildPyTestLib
 *   (cmake step handled by  nimble testFfiApiCpp)
 */

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "pytestlib.hpp"

using namespace pytestlib;

// ============================================================================
// Minimal test framework
// ============================================================================

static int gTotal = 0;
static int gFailed = 0;
static bool gCurrentFailed = false;
static const char* gCurrentTest = nullptr;

static void checkImpl(
    const char* file, int line, const char* expr, bool ok
) {
    if (!ok) {
        fprintf(stderr, "  FAIL %s:%d: %s\n", file, line, expr);
        gCurrentFailed = true;
    }
}

#define CHECK(expr) checkImpl(__FILE__, __LINE__, #expr, static_cast<bool>(expr))

#define CHECK_EQ(a, b)                                                            \
    do {                                                                          \
        auto _a = (a);                                                            \
        auto _b = (b);                                                            \
        if (!(_a == _b)) {                                                        \
            fprintf(stderr, "  FAIL %s:%d: %s == %s\n", __FILE__, __LINE__, #a, #b); \
            gCurrentFailed = true;                                                \
        }                                                                         \
    } while (0)

#define CHECK_NE(a, b)                                                            \
    do {                                                                          \
        auto _a = (a);                                                            \
        auto _b = (b);                                                            \
        if (_a == _b) {                                                           \
            fprintf(stderr, "  FAIL %s:%d: %s != %s\n", __FILE__, __LINE__, #a, #b); \
            gCurrentFailed = true;                                                \
        }                                                                         \
    } while (0)

#define CHECK_NEAR(a, b, eps)                                                        \
    do {                                                                             \
        double _a = static_cast<double>(a);                                          \
        double _b = static_cast<double>(b);                                          \
        if (std::fabs(_a - _b) > (eps)) {                                            \
            fprintf(stderr, "  FAIL %s:%d: |%s - %s| <= %g\n",                      \
                    __FILE__, __LINE__, #a, #b, static_cast<double>(eps));           \
            gCurrentFailed = true;                                                   \
        }                                                                            \
    } while (0)

static void runTest(const char* name, void (*fn)()) {
    gCurrentFailed = false;
    gCurrentTest = name;
    ++gTotal;
    printf("  %-60s", name);
    fflush(stdout);
    fn();
    if (gCurrentFailed) {
        puts("FAIL");
        ++gFailed;
    } else {
        puts("ok");
    }
}

#define RUN(fn) runTest(#fn, fn)

// ============================================================================
// Shared helpers
// ============================================================================

/// Thread-safe list for collecting asynchronous event callbacks.
template <typename T>
struct SafeList {
    void push(T v) {
        std::lock_guard<std::mutex> lk(mtx_);
        items_.push_back(std::move(v));
    }
    size_t size() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return items_.size();
    }
    T at(size_t i) const {
        std::lock_guard<std::mutex> lk(mtx_);
        return items_.at(i);
    }
    std::vector<T> snapshot() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return items_;
    }
    void clear() {
        std::lock_guard<std::mutex> lk(mtx_);
        items_.clear();
    }

private:
    std::vector<T> items_;
    mutable std::mutex mtx_;
};

/// Busy-wait until pred() returns true or timeout expires.
template <typename Pred>
static bool waitFor(Pred pred, double timeoutSec = 2.0) {
    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + std::chrono::duration<double>(timeoutSec);
    while (!pred() && clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    return pred();
}

// ============================================================================
// TestLifecycle
// ============================================================================

static void test_lifecycle_create_and_shutdown() {
    Pytestlib lib;
    CHECK(!lib.validContext());
    auto r = lib.createContext();
    CHECK(r.ok());
    CHECK(lib.validContext());
    CHECK_NE(lib.ctx(), 0u);
    lib.shutdown();
    CHECK(!lib.validContext());
}

static void test_lifecycle_raii_shutdown() {
    uint32_t savedCtx = 0;
    {
        Pytestlib lib;
        lib.createContext();
        savedCtx = lib.ctx();
        CHECK_NE(savedCtx, 0u);
        // destructor calls shutdown()
    }
    // No crash — RAII worked.
    CHECK_NE(savedCtx, 0u);
}

static void test_lifecycle_double_shutdown_is_safe() {
    Pytestlib lib;
    lib.createContext();
    lib.shutdown();
    lib.shutdown(); // must not crash
}

static void test_lifecycle_double_create_returns_error() {
    Pytestlib lib;
    auto r1 = lib.createContext();
    CHECK(r1.ok());
    auto r2 = lib.createContext();
    CHECK(!r2.ok()); // second create should fail
    lib.shutdown();
}

static void test_lifecycle_request_without_context_fails() {
    Pytestlib lib; // ctx_ == 0
    auto r = lib.echoRequest("hello");
    CHECK(!r.ok());
}

// ============================================================================
// TestRequests
// ============================================================================

static void test_requests_initialize() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.initializeRequest("test-label");
    CHECK(r.ok());
    CHECK_EQ(r->label, std::string("test-label"));
    lib.shutdown();
}

static void test_requests_echo() {
    Pytestlib lib;
    lib.createContext();
    lib.initializeRequest("ctx-A");
    auto r = lib.echoRequest("hello");
    CHECK(r.ok());
    CHECK_EQ(r->reply, std::string("ctx-A:hello"));
    lib.shutdown();
}

static void test_requests_counter_increments() {
    Pytestlib lib;
    lib.createContext();
    for (int32_t expected = 1; expected <= 3; ++expected) {
        auto r = lib.counterRequest();
        CHECK(r.ok());
        CHECK_EQ(r->value, expected);
    }
    lib.shutdown();
}

static void test_requests_multiple_echo() {
    Pytestlib lib;
    lib.createContext();
    lib.initializeRequest("multi");
    for (int i = 0; i < 5; ++i) {
        auto r = lib.echoRequest("msg-" + std::to_string(i));
        CHECK(r.ok());
        CHECK_EQ(r->reply, "multi:msg-" + std::to_string(i));
    }
    lib.shutdown();
}

// ============================================================================
// TestEvents
// ============================================================================

static void test_events_counter_changed() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::pair<uint32_t, int32_t>> received;
    auto h = lib.onCounterChanged([&received, &lib](Pytestlib& owner, int32_t v) {
        received.push({owner.ctx(), v});
    });
    CHECK_NE(h, 0ull);

    lib.counterRequest();
    lib.counterRequest();
    lib.counterRequest();
    waitFor([&] { return received.size() >= 3; });

    CHECK_EQ(received.size(), 3u);
    auto snap = received.snapshot();
    for (size_t i = 0; i < snap.size(); ++i)
        CHECK_EQ(snap[i].second, static_cast<int32_t>(i + 1));
    for (auto& [ctx, _] : snap)
        CHECK_EQ(ctx, lib.ctx());

    lib.offCounterChanged(h);
    lib.shutdown();
}

static void test_events_off_stops_delivery() {
    Pytestlib lib;
    lib.createContext();

    SafeList<int32_t> received;
    auto h = lib.onCounterChanged([&received](Pytestlib&, int32_t v) {
        received.push(v);
    });

    lib.counterRequest();
    waitFor([&] { return received.size() >= 1; });

    lib.offCounterChanged(h);
    size_t countAfterOff = received.size();

    lib.counterRequest();
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    CHECK_EQ(received.size(), countAfterOff);

    lib.shutdown();
}

// ============================================================================
// TestContextSeparation
// ============================================================================

static void sleepMs(int ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

static void test_context_independent_counters() {
    Pytestlib lib1, lib2;
    lib1.createContext();
    lib2.createContext();
    CHECK_NE(lib1.ctx(), lib2.ctx());

    lib1.initializeRequest("alpha");
    lib2.initializeRequest("beta");

    for (int32_t i = 1; i <= 3; ++i)
        CHECK_EQ(lib1.counterRequest()->value, i);
    for (int32_t i = 1; i <= 2; ++i)
        CHECK_EQ(lib2.counterRequest()->value, i);
    CHECK_EQ(lib1.counterRequest()->value, 4);

    lib1.shutdown();
    lib2.shutdown();
    sleepMs(50);
}

static void test_context_independent_echo() {
    Pytestlib lib1, lib2;
    lib1.createContext();
    lib2.createContext();

    lib1.initializeRequest("one");
    lib2.initializeRequest("two");

    CHECK_EQ(lib1.echoRequest("x")->reply, std::string("one:x"));
    CHECK_EQ(lib2.echoRequest("x")->reply, std::string("two:x"));

    lib1.shutdown();
    lib2.shutdown();
    sleepMs(50);
}

static void test_context_independent_events() {
    SafeList<int32_t> events1, events2;
    Pytestlib lib1, lib2;
    lib1.createContext();
    lib2.createContext();

    auto h1 =
        lib1.onCounterChanged([&events1](Pytestlib&, int32_t v) { events1.push(v); });
    auto h2 =
        lib2.onCounterChanged([&events2](Pytestlib&, int32_t v) { events2.push(v); });

    lib1.counterRequest();
    lib1.counterRequest();
    lib2.counterRequest();

    waitFor([&] { return events1.size() >= 2 && events2.size() >= 1; });

    auto snap1 = events1.snapshot();
    auto snap2 = events2.snapshot();
    CHECK_EQ(snap1.size(), 2u);
    CHECK_EQ(snap2.size(), 1u);
    CHECK_EQ(snap1[0], 1);
    CHECK_EQ(snap1[1], 2);
    CHECK_EQ(snap2[0], 1);

    lib1.offCounterChanged(h1);
    lib2.offCounterChanged(h2);
    lib1.shutdown();
    lib2.shutdown();
    sleepMs(50);
}

static void test_context_shutdown_one_does_not_affect_other() {
    Pytestlib lib1, lib2;
    lib1.createContext();
    lib2.createContext();

    lib1.initializeRequest("first");
    lib2.initializeRequest("second");

    lib1.shutdown();

    auto r = lib2.echoRequest("still-alive");
    CHECK(r.ok());
    CHECK_EQ(r->reply, std::string("second:still-alive"));

    lib2.shutdown();
    sleepMs(50);
}

// ============================================================================
// TestScalarTypes
// ============================================================================

static void test_scalar_bool_true() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primScalarRequest(true, 0, 0, 0.0);
    CHECK(r.ok());
    CHECK(r->flag == true);
    lib.shutdown();
}

static void test_scalar_bool_false() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primScalarRequest(false, 0, 0, 0.0);
    CHECK(r.ok());
    CHECK(r->flag == false);
    lib.shutdown();
}

static void test_scalar_int32_roundtrip() {
    Pytestlib lib;
    lib.createContext();

    auto r1 = lib.primScalarRequest(false, INT32_MIN, 0, 0.0);
    CHECK(r1.ok());
    CHECK_EQ(r1->i32, INT32_MIN);

    auto r2 = lib.primScalarRequest(false, INT32_MAX, 0, 0.0);
    CHECK(r2.ok());
    CHECK_EQ(r2->i32, INT32_MAX);

    lib.shutdown();
}

static void test_scalar_int64_roundtrip() {
    Pytestlib lib;
    lib.createContext();
    int64_t big = 9'000'000'000'000LL;
    auto r = lib.primScalarRequest(false, 0, big, 0.0);
    CHECK(r.ok());
    CHECK_EQ(r->i64, big);
    lib.shutdown();
}

static void test_scalar_float64_roundtrip() {
    Pytestlib lib;
    lib.createContext();
    double pi = 3.141592653589793;
    auto r = lib.primScalarRequest(false, 0, 0, pi);
    CHECK(r.ok());
    CHECK_NEAR(r->f64, pi, 1e-12);
    lib.shutdown();
}

static void test_scalar_all_fields_roundtrip() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primScalarRequest(true, 42, 1'000'000'000LL, 2.718);
    CHECK(r.ok());
    CHECK(r->flag == true);
    CHECK_EQ(r->i32, 42);
    CHECK_EQ(r->i64, 1'000'000'000LL);
    CHECK_NEAR(r->f64, 2.718, 1e-12);
    lib.shutdown();
}

static void test_scalar_prim_scalar_event() {
    Pytestlib lib;
    lib.createContext();

    struct Evt { bool flag; int32_t i32; int64_t i64; double f64; };
    SafeList<Evt> evts;
    auto h = lib.onPrimScalarEvent(
        [&evts](Pytestlib&, bool flag, int32_t i32, int64_t i64, double f64) {
            evts.push({flag, i32, i64, f64});
        });

    lib.primScalarRequest(true, 7, 777777LL, 1.5);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto e = evts.at(0);
    CHECK(e.flag == true);
    CHECK_EQ(e.i32, 7);
    CHECK_EQ(e.i64, 777777LL);
    CHECK_NEAR(e.f64, 1.5, 1e-12);

    lib.offPrimScalarEvent(h);
    lib.shutdown();
}

static void test_scalar_prim_scalar_event_false_flag() {
    Pytestlib lib;
    lib.createContext();

    SafeList<bool> evts;
    auto h = lib.onPrimScalarEvent(
        [&evts](Pytestlib&, bool flag, int32_t, int64_t, double) {
            evts.push(flag);
        });

    lib.primScalarRequest(false, 0, 0, 0.0);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    CHECK(evts.at(0) == false);

    lib.offPrimScalarEvent(h);
    lib.shutdown();
}

// ============================================================================
// TestEnumDistinctTypes
// ============================================================================

static void test_enum_roundtrip_low() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(PRIORITY_P_LOW, 10);
    CHECK(r.ok());
    CHECK_EQ(r->priority, PRIORITY_P_LOW);
    CHECK_EQ(static_cast<int>(r->priority), 0);
    lib.shutdown();
}

static void test_enum_roundtrip_high() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(PRIORITY_P_HIGH, 1);
    CHECK(r.ok());
    CHECK_EQ(r->priority, PRIORITY_P_HIGH);
    CHECK_EQ(static_cast<int>(r->priority), 2);
    lib.shutdown();
}

static void test_enum_roundtrip_critical() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(PRIORITY_P_CRITICAL, 1);
    CHECK(r.ok());
    CHECK_EQ(static_cast<int>(r->priority), 3);
    lib.shutdown();
}

static void test_distinct_jobid_echoed() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(PRIORITY_P_LOW, 5);
    CHECK(r.ok());
    CHECK_EQ(r->jobId, 5);
    lib.shutdown();
}

static void test_distinct_jobid_next() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(PRIORITY_P_LOW, 5);
    CHECK(r.ok());
    CHECK_EQ(r->nextId, 6); // nextId = jobId + 1
    lib.shutdown();
}

static void test_distinct_jobid_zero() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(PRIORITY_P_MEDIUM, 0);
    CHECK(r.ok());
    CHECK_EQ(r->jobId, 0);
    CHECK_EQ(r->nextId, 1);
    lib.shutdown();
}

static void test_all_priority_values() {
    Pytestlib lib;
    lib.createContext();
    Priority priorities[] = {
        PRIORITY_P_LOW, PRIORITY_P_MEDIUM, PRIORITY_P_HIGH, PRIORITY_P_CRITICAL
    };
    for (auto p : priorities) {
        auto r = lib.typedScalarRequest(p, 1);
        CHECK(r.ok());
        CHECK_EQ(r->priority, p);
    }
    lib.shutdown();
}

static void test_typed_scalar_event_enum() {
    Pytestlib lib;
    lib.createContext();

    struct Evt { Priority priority; int32_t jobId; int64_t ts; };
    SafeList<Evt> evts;
    auto h = lib.onTypedScalarEvent(
        [&evts](Pytestlib&, Priority p, int32_t jid, int64_t ts) {
            evts.push({p, jid, ts});
        });

    lib.typedScalarRequest(PRIORITY_P_HIGH, 7);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto e = evts.at(0);
    CHECK_EQ(e.priority, PRIORITY_P_HIGH);
    CHECK_EQ(static_cast<int>(e.priority), 2);
    CHECK_EQ(e.jobId, 7);
    CHECK_EQ(e.ts, 70LL); // ts = jobId * 10

    lib.offTypedScalarEvent(h);
    lib.shutdown();
}

static void test_typed_scalar_event_distinct_timestamp() {
    Pytestlib lib;
    lib.createContext();

    SafeList<int64_t> evts;
    auto h = lib.onTypedScalarEvent(
        [&evts](Pytestlib&, Priority, int32_t, int64_t ts) { evts.push(ts); });

    lib.typedScalarRequest(PRIORITY_P_LOW, 3);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    CHECK_EQ(evts.at(0), 30LL); // ts = jobId * 10 = 3 * 10

    lib.offTypedScalarEvent(h);
    lib.shutdown();
}

static void test_fixedarray_result_contains_timestamp() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(99);
    CHECK(r.ok());
    CHECK_EQ(r->ts, 99LL); // ts = Timestamp(seed)
    lib.shutdown();
}

// ============================================================================
// TestSeqByteResult
// ============================================================================

static void test_seq_byte_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(0);
    CHECK(r.ok());
    CHECK(r->data.empty());
    lib.shutdown();
}

static void test_seq_byte_length() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(8);
    CHECK(r.ok());
    CHECK_EQ(r->data.size(), 8u);
    lib.shutdown();
}

static void test_seq_byte_values() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(5);
    CHECK(r.ok());
    CHECK_EQ(r->data.size(), 5u);
    for (size_t i = 0; i < r->data.size(); ++i)
        CHECK_EQ(r->data[i], static_cast<uint8_t>(i));
    lib.shutdown();
}

static void test_seq_byte_wrap_around() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(260);
    CHECK(r.ok());
    CHECK_EQ(r->data.size(), 260u);
    CHECK_EQ(r->data[0], 0u);
    CHECK_EQ(r->data[255], 255u);
    CHECK_EQ(r->data[256], 0u); // wraps at 256
    lib.shutdown();
}

static void test_seq_byte_single_element() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(1);
    CHECK(r.ok());
    CHECK_EQ(r->data.size(), 1u);
    CHECK_EQ(r->data[0], 0u);
    lib.shutdown();
}

static void test_seq_byte_large() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(100);
    CHECK(r.ok());
    CHECK_EQ(r->data.size(), 100u);
    for (size_t i = 0; i < r->data.size(); ++i)
        CHECK_EQ(r->data[i], static_cast<uint8_t>(i % 256));
    lib.shutdown();
}

// ============================================================================
// TestSeqStringTypes
// ============================================================================

static void test_seq_string_result_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("x", 0);
    CHECK(r.ok());
    CHECK(r->items.empty());
    lib.shutdown();
}

static void test_seq_string_result_count() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("item", 4);
    CHECK(r.ok());
    CHECK_EQ(r->items.size(), 4u);
    lib.shutdown();
}

static void test_seq_string_result_values() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("tag", 3);
    CHECK(r.ok());
    CHECK_EQ(r->items.size(), 3u);
    CHECK_EQ(r->items[0], std::string("tag-0"));
    CHECK_EQ(r->items[1], std::string("tag-1"));
    CHECK_EQ(r->items[2], std::string("tag-2"));
    lib.shutdown();
}

static void test_seq_string_result_special_chars() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("a/b:c", 2);
    CHECK(r.ok());
    CHECK_EQ(r->items.size(), 2u);
    CHECK_EQ(r->items[0], std::string("a/b:c-0"));
    CHECK_EQ(r->items[1], std::string("a/b:c-1"));
    lib.shutdown();
}

static void test_seq_string_param_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({});
    CHECK(r.ok());
    CHECK_EQ(r->count, 0);
    CHECK_EQ(r->joined, std::string(""));
    lib.shutdown();
}

static void test_seq_string_param_single() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({"hello"});
    CHECK(r.ok());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->joined, std::string("hello"));
    lib.shutdown();
}

static void test_seq_string_param_multiple() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({"alpha", "beta", "gamma"});
    CHECK(r.ok());
    CHECK_EQ(r->count, 3);
    CHECK_EQ(r->joined, std::string("alpha,beta,gamma"));
    lib.shutdown();
}

static void test_seq_string_param_unicode() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({"héllo", "wörld"});
    CHECK(r.ok());
    CHECK_EQ(r->count, 2);
    CHECK_EQ(r->joined, std::string("héllo,wörld"));
    lib.shutdown();
}

static void test_string_seq_event() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<std::string>> evts;
    auto h = lib.onStringSeqEvent(
        [&evts](Pytestlib&, std::span<const char*> items) {
            std::vector<std::string> v;
            for (const char* s : items)
                v.emplace_back(s ? s : "");
            evts.push(std::move(v));
        });

    lib.stringSeqRequest("ev", 3);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto snap = evts.at(0);
    CHECK_EQ(snap.size(), 3u);
    CHECK_EQ(snap[0], std::string("ev-0"));
    CHECK_EQ(snap[1], std::string("ev-1"));
    CHECK_EQ(snap[2], std::string("ev-2"));

    lib.offStringSeqEvent(h);
    lib.shutdown();
}

static void test_string_seq_event_empty() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<std::string>> evts;
    auto h = lib.onStringSeqEvent(
        [&evts](Pytestlib&, std::span<const char*> items) {
            evts.push(std::vector<std::string>(items.begin(), items.end()));
        });

    lib.stringSeqRequest("x", 0);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    CHECK(evts.at(0).empty());

    lib.offStringSeqEvent(h);
    lib.shutdown();
}

// ============================================================================
// TestSeqPrimTypes
// ============================================================================

static void test_prim_seq_result_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(0);
    CHECK(r.ok());
    CHECK(r->values.empty());
    lib.shutdown();
}

static void test_prim_seq_result_length() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(5);
    CHECK(r.ok());
    CHECK_EQ(r->values.size(), 5u);
    lib.shutdown();
}

static void test_prim_seq_result_values() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(4);
    CHECK(r.ok());
    CHECK_EQ(r->values.size(), 4u);
    for (size_t i = 0; i < r->values.size(); ++i)
        CHECK_EQ(r->values[i], static_cast<int64_t>(i) * 10LL);
    lib.shutdown();
}

static void test_prim_seq_result_large_int64() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(3);
    CHECK(r.ok());
    CHECK_EQ(r->values[2], 20LL);
    lib.shutdown();
}

static void test_prim_seq_param_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqParamRequest({});
    CHECK(r.ok());
    CHECK_EQ(r->count, 0);
    CHECK_EQ(r->total, 0LL);
    lib.shutdown();
}

static void test_prim_seq_param_single() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqParamRequest({42LL});
    CHECK(r.ok());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->total, 42LL);
    lib.shutdown();
}

static void test_prim_seq_param_sum() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.primSeqParamRequest({1LL, 2LL, 3LL, 4LL, 5LL});
    CHECK(r.ok());
    CHECK_EQ(r->count, 5);
    CHECK_EQ(r->total, 15LL);
    lib.shutdown();
}

static void test_prim_seq_param_large_values() {
    Pytestlib lib;
    lib.createContext();
    int64_t big = 1'000'000'000'000LL;
    auto r = lib.primSeqParamRequest({big, big});
    CHECK(r.ok());
    CHECK_EQ(r->count, 2);
    CHECK_EQ(r->total, 2 * big);
    lib.shutdown();
}

static void test_prim_seq_event() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<int64_t>> evts;
    auto h = lib.onPrimSeqEvent(
        [&evts](Pytestlib&, std::span<const int64_t> values) {
            evts.push(std::vector<int64_t>(values.begin(), values.end()));
        });

    lib.primSeqRequest(3);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto snap = evts.at(0);
    CHECK_EQ(snap.size(), 3u);
    CHECK_EQ(snap[0], 0LL);
    CHECK_EQ(snap[1], 10LL);
    CHECK_EQ(snap[2], 20LL);

    lib.offPrimSeqEvent(h);
    lib.shutdown();
}

static void test_prim_seq_event_empty() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<int64_t>> evts;
    auto h = lib.onPrimSeqEvent(
        [&evts](Pytestlib&, std::span<const int64_t> values) {
            evts.push(std::vector<int64_t>(values.begin(), values.end()));
        });

    lib.primSeqRequest(0);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    CHECK(evts.at(0).empty());

    lib.offPrimSeqEvent(h);
    lib.shutdown();
}

// ============================================================================
// TestFixedArrayTypes
// ============================================================================

static void test_array_result_values() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(5);
    CHECK(r.ok());
    CHECK_EQ(r->values[0], 5);
    CHECK_EQ(r->values[1], 10);
    CHECK_EQ(r->values[2], 15);
    CHECK_EQ(r->values[3], 20);
    lib.shutdown();
}

static void test_array_result_length() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(1);
    CHECK(r.ok());
    CHECK_EQ(r->values.size(), 4u);
    lib.shutdown();
}

static void test_array_result_seed_zero() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(0);
    CHECK(r.ok());
    for (auto v : r->values)
        CHECK_EQ(v, 0);
    lib.shutdown();
}

static void test_array_result_negative_seed() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(-3);
    CHECK(r.ok());
    CHECK_EQ(r->values[0], -3);
    CHECK_EQ(r->values[1], -6);
    CHECK_EQ(r->values[2], -9);
    CHECK_EQ(r->values[3], -12);
    lib.shutdown();
}

static void test_array_result_timestamp() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(42);
    CHECK(r.ok());
    CHECK_EQ(r->ts, 42LL);
    lib.shutdown();
}

static void test_fixed_array_event() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onFixedArrayEvent(
        [&evts](Pytestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.fixedArrayRequest(3);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto snap = evts.at(0);
    CHECK_EQ(snap.size(), 4u);
    CHECK_EQ(snap[0], 3);
    CHECK_EQ(snap[1], 6);
    CHECK_EQ(snap[2], 9);
    CHECK_EQ(snap[3], 12);

    lib.offFixedArrayEvent(h);
    lib.shutdown();
}

static void test_fixed_array_event_zero_seed() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onFixedArrayEvent(
        [&evts](Pytestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.fixedArrayRequest(0);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    for (auto v : evts.at(0))
        CHECK_EQ(v, 0);

    lib.offFixedArrayEvent(h);
    lib.shutdown();
}

static void test_fixed_array_multiple_requests() {
    Pytestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onFixedArrayEvent(
        [&evts](Pytestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.fixedArrayRequest(1);
    lib.fixedArrayRequest(2);
    waitFor([&] { return evts.size() >= 2; });

    CHECK_EQ(evts.size(), 2u);
    auto e0 = evts.at(0);
    auto e1 = evts.at(1);
    CHECK_EQ(e0.size(), 4u);
    CHECK_EQ(e1.size(), 4u);
    CHECK_EQ(e0[0], 1);
    CHECK_EQ(e0[1], 2);
    CHECK_EQ(e0[2], 3);
    CHECK_EQ(e0[3], 4);
    CHECK_EQ(e1[0], 2);
    CHECK_EQ(e1[1], 4);
    CHECK_EQ(e1[2], 6);
    CHECK_EQ(e1[3], 8);

    lib.offFixedArrayEvent(h);
    lib.shutdown();
}

// ============================================================================
// TestSeqObjectTypes
// ============================================================================

static void test_obj_seq_param_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.objSeqParamRequest({});
    CHECK(r.ok());
    CHECK_EQ(r->count, 0);
    CHECK_EQ(r->first, std::string(""));
    lib.shutdown();
}

static Tag makeTag(std::string key, std::string value) {
    Tag t;
    t.key = std::move(key);
    t.value = std::move(value);
    return t;
}

static void test_obj_seq_param_single() {
    Pytestlib lib;
    lib.createContext();
    std::vector<Tag> tags = {makeTag("mykey", "myval")};
    auto r = lib.objSeqParamRequest(tags);
    CHECK(r.ok());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->first, std::string("mykey"));
    lib.shutdown();
}

static void test_obj_seq_param_multiple() {
    Pytestlib lib;
    lib.createContext();
    std::vector<Tag> tags = {
        makeTag("first", "1"), makeTag("second", "2"), makeTag("third", "3")
    };
    auto r = lib.objSeqParamRequest(tags);
    CHECK(r.ok());
    CHECK_EQ(r->count, 3);
    CHECK_EQ(r->first, std::string("first"));
    lib.shutdown();
}

static void test_obj_seq_param_string_encoding() {
    Pytestlib lib;
    lib.createContext();
    std::vector<Tag> tags = {makeTag("key with spaces", "value/path")};
    auto r = lib.objSeqParamRequest(tags);
    CHECK(r.ok());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->first, std::string("key with spaces"));
    lib.shutdown();
}

static void test_obj_seq_result_empty() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(0);
    CHECK(r.ok());
    CHECK(r->tags.empty());
    lib.shutdown();
}

static void test_obj_seq_result_length() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(4);
    CHECK(r.ok());
    CHECK_EQ(r->tags.size(), 4u);
    lib.shutdown();
}

static void test_obj_seq_result_keys() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(3);
    CHECK(r.ok());
    CHECK_EQ(r->tags.size(), 3u);
    CHECK_EQ(r->tags[0].key, std::string("key-0"));
    CHECK_EQ(r->tags[1].key, std::string("key-1"));
    CHECK_EQ(r->tags[2].key, std::string("key-2"));
    lib.shutdown();
}

static void test_obj_seq_result_values() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(3);
    CHECK(r.ok());
    CHECK_EQ(r->tags[0].value, std::string("val-0"));
    CHECK_EQ(r->tags[1].value, std::string("val-1"));
    CHECK_EQ(r->tags[2].value, std::string("val-2"));
    lib.shutdown();
}

static void test_obj_seq_result_tag_fields() {
    Pytestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(2);
    CHECK(r.ok());
    for (const auto& tag : r->tags) {
        CHECK(!tag.key.empty());
        CHECK(!tag.value.empty());
    }
    lib.shutdown();
}

static void test_obj_seq_roundtrip() {
    Pytestlib lib;
    lib.createContext();
    // Generate tags via result request
    auto gen = lib.objSeqResultRequest(3);
    CHECK(gen.ok());
    // Pass them back as input param
    auto r = lib.objSeqParamRequest(gen->tags);
    CHECK(r.ok());
    CHECK_EQ(r->count, 3);
    CHECK_EQ(r->first, std::string("key-0"));
    lib.shutdown();
}

// ============================================================================
// TestMultipleEventListeners
// ============================================================================

static void test_two_scalar_event_listeners() {
    Pytestlib lib;
    lib.createContext();

    SafeList<int32_t> evts1, evts2;
    auto h1 = lib.onPrimScalarEvent(
        [&evts1](Pytestlib&, bool, int32_t i32, int64_t, double) {
            evts1.push(i32);
        });
    auto h2 = lib.onPrimScalarEvent(
        [&evts2](Pytestlib&, bool, int32_t i32, int64_t, double) {
            evts2.push(i32);
        });

    lib.primScalarRequest(false, 99, 0, 0.0);
    waitFor([&] { return evts1.size() >= 1; });
    waitFor([&] { return evts2.size() >= 1; });

    CHECK_EQ(evts1.size(), 1u);
    CHECK_EQ(evts2.size(), 1u);
    CHECK_EQ(evts1.at(0), 99);
    CHECK_EQ(evts2.at(0), 99);

    lib.offPrimScalarEvent(h1);
    lib.offPrimScalarEvent(h2);
    lib.shutdown();
}

static void test_remove_one_listener_keeps_other() {
    Pytestlib lib;
    lib.createContext();

    SafeList<int32_t> evts1, evts2;
    auto h1 = lib.onPrimScalarEvent(
        [&evts1](Pytestlib&, bool, int32_t i32, int64_t, double) {
            evts1.push(i32);
        });
    auto h2 = lib.onPrimScalarEvent(
        [&evts2](Pytestlib&, bool, int32_t i32, int64_t, double) {
            evts2.push(i32);
        });

    lib.primScalarRequest(false, 1, 0, 0.0);
    waitFor([&] { return evts1.size() >= 1; });
    waitFor([&] { return evts2.size() >= 1; });
    CHECK_EQ(evts1.size(), 1u);
    CHECK_EQ(evts2.size(), 1u);

    lib.offPrimScalarEvent(h1);

    lib.primScalarRequest(false, 2, 0, 0.0);
    waitFor([&] { return evts2.size() >= 2; });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    CHECK_EQ(evts1.size(), 1u); // h1 removed — no new events
    CHECK_EQ(evts2.size(), 2u);
    CHECK_EQ(evts2.at(1), 2);

    lib.offPrimScalarEvent(h2);
    lib.shutdown();
}

static void test_concurrent_event_types() {
    Pytestlib lib;
    lib.createContext();

    SafeList<int32_t> scalarEvts;
    SafeList<std::vector<int32_t>> arrayEvts;
    SafeList<std::vector<std::string>> stringEvts;

    auto hs = lib.onPrimScalarEvent(
        [&scalarEvts](Pytestlib&, bool, int32_t i32, int64_t, double) {
            scalarEvts.push(i32);
        });
    auto ha = lib.onFixedArrayEvent(
        [&arrayEvts](Pytestlib&, std::span<const int32_t> values) {
            arrayEvts.push(std::vector<int32_t>(values.begin(), values.end()));
        });
    auto hst = lib.onStringSeqEvent(
        [&stringEvts](Pytestlib&, std::span<const char*> items) {
            std::vector<std::string> v;
            for (const char* s : items)
                v.emplace_back(s ? s : "");
            stringEvts.push(std::move(v));
        });

    lib.primScalarRequest(false, 55, 0, 0.0);
    lib.fixedArrayRequest(4);
    lib.stringSeqRequest("z", 2);

    waitFor([&] { return scalarEvts.size() >= 1; });
    waitFor([&] { return arrayEvts.size() >= 1; });
    waitFor([&] { return stringEvts.size() >= 1; });

    CHECK_EQ(scalarEvts.size(), 1u);
    CHECK_EQ(scalarEvts.at(0), 55);

    CHECK_EQ(arrayEvts.size(), 1u);
    auto arr = arrayEvts.at(0);
    CHECK_EQ(arr.size(), 4u);
    CHECK_EQ(arr[0], 4);
    CHECK_EQ(arr[1], 8);
    CHECK_EQ(arr[2], 12);
    CHECK_EQ(arr[3], 16);

    CHECK_EQ(stringEvts.size(), 1u);
    auto strs = stringEvts.at(0);
    CHECK_EQ(strs.size(), 2u);
    CHECK_EQ(strs[0], std::string("z-0"));
    CHECK_EQ(strs[1], std::string("z-1"));

    lib.offPrimScalarEvent(hs);
    lib.offFixedArrayEvent(ha);
    lib.offStringSeqEvent(hst);
    lib.shutdown();
}

// ============================================================================
// main
// ============================================================================

int main() {
    printf("test_pytestlib — C++ type mapping coverage\n\n");

    printf("--- TestLifecycle ---\n");
    RUN(test_lifecycle_create_and_shutdown);
    RUN(test_lifecycle_raii_shutdown);
    RUN(test_lifecycle_double_shutdown_is_safe);
    RUN(test_lifecycle_double_create_returns_error);
    RUN(test_lifecycle_request_without_context_fails);

    printf("\n--- TestRequests ---\n");
    RUN(test_requests_initialize);
    RUN(test_requests_echo);
    RUN(test_requests_counter_increments);
    RUN(test_requests_multiple_echo);

    printf("\n--- TestEvents ---\n");
    RUN(test_events_counter_changed);
    RUN(test_events_off_stops_delivery);

    printf("\n--- TestContextSeparation ---\n");
    RUN(test_context_independent_counters);
    RUN(test_context_independent_echo);
    RUN(test_context_independent_events);
    RUN(test_context_shutdown_one_does_not_affect_other);

    printf("\n--- TestScalarTypes ---\n");
    RUN(test_scalar_bool_true);
    RUN(test_scalar_bool_false);
    RUN(test_scalar_int32_roundtrip);
    RUN(test_scalar_int64_roundtrip);
    RUN(test_scalar_float64_roundtrip);
    RUN(test_scalar_all_fields_roundtrip);
    RUN(test_scalar_prim_scalar_event);
    RUN(test_scalar_prim_scalar_event_false_flag);

    printf("\n--- TestEnumDistinctTypes ---\n");
    RUN(test_enum_roundtrip_low);
    RUN(test_enum_roundtrip_high);
    RUN(test_enum_roundtrip_critical);
    RUN(test_distinct_jobid_echoed);
    RUN(test_distinct_jobid_next);
    RUN(test_distinct_jobid_zero);
    RUN(test_all_priority_values);
    RUN(test_typed_scalar_event_enum);
    RUN(test_typed_scalar_event_distinct_timestamp);
    RUN(test_fixedarray_result_contains_timestamp);

    printf("\n--- TestSeqByteResult ---\n");
    RUN(test_seq_byte_empty);
    RUN(test_seq_byte_length);
    RUN(test_seq_byte_values);
    RUN(test_seq_byte_wrap_around);
    RUN(test_seq_byte_single_element);
    RUN(test_seq_byte_large);

    printf("\n--- TestSeqStringTypes ---\n");
    RUN(test_seq_string_result_empty);
    RUN(test_seq_string_result_count);
    RUN(test_seq_string_result_values);
    RUN(test_seq_string_result_special_chars);
    RUN(test_seq_string_param_empty);
    RUN(test_seq_string_param_single);
    RUN(test_seq_string_param_multiple);
    RUN(test_seq_string_param_unicode);
    RUN(test_string_seq_event);
    RUN(test_string_seq_event_empty);

    printf("\n--- TestSeqPrimTypes ---\n");
    RUN(test_prim_seq_result_empty);
    RUN(test_prim_seq_result_length);
    RUN(test_prim_seq_result_values);
    RUN(test_prim_seq_result_large_int64);
    RUN(test_prim_seq_param_empty);
    RUN(test_prim_seq_param_single);
    RUN(test_prim_seq_param_sum);
    RUN(test_prim_seq_param_large_values);
    RUN(test_prim_seq_event);
    RUN(test_prim_seq_event_empty);

    printf("\n--- TestFixedArrayTypes ---\n");
    RUN(test_array_result_values);
    RUN(test_array_result_length);
    RUN(test_array_result_seed_zero);
    RUN(test_array_result_negative_seed);
    RUN(test_array_result_timestamp);
    RUN(test_fixed_array_event);
    RUN(test_fixed_array_event_zero_seed);
    RUN(test_fixed_array_multiple_requests);

    printf("\n--- TestSeqObjectTypes ---\n");
    RUN(test_obj_seq_param_empty);
    RUN(test_obj_seq_param_single);
    RUN(test_obj_seq_param_multiple);
    RUN(test_obj_seq_param_string_encoding);
    RUN(test_obj_seq_result_empty);
    RUN(test_obj_seq_result_length);
    RUN(test_obj_seq_result_keys);
    RUN(test_obj_seq_result_values);
    RUN(test_obj_seq_result_tag_fields);
    RUN(test_obj_seq_roundtrip);

    printf("\n--- TestMultipleEventListeners ---\n");
    RUN(test_two_scalar_event_listeners);
    RUN(test_remove_one_listener_keeps_other);
    RUN(test_concurrent_event_types);

    printf("\n----------------------------------------------------------------------\n");
    printf("Ran %d tests: %d ok, %d failed\n", gTotal, gTotal - gFailed, gFailed);

    return gFailed == 0 ? 0 : 1;
}
