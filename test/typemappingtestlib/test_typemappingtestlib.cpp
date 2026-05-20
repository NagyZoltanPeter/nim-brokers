/**
 * test_typemappingtestlib.cpp
 * ===========================
 * C++ port of test_typemappingtestlib.py — covers every Nim→C→C++ type mapping
 * through the generated C++ wrapper (typemappingtestlib.hpp).
 *
 * Type mapping coverage:
 *   Scalars:    bool, int32, int64, float64, string
 *   Enum:       Priority
 *   Distinct:   JobId (int32), Timestamp (int64)
 *   seq result: seq[byte], seq[string], seq[int64], seq[Tag]
 *   seq params: seq[Tag], seq[string], seq[int64]
 *   array:      array[4, int32], array[ConstArrayLen, int32] (const-defined size)
 *   Events:     all of the above in callback fields
 *
 * Build (from repo root):
 *   nimble buildTypeMapTestLib
 *   (cmake step handled by nimble testTypeMap)
 */

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "typemappingtestlib.hpp"

using namespace typemappingtestlib;

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
    Typemappingtestlib lib;
    CHECK(!lib.validContext());
    auto r = lib.createContext();
    CHECK(r.isOk());
    CHECK(lib.validContext());
    CHECK_NE(lib.ctx(), 0u);
    lib.shutdown();
    CHECK(!lib.validContext());
}

static void test_lifecycle_raii_shutdown() {
    uint32_t savedCtx = 0;
    {
        Typemappingtestlib lib;
        lib.createContext();
        savedCtx = lib.ctx();
        CHECK_NE(savedCtx, 0u);
        // destructor calls shutdown()
    }
    // No crash — RAII worked.
    CHECK_NE(savedCtx, 0u);
}

static void test_lifecycle_double_shutdown_is_safe() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.shutdown();
    lib.shutdown(); // must not crash
}

static void test_lifecycle_double_create_returns_error() {
    Typemappingtestlib lib;
    auto r1 = lib.createContext();
    CHECK(r1.isOk());
    auto r2 = lib.createContext();
    CHECK(!r2.isOk()); // second create should fail
    lib.shutdown();
}

static void test_lifecycle_request_without_context_fails() {
    Typemappingtestlib lib; // ctx_ == 0
    auto r = lib.echoRequest("hello");
    CHECK(!r.isOk());
}

// ============================================================================
// TestRequests
// ============================================================================

static void test_requests_initialize() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.initializeRequest("test-label");
    CHECK(r.isOk());
    CHECK_EQ(r->label, std::string("test-label"));
    lib.shutdown();
}

static void test_requests_echo() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.initializeRequest("ctx-A");
    auto r = lib.echoRequest("hello");
    CHECK(r.isOk());
    CHECK_EQ(r->reply, std::string("ctx-A:hello"));
    lib.shutdown();
}

static void test_requests_counter_increments() {
    Typemappingtestlib lib;
    lib.createContext();
    for (int32_t expected = 1; expected <= 3; ++expected) {
        auto r = lib.counterRequest();
        CHECK(r.isOk());
        CHECK_EQ(r->value, expected);
    }
    lib.shutdown();
}

static void test_requests_multiple_echo() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.initializeRequest("multi");
    for (int i = 0; i < 5; ++i) {
        auto r = lib.echoRequest("msg-" + std::to_string(i));
        CHECK(r.isOk());
        CHECK_EQ(r->reply, "multi:msg-" + std::to_string(i));
    }
    lib.shutdown();
}

static void test_dual_sig_zero() {
    Typemappingtestlib lib;
    lib.createContext();
#ifdef USE_CBOR
    auto r = lib.dualSigRequestZero();
#else
    auto r = lib.dualSigRequest();
#endif
    CHECK(r.isOk());
    CHECK_EQ(r->label, std::string("zero"));
    CHECK_EQ(r->counter, 0);
    lib.shutdown();
}

static void test_dual_sig_with_label() {
    Typemappingtestlib lib;
    lib.createContext();
#ifdef USE_CBOR
    auto r = lib.dualSigRequestWithLabel("hello", 7);
#else
    auto r = lib.dualSigRequest("hello", 7);
#endif
    CHECK(r.isOk());
    CHECK_EQ(r->label, std::string("hello"));
    CHECK_EQ(r->counter, 7);
    lib.shutdown();
}

// ============================================================================
// TestEvents
// ============================================================================

static void test_events_counter_changed() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::pair<uint32_t, int32_t>> received;
    auto h = lib.onCounterChanged([&received, &lib](Typemappingtestlib& owner, int32_t v) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int32_t> received;
    auto h = lib.onCounterChanged([&received](Typemappingtestlib&, int32_t v) {
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
// TestPrimitiveBrokerTypes — non-object (primitive) request result + event
// payload. IntResultRequest is `type X = int32`; SimpleIntEvent is
// `type X = int64`. Native mode exposes the result as a struct with a single
// `value` field; CBOR mode exposes it as the bare `int32_t` alias. The event
// callback carries a bare scalar parameter in both modes.
// ============================================================================

static void test_primitive_int_result_request() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.intResultRequest(21);
    CHECK(r.isOk());
    // Native mode: IntResultRequest is a struct with a single `value` field.
    // CBOR mode: IntResultRequest is the bare `int32_t` alias.
#ifdef USE_CBOR
    CHECK_EQ(*r, 42); // provider returns value * 2
#else
    CHECK_EQ(r->value, 42); // provider returns value * 2
#endif
    lib.shutdown();
}

static void test_primitive_simple_int_event() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int64_t> received;
    auto h = lib.onSimpleIntEvent([&received](Typemappingtestlib&, int64_t v) {
        received.push(v);
    });
    CHECK_NE(h, 0ull);

    lib.intResultRequest(5); // provider emits SimpleIntEvent(value * 10)
    waitFor([&] { return received.size() >= 1; });

    CHECK_EQ(received.size(), 1u);
    CHECK_EQ(received.snapshot()[0], static_cast<int64_t>(50));

    lib.offSimpleIntEvent(h);
    lib.shutdown();
}

// ============================================================================
// TestVoidBrokerTypes — payload-less request + event. VoidActionRequest is
// `type X = void`; VoidPing is a `void` event. Native mode surfaces the
// result as an empty struct, CBOR mode as Result<void>; either way the
// caller only inspects isOk()/isErr(). The void event callback carries no
// payload argument in both modes.
// ============================================================================

static void test_void_action_request() {
    Typemappingtestlib lib;
    lib.createContext();

    auto ok = lib.voidActionRequest("go");
    CHECK(ok.isOk());

    auto bad = lib.voidActionRequest(""); // provider rejects empty label
    CHECK(bad.isErr());

    lib.shutdown();
}

static void test_void_ping_event() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int> received;
    auto h = lib.onVoidPing([&received](Typemappingtestlib&) { received.push(1); });
    CHECK_NE(h, 0ull);

    lib.voidActionRequest("trigger"); // provider emits VoidPing
    waitFor([&] { return received.size() >= 1; });

    CHECK_EQ(received.size(), 1u);

    lib.offVoidPing(h);
    lib.shutdown();
}

// ============================================================================
// TestContextSeparation
// ============================================================================

static void sleepMs(int ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

static void test_context_independent_counters() {
    Typemappingtestlib lib1, lib2;
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
    Typemappingtestlib lib1, lib2;
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
    Typemappingtestlib lib1, lib2;
    lib1.createContext();
    lib2.createContext();

    auto h1 =
        lib1.onCounterChanged([&events1](Typemappingtestlib&, int32_t v) { events1.push(v); });
    auto h2 =
        lib2.onCounterChanged([&events2](Typemappingtestlib&, int32_t v) { events2.push(v); });

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
    Typemappingtestlib lib1, lib2;
    lib1.createContext();
    lib2.createContext();

    lib1.initializeRequest("first");
    lib2.initializeRequest("second");

    lib1.shutdown();

    auto r = lib2.echoRequest("still-alive");
    CHECK(r.isOk());
    CHECK_EQ(r->reply, std::string("second:still-alive"));

    lib2.shutdown();
    sleepMs(50);
}

// ============================================================================
// TestScalarTypes
// ============================================================================

static void test_scalar_bool_true() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primScalarRequest(true, 0, 0, 0.0);
    CHECK(r.isOk());
    CHECK(r->flag == true);
    lib.shutdown();
}

static void test_scalar_bool_false() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primScalarRequest(false, 0, 0, 0.0);
    CHECK(r.isOk());
    CHECK(r->flag == false);
    lib.shutdown();
}

static void test_scalar_int32_roundtrip() {
    Typemappingtestlib lib;
    lib.createContext();

    auto r1 = lib.primScalarRequest(false, INT32_MIN, 0, 0.0);
    CHECK(r1.isOk());
    CHECK_EQ(r1->i32, INT32_MIN);

    auto r2 = lib.primScalarRequest(false, INT32_MAX, 0, 0.0);
    CHECK(r2.isOk());
    CHECK_EQ(r2->i32, INT32_MAX);

    lib.shutdown();
}

static void test_scalar_int64_roundtrip() {
    Typemappingtestlib lib;
    lib.createContext();
    int64_t big = 9'000'000'000'000LL;
    auto r = lib.primScalarRequest(false, 0, big, 0.0);
    CHECK(r.isOk());
    CHECK_EQ(r->i64, big);
    lib.shutdown();
}

static void test_scalar_float64_roundtrip() {
    Typemappingtestlib lib;
    lib.createContext();
    double pi = 3.141592653589793;
    auto r = lib.primScalarRequest(false, 0, 0, pi);
    CHECK(r.isOk());
    CHECK_NEAR(r->f64, pi, 1e-12);
    lib.shutdown();
}

static void test_scalar_all_fields_roundtrip() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primScalarRequest(true, 42, 1'000'000'000LL, 2.718);
    CHECK(r.isOk());
    CHECK(r->flag == true);
    CHECK_EQ(r->i32, 42);
    CHECK_EQ(r->i64, 1'000'000'000LL);
    CHECK_NEAR(r->f64, 2.718, 1e-12);
    lib.shutdown();
}

static void test_scalar_prim_scalar_event() {
    Typemappingtestlib lib;
    lib.createContext();

    struct Evt { bool flag; int32_t i32; int64_t i64; double f64; };
    SafeList<Evt> evts;
    auto h = lib.onPrimScalarEvent(
        [&evts](Typemappingtestlib&, bool flag, int32_t i32, int64_t i64, double f64) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<bool> evts;
    auto h = lib.onPrimScalarEvent(
        [&evts](Typemappingtestlib&, bool flag, int32_t, int64_t, double) {
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
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pLow, 10);
    CHECK(r.isOk());
    CHECK_EQ(r->priority, Priority::pLow);
    CHECK_EQ(static_cast<int>(r->priority), 0);
    lib.shutdown();
}

static void test_enum_roundtrip_high() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pHigh, 1);
    CHECK(r.isOk());
    CHECK_EQ(r->priority, Priority::pHigh);
    CHECK_EQ(static_cast<int>(r->priority), 2);
    lib.shutdown();
}

static void test_enum_roundtrip_critical() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pCritical, 1);
    CHECK(r.isOk());
    CHECK_EQ(static_cast<int>(r->priority), 3);
    lib.shutdown();
}

static void test_distinct_jobid_echoed() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pLow, 5);
    CHECK(r.isOk());
    CHECK_EQ(r->jobId, 5);
    lib.shutdown();
}

static void test_distinct_jobid_next() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pLow, 5);
    CHECK(r.isOk());
    CHECK_EQ(r->nextId, 6); // nextId = jobId + 1
    lib.shutdown();
}

static void test_distinct_jobid_zero() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pMedium, 0);
    CHECK(r.isOk());
    CHECK_EQ(r->jobId, 0);
    CHECK_EQ(r->nextId, 1);
    lib.shutdown();
}

static void test_all_priority_values() {
    Typemappingtestlib lib;
    lib.createContext();
    Priority priorities[] = {
        Priority::pLow, Priority::pMedium, Priority::pHigh, Priority::pCritical
    };
    for (auto p : priorities) {
        auto r = lib.typedScalarRequest(p, 1);
        CHECK(r.isOk());
        CHECK_EQ(r->priority, p);
    }
    lib.shutdown();
}

static void test_typed_scalar_event_enum() {
    Typemappingtestlib lib;
    lib.createContext();

    struct Evt { Priority priority; int32_t jobId; int64_t ts; };
    SafeList<Evt> evts;
    auto h = lib.onTypedScalarEvent(
        [&evts](Typemappingtestlib&, Priority p, int32_t jid, int64_t ts) {
            evts.push({p, jid, ts});
        });

    lib.typedScalarRequest(Priority::pHigh, 7);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto e = evts.at(0);
    CHECK_EQ(e.priority, Priority::pHigh);
    CHECK_EQ(static_cast<int>(e.priority), 2);
    CHECK_EQ(e.jobId, 7);
    CHECK_EQ(e.ts, 70LL); // ts = jobId * 10

    lib.offTypedScalarEvent(h);
    lib.shutdown();
}

static void test_typed_scalar_event_distinct_timestamp() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int64_t> evts;
    auto h = lib.onTypedScalarEvent(
        [&evts](Typemappingtestlib&, Priority, int32_t, int64_t ts) { evts.push(ts); });

    lib.typedScalarRequest(Priority::pLow, 3);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    CHECK_EQ(evts.at(0), 30LL); // ts = jobId * 10 = 3 * 10

    lib.offTypedScalarEvent(h);
    lib.shutdown();
}

static void test_fixedarray_result_contains_timestamp() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(99);
    CHECK(r.isOk());
    CHECK_EQ(r->ts, 99LL); // ts = Timestamp(seed)
    lib.shutdown();
}

// ============================================================================
// TestSeqByteResult
// ============================================================================

static void test_seq_byte_empty() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(0);
    CHECK(r.isOk());
    // `seq[byte]` maps to jsoncons::byte_string (no `.empty()`; use size()).
    CHECK_EQ(r->data.size(), static_cast<size_t>(0));
    lib.shutdown();
}

static void test_seq_byte_length() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(8);
    CHECK(r.isOk());
    CHECK_EQ(r->data.size(), 8u);
    lib.shutdown();
}

static void test_seq_byte_values() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(5);
    CHECK(r.isOk());
    CHECK_EQ(r->data.size(), 5u);
    for (size_t i = 0; i < r->data.size(); ++i)
        CHECK_EQ(r->data[i], static_cast<uint8_t>(i));
    lib.shutdown();
}

static void test_seq_byte_wrap_around() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(260);
    CHECK(r.isOk());
    CHECK_EQ(r->data.size(), 260u);
    CHECK_EQ(r->data[0], 0u);
    CHECK_EQ(r->data[255], 255u);
    CHECK_EQ(r->data[256], 0u); // wraps at 256
    lib.shutdown();
}

static void test_seq_byte_single_element() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(1);
    CHECK(r.isOk());
    CHECK_EQ(r->data.size(), 1u);
    CHECK_EQ(r->data[0], 0u);
    lib.shutdown();
}

static void test_seq_byte_large() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.byteSeqRequest(100);
    CHECK(r.isOk());
    CHECK_EQ(r->data.size(), 100u);
    for (size_t i = 0; i < r->data.size(); ++i)
        CHECK_EQ(r->data[i], static_cast<uint8_t>(i % 256));
    lib.shutdown();
}

// ============================================================================
// TestSeqStringTypes
// ============================================================================

static void test_seq_string_result_empty() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("x", 0);
    CHECK(r.isOk());
    CHECK(r->items.empty());
    lib.shutdown();
}

static void test_seq_string_result_count() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("item", 4);
    CHECK(r.isOk());
    CHECK_EQ(r->items.size(), 4u);
    lib.shutdown();
}

static void test_seq_string_result_values() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("tag", 3);
    CHECK(r.isOk());
    CHECK_EQ(r->items.size(), 3u);
    CHECK_EQ(r->items[0], std::string("tag-0"));
    CHECK_EQ(r->items[1], std::string("tag-1"));
    CHECK_EQ(r->items[2], std::string("tag-2"));
    lib.shutdown();
}

static void test_seq_string_result_special_chars() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.stringSeqRequest("a/b:c", 2);
    CHECK(r.isOk());
    CHECK_EQ(r->items.size(), 2u);
    CHECK_EQ(r->items[0], std::string("a/b:c-0"));
    CHECK_EQ(r->items[1], std::string("a/b:c-1"));
    lib.shutdown();
}

static void test_seq_string_param_empty() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 0);
    CHECK_EQ(r->joined, std::string(""));
    lib.shutdown();
}

static void test_seq_string_param_single() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({"hello"});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->joined, std::string("hello"));
    lib.shutdown();
}

static void test_seq_string_param_multiple() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({"alpha", "beta", "gamma"});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 3);
    CHECK_EQ(r->joined, std::string("alpha,beta,gamma"));
    lib.shutdown();
}

static void test_seq_string_param_unicode() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.seqStringParamRequest({"héllo", "wörld"});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 2);
    CHECK_EQ(r->joined, std::string("héllo,wörld"));
    lib.shutdown();
}

static void test_string_seq_event() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<std::string>> evts;
    auto h = lib.onStringSeqEvent(
        [&evts](Typemappingtestlib&, std::span<const std::string_view> items) {
            std::vector<std::string> v;
            v.reserve(items.size());
            for (auto sv : items)
                v.emplace_back(sv);
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<std::string>> evts;
    auto h = lib.onStringSeqEvent(
        [&evts](Typemappingtestlib&, std::span<const std::string_view> items) {
            std::vector<std::string> v;
            v.reserve(items.size());
            for (auto sv : items)
                v.emplace_back(sv);
            evts.push(std::move(v));
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
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(0);
    CHECK(r.isOk());
    CHECK(r->values.empty());
    lib.shutdown();
}

static void test_prim_seq_result_length() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(5);
    CHECK(r.isOk());
    CHECK_EQ(r->values.size(), 5u);
    lib.shutdown();
}

static void test_prim_seq_result_values() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(4);
    CHECK(r.isOk());
    CHECK_EQ(r->values.size(), 4u);
    for (size_t i = 0; i < r->values.size(); ++i)
        CHECK_EQ(r->values[i], static_cast<int64_t>(i) * 10LL);
    lib.shutdown();
}

static void test_prim_seq_result_large_int64() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqRequest(3);
    CHECK(r.isOk());
    CHECK_EQ(r->values[2], 20LL);
    lib.shutdown();
}

static void test_prim_seq_param_empty() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqParamRequest({});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 0);
    CHECK_EQ(r->total, 0LL);
    lib.shutdown();
}

static void test_prim_seq_param_single() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqParamRequest({42LL});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->total, 42LL);
    lib.shutdown();
}

static void test_prim_seq_param_sum() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.primSeqParamRequest({1LL, 2LL, 3LL, 4LL, 5LL});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 5);
    CHECK_EQ(r->total, 15LL);
    lib.shutdown();
}

static void test_prim_seq_param_large_values() {
    Typemappingtestlib lib;
    lib.createContext();
    int64_t big = 1'000'000'000'000LL;
    auto r = lib.primSeqParamRequest({big, big});
    CHECK(r.isOk());
    CHECK_EQ(r->count, 2);
    CHECK_EQ(r->total, 2 * big);
    lib.shutdown();
}

static void test_prim_seq_event() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int64_t>> evts;
    auto h = lib.onPrimSeqEvent(
        [&evts](Typemappingtestlib&, std::span<const int64_t> values) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int64_t>> evts;
    auto h = lib.onPrimSeqEvent(
        [&evts](Typemappingtestlib&, std::span<const int64_t> values) {
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
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(5);
    CHECK(r.isOk());
    CHECK_EQ(r->values[0], 5);
    CHECK_EQ(r->values[1], 10);
    CHECK_EQ(r->values[2], 15);
    CHECK_EQ(r->values[3], 20);
    lib.shutdown();
}

static void test_array_result_length() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(1);
    CHECK(r.isOk());
    CHECK_EQ(r->values.size(), 4u);
    lib.shutdown();
}

static void test_array_result_seed_zero() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(0);
    CHECK(r.isOk());
    for (auto v : r->values)
        CHECK_EQ(v, 0);
    lib.shutdown();
}

static void test_array_result_negative_seed() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(-3);
    CHECK(r.isOk());
    CHECK_EQ(r->values[0], -3);
    CHECK_EQ(r->values[1], -6);
    CHECK_EQ(r->values[2], -9);
    CHECK_EQ(r->values[3], -12);
    lib.shutdown();
}

static void test_array_result_timestamp() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.fixedArrayRequest(42);
    CHECK(r.isOk());
    CHECK_EQ(r->ts, 42LL);
    lib.shutdown();
}

static void test_fixed_array_event() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onFixedArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onFixedArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onFixedArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
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
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objSeqParamRequest({});
    CHECK(r.isOk());
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
    Typemappingtestlib lib;
    lib.createContext();
    std::vector<Tag> tags = {makeTag("mykey", "myval")};
    auto r = lib.objSeqParamRequest(tags);
    CHECK(r.isOk());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->first, std::string("mykey"));
    lib.shutdown();
}

static void test_obj_seq_param_multiple() {
    Typemappingtestlib lib;
    lib.createContext();
    std::vector<Tag> tags = {
        makeTag("first", "1"), makeTag("second", "2"), makeTag("third", "3")
    };
    auto r = lib.objSeqParamRequest(tags);
    CHECK(r.isOk());
    CHECK_EQ(r->count, 3);
    CHECK_EQ(r->first, std::string("first"));
    lib.shutdown();
}

static void test_obj_seq_param_string_encoding() {
    Typemappingtestlib lib;
    lib.createContext();
    std::vector<Tag> tags = {makeTag("key with spaces", "value/path")};
    auto r = lib.objSeqParamRequest(tags);
    CHECK(r.isOk());
    CHECK_EQ(r->count, 1);
    CHECK_EQ(r->first, std::string("key with spaces"));
    lib.shutdown();
}

// Native Option[T] probe (Phase E1 / scalar). Works in both native and
// CBOR builds: the C ABI now expands every `Option[T]` field to a
// `<name>: T` + `<name>_has_value: bool` pair (uniform layout); the
// C++ wrapper exposes it as `std::optional<T>`.
static void test_opt_scalar_present() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optScalarRequest(true);
    CHECK(r.isOk());
    CHECK(r->value.has_value());
    CHECK_EQ(*r->value, 42);
    lib.shutdown();
}

static void test_opt_scalar_absent() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optScalarRequest(false);
    CHECK(r.isOk());
    CHECK(!r->value.has_value());
    lib.shutdown();
}

// Variable-shape Option probe (Phase E2a) — Option[string] crosses the
// C ABI as `<name>: char*` + `<name>_has_value: bool` (uniform layout).
// Wrapper exposes it as std::optional<std::string>.
static void test_opt_string_present() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optStringRequest(true);
    CHECK(r.isOk());
    CHECK(r->value.has_value());
    CHECK_EQ(*r->value, std::string("hello"));
    lib.shutdown();
}

static void test_opt_string_absent() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optStringRequest(false);
    CHECK(r.isOk());
    CHECK(!r->value.has_value());
    lib.shutdown();
}

// Option of a registered object (Phase E3) — embedded by value at the
// C ABI (`TagCItem value` + `value_has_value`). Wrapper exposes it as
// std::optional<Tag>.
static void test_opt_obj_present() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optObjRequest(true);
    CHECK(r.isOk());
    CHECK(r->value.has_value());
    CHECK_EQ(r->value->key, std::string("ok"));
    CHECK_EQ(r->value->value, std::string("yes"));
    lib.shutdown();
}

static void test_opt_obj_absent() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optObjRequest(false);
    CHECK(r.isOk());
    CHECK(!r->value.has_value());
    lib.shutdown();
}

// Option[seq[byte]] absent — both modes partition Option fields so a
// payload where the field is missing yields `has_value() == false`.
static void test_opt_seq_absent() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optSeqRequest(false);
    CHECK(r.isOk());
    CHECK(!r->value.has_value());
    lib.shutdown();
}

// Option[seq[byte]] present — native Option support (Phase E2b) expands
// the field to a `(ptr,count)` + `value_has_value` pair at the C ABI;
// the C++ wrapper exposes it as std::optional<std::vector<uint8_t>>.
static void test_opt_seq_present() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.optSeqRequest(true);
    CHECK(r.isOk());
    CHECK(r->value.has_value());
    CHECK_EQ(r->value->size(), static_cast<size_t>(4));
    CHECK_EQ((*r->value)[0], static_cast<uint8_t>(1));
    CHECK_EQ((*r->value)[3], static_cast<uint8_t>(4));
    lib.shutdown();
}

#ifdef USE_CBOR
// Object-as-request-param probe — exercises whole-struct pass-by-value.
// Supported on every wrapper since CBOR became the only FFI mode.
// (`#ifdef USE_CBOR` is now always-true; left in until the C++ test
// source is swept clean of historical gates.)
static void test_obj_as_param() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objParamRequest(makeTag("k", "v"));
    CHECK(r.isOk());
    CHECK_EQ(r->summary, std::string("k=v"));
    lib.shutdown();
}

// Inbound `seq[byte]` byte-string probe. `seq[byte]` maps to
// jsoncons::byte_string, which jsoncons encodes/decodes as a CBOR byte
// string (major type 2) — the form the Nim provider expects.
static void test_bytes_echo_request_roundtrip() {
    Typemappingtestlib lib;
    lib.createContext();
    jsoncons::byte_string payload{10, 20, 30, 40, 50};
    auto r = lib.bytesEchoRequest(payload);
    CHECK(r.isOk());
    CHECK_EQ(r->length, 5);
    CHECK_EQ(r->first, 10);
    CHECK_EQ(r->last, 50);
    lib.shutdown();
}

static void test_bytes_echo_request_empty() {
    Typemappingtestlib lib;
    lib.createContext();
    jsoncons::byte_string payload;
    auto r = lib.bytesEchoRequest(payload);
    CHECK(r.isOk());
    CHECK_EQ(r->length, 0);
    CHECK_EQ(r->first, -1);
    CHECK_EQ(r->last, -1);
    lib.shutdown();
}

// ScanRequest round-trip — exercises tuple-as-struct (TupleRow), seq[Tuple]
// (rows), and object-as-input-param (KeyRange) end-to-end. With the per-
// tuple `bindCborTupleMap` overrides on the Nim side, named tuples
// serialise as CBOR maps so the wrapper-side struct decoders are happy.
static void test_scan_request_forward() {
    Typemappingtestlib lib;
    lib.createContext();
    KeyRange kr;
    kr.startKey = "lo";
    kr.stopKey = "hi";
    auto r = lib.scanRequest("scan", kr, false);
    CHECK(r.isOk());
    CHECK_EQ(r->rows.size(), static_cast<size_t>(3));
    CHECK_EQ(r->rows[0].key, std::string("0:lo"));
    CHECK_EQ(r->rows[2].key, std::string("2:lo"));
    CHECK_EQ(r->rows[0].payload, std::string("scan-row-0:hi"));
    lib.shutdown();
}

static void test_scan_request_reverse() {
    Typemappingtestlib lib;
    lib.createContext();
    KeyRange kr;
    kr.startKey = "lo";
    kr.stopKey = "hi";
    auto r = lib.scanRequest("scan", kr, true);
    CHECK(r.isOk());
    CHECK_EQ(r->rows.size(), static_cast<size_t>(3));
    CHECK_EQ(r->rows[0].key, std::string("2:lo"));
    CHECK_EQ(r->rows[2].key, std::string("0:lo"));
    lib.shutdown();
}
#endif

static void test_obj_seq_result_empty() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(0);
    CHECK(r.isOk());
    CHECK(r->tags.empty());
    lib.shutdown();
}

static void test_obj_seq_result_length() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(4);
    CHECK(r.isOk());
    CHECK_EQ(r->tags.size(), 4u);
    lib.shutdown();
}

static void test_obj_seq_result_keys() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(3);
    CHECK(r.isOk());
    CHECK_EQ(r->tags.size(), 3u);
    CHECK_EQ(r->tags[0].key, std::string("key-0"));
    CHECK_EQ(r->tags[1].key, std::string("key-1"));
    CHECK_EQ(r->tags[2].key, std::string("key-2"));
    lib.shutdown();
}

static void test_obj_seq_result_values() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(3);
    CHECK(r.isOk());
    CHECK_EQ(r->tags[0].value, std::string("val-0"));
    CHECK_EQ(r->tags[1].value, std::string("val-1"));
    CHECK_EQ(r->tags[2].value, std::string("val-2"));
    lib.shutdown();
}

static void test_obj_seq_result_tag_fields() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.objSeqResultRequest(2);
    CHECK(r.isOk());
    for (const auto& tag : r->tags) {
        CHECK(!tag.key.empty());
        CHECK(!tag.value.empty());
    }
    lib.shutdown();
}

static void test_obj_seq_roundtrip() {
    Typemappingtestlib lib;
    lib.createContext();
    // Generate tags via result request
    auto gen = lib.objSeqResultRequest(3);
    CHECK(gen.isOk());
    // Pass them back as input param
    auto r = lib.objSeqParamRequest(gen->tags);
    CHECK(r.isOk());
    CHECK_EQ(r->count, 3);
    CHECK_EQ(r->first, std::string("key-0"));
    lib.shutdown();
}

// ============================================================================
// TestConstArraySize — array[ConstArrayLen, int32] (const-defined size)
// Exercises the arrayNodeSize nnkIdent path in api_codegen_c.nim.
// ============================================================================

static constexpr size_t kConstArrayLen = 6;

static void test_const_array_result_length() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.constArrayRequest(1);
    CHECK(r.isOk());
    CHECK_EQ(r->values.size(), kConstArrayLen);
    lib.shutdown();
}

static void test_const_array_result_values() {
    Typemappingtestlib lib;
    lib.createContext();
    // Provider: values[i] = seed * (i + 1)
    auto r = lib.constArrayRequest(3);
    CHECK(r.isOk());
    CHECK_EQ(r->values.size(), kConstArrayLen);
    int32_t expected[] = {3, 6, 9, 12, 15, 18};
    for (size_t i = 0; i < kConstArrayLen; ++i)
        CHECK_EQ(r->values[i], expected[i]);
    lib.shutdown();
}

static void test_const_array_result_zero_seed() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.constArrayRequest(0);
    CHECK(r.isOk());
    for (auto v : r->values)
        CHECK_EQ(v, 0);
    lib.shutdown();
}

static void test_const_array_result_negative_seed() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.constArrayRequest(-2);
    CHECK(r.isOk());
    int32_t expected[] = {-2, -4, -6, -8, -10, -12};
    for (size_t i = 0; i < kConstArrayLen; ++i)
        CHECK_EQ(r->values[i], expected[i]);
    lib.shutdown();
}

static void test_const_array_event_values() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onConstArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.constArrayRequest(2);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto snap = evts.at(0);
    CHECK_EQ(snap.size(), kConstArrayLen);
    int32_t expected[] = {2, 4, 6, 8, 10, 12};
    for (size_t i = 0; i < kConstArrayLen; ++i)
        CHECK_EQ(snap[i], expected[i]);

    lib.offConstArrayEvent(h);
    lib.shutdown();
}

static void test_const_array_event_length() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onConstArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.constArrayRequest(1);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.at(0).size(), kConstArrayLen);

    lib.offConstArrayEvent(h);
    lib.shutdown();
}

static void test_const_array_event_neg_seed() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onConstArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.constArrayRequest(-2);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    auto snap = evts.at(0);
    std::vector<int32_t> expected{-2, -4, -6, -8, -10, -12};
    CHECK_EQ(snap.size(), expected.size());
    for (size_t i = 0; i < snap.size() && i < expected.size(); ++i)
        CHECK_EQ(snap[i], expected[i]);

    lib.offConstArrayEvent(h);
    lib.shutdown();
}

static void test_distinct_jobid_max_minus_one() {
    Typemappingtestlib lib;
    lib.createContext();
    auto r = lib.typedScalarRequest(Priority::pLow, INT32_MAX - 1);
    CHECK(r.isOk());
    CHECK_EQ(r->jobId, INT32_MAX - 1);
    CHECK_EQ(r->nextId, INT32_MAX);
    lib.shutdown();
}

static void test_const_array_event_zero_seed() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<std::vector<int32_t>> evts;
    auto h = lib.onConstArrayEvent(
        [&evts](Typemappingtestlib&, std::span<const int32_t> values) {
            evts.push(std::vector<int32_t>(values.begin(), values.end()));
        });

    lib.constArrayRequest(0);
    waitFor([&] { return evts.size() >= 1; });

    CHECK_EQ(evts.size(), 1u);
    for (auto v : evts.at(0))
        CHECK_EQ(v, 0);

    lib.offConstArrayEvent(h);
    lib.shutdown();
}

// ============================================================================
// TestMultipleEventListeners
// ============================================================================

static void test_two_scalar_event_listeners() {
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int32_t> evts1, evts2;
    auto h1 = lib.onPrimScalarEvent(
        [&evts1](Typemappingtestlib&, bool, int32_t i32, int64_t, double) {
            evts1.push(i32);
        });
    auto h2 = lib.onPrimScalarEvent(
        [&evts2](Typemappingtestlib&, bool, int32_t i32, int64_t, double) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int32_t> evts1, evts2;
    auto h1 = lib.onPrimScalarEvent(
        [&evts1](Typemappingtestlib&, bool, int32_t i32, int64_t, double) {
            evts1.push(i32);
        });
    auto h2 = lib.onPrimScalarEvent(
        [&evts2](Typemappingtestlib&, bool, int32_t i32, int64_t, double) {
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
    Typemappingtestlib lib;
    lib.createContext();

    SafeList<int32_t> scalarEvts;
    SafeList<std::vector<int32_t>> arrayEvts;
    SafeList<std::vector<std::string>> stringEvts;

    auto hs = lib.onPrimScalarEvent(
        [&scalarEvts](Typemappingtestlib&, bool, int32_t i32, int64_t, double) {
            scalarEvts.push(i32);
        });
    auto ha = lib.onFixedArrayEvent(
        [&arrayEvts](Typemappingtestlib&, std::span<const int32_t> values) {
            arrayEvts.push(std::vector<int32_t>(values.begin(), values.end()));
        });
    auto hst = lib.onStringSeqEvent(
        [&stringEvts](Typemappingtestlib&, std::span<const std::string_view> items) {
            std::vector<std::string> v;
            v.reserve(items.size());
            for (auto sv : items)
                v.emplace_back(sv);
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
// TestForeignThreadGcSafety
// ============================================================================
// These tests exercise the ensureForeignThreadGc() path: multiple C++ threads
// (foreign to Nim) calling exported FFI functions concurrently.  Without
// per-thread GC registration, the Nim GC would miss live references created
// on threads other than the one that called _initialize(), leading to
// premature collection, heap corruption, or crashes.
// ============================================================================

/// Spawn N threads, each making a request that creates Nim strings/seqs on
/// the caller's stack before crossing into the broker.  Verifies that all
/// responses are correct — no GC-induced corruption.
static void test_foreign_thread_concurrent_requests() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.initializeRequest("gc-test");

    constexpr int kThreads = 8;
    constexpr int kIters = 20;

    struct ThreadResult {
        bool ok = false;
        std::string error;
        std::vector<std::string> replies;
    };
    std::vector<ThreadResult> results(kThreads);
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                std::string msg = "thread-" + std::to_string(t) + "-msg-" + std::to_string(i);
                auto r = lib.echoRequest(msg);
                if (!r.isOk()) {
                    results[t].error = r.error();
                    return;
                }
                if (i == 0) {
                    results[t].ok = true;
                }
                // Verify the reply contains our thread identifier
                std::string expectedPrefix = "gc-test:";
                if (r->reply.find(expectedPrefix) != 0) {
                    results[t].error = "unexpected reply: " + r->reply;
                    return;
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    for (int t = 0; t < kThreads; ++t) {
        if (!results[t].ok && results[t].error.empty()) {
            // Thread didn't get to run its first iteration — shouldn't happen
            results[t].ok = true;
        }
        if (!results[t].error.empty()) {
            fprintf(stderr, "  thread %d error: %s\n", t, results[t].error.c_str());
        }
        CHECK(results[t].error.empty());
    }

    lib.shutdown();
}

/// Multiple foreign threads calling seq[string] result requests concurrently.
/// This exercises the decode path for seq[string] params and the encode path
/// for seq[string] results, both of which create GC-managed Nim objects on
/// the foreign thread's stack.
static void test_foreign_thread_concurrent_seq_string_requests() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.initializeRequest("seq-str");

    constexpr int kThreads = 6;
    constexpr int kIters = 10;

    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                std::string prefix = "t" + std::to_string(t) + "i" + std::to_string(i);
                int n = 5 + (t % 3);
                auto r = lib.stringSeqRequest(prefix, n);
                if (!r.isOk()) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (r->items.size() != static_cast<size_t>(n)) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                for (int j = 0; j < n; ++j) {
                    std::string expected = prefix + "-" + std::to_string(j);
                    if (r->items[j] != expected) {
                        failures.fetch_add(1, std::memory_order_relaxed);
                        return;
                    }
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
    lib.shutdown();
}

/// Multiple foreign threads calling seq[int64] result requests concurrently.
/// Exercises the decode/encode path for seq[primitive].
static void test_foreign_thread_concurrent_seq_prim_requests() {
    Typemappingtestlib lib;
    lib.createContext();

    constexpr int kThreads = 6;
    constexpr int kIters = 15;

    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                int n = 3 + (t % 4);
                auto r = lib.primSeqRequest(n);
                if (!r.isOk()) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (r->values.size() != static_cast<size_t>(n)) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                for (size_t j = 0; j < r->values.size(); ++j) {
                    if (r->values[j] != static_cast<int64_t>(j) * 10LL) {
                        failures.fetch_add(1, std::memory_order_relaxed);
                        return;
                    }
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
    lib.shutdown();
}

/// Multiple foreign threads calling seq[object] (Tag) result requests concurrently.
/// This exercises the CItem encode/decode path where each Tag has two string
/// fields allocated via allocCStringCopy on the shared heap.
static void test_foreign_thread_concurrent_seq_object_requests() {
    Typemappingtestlib lib;
    lib.createContext();

    constexpr int kThreads = 4;
    constexpr int kIters = 10;

    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                int n = 3 + (t % 5);
                auto r = lib.objSeqResultRequest(n);
                if (!r.isOk()) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (r->tags.size() != static_cast<size_t>(n)) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                for (int j = 0; j < n; ++j) {
                    std::string expectedKey = "key-" + std::to_string(j);
                    std::string expectedVal = "val-" + std::to_string(j);
                    if (r->tags[j].key != expectedKey || r->tags[j].value != expectedVal) {
                        failures.fetch_add(1, std::memory_order_relaxed);
                        return;
                    }
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
    lib.shutdown();
}

/// Multiple foreign threads calling seq[object] input param requests concurrently.
/// Exercises the decode path for seq[CItem] where each CItem has string fields
/// that must be converted to Nim strings on the foreign thread.
static void test_foreign_thread_concurrent_seq_object_param_requests() {
    Typemappingtestlib lib;
    lib.createContext();

    constexpr int kThreads = 4;
    constexpr int kIters = 8;

    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                int n = 2 + (t % 3);
                std::vector<Tag> tags;
                for (int j = 0; j < n; ++j) {
                    Tag tag;
                    tag.key = "thread" + std::to_string(t) + "-key" + std::to_string(j);
                    tag.value = "thread" + std::to_string(t) + "-val" + std::to_string(j);
                    tags.push_back(std::move(tag));
                }
                auto r = lib.objSeqParamRequest(tags);
                if (!r.isOk()) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (r->count != n) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (r->first != "thread" + std::to_string(t) + "-key0") {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
    lib.shutdown();
}

/// Multiple foreign threads calling createContext/shutdown in rapid succession.
/// Each thread gets its own library instance and context, exercising the
/// per-thread GC registration path in createContext and shutdown.
static void test_foreign_thread_concurrent_lifecycle() {
    constexpr int kThreads = 4;
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            Typemappingtestlib lib;
            auto cr = lib.createContext();
            if (!cr.isOk()) {
                failures.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            auto ir = lib.initializeRequest("lifecycle-t" + std::to_string(t));
            if (!ir.isOk()) {
                failures.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            // Make a request to verify the context is fully functional
            auto r = lib.echoRequest("test");
            if (!r.isOk()) {
                failures.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            std::string expected = "lifecycle-t" + std::to_string(t) + ":test";
            if (r->reply != expected) {
                failures.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            // destructor calls shutdown
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
}

/// Mixed workload: multiple foreign threads making different types of requests
/// concurrently, including requests that return error results (which allocate
/// error_message via allocCStringCopy on the shared heap).
static void test_foreign_thread_mixed_request_types() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.initializeRequest("mixed");

    constexpr int kThreads = 6;
    constexpr int kIters = 10;

    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                switch (i % 5) {
                case 0: {
                    auto r = lib.echoRequest("t" + std::to_string(t));
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    break;
                }
                case 1: {
                    auto r = lib.counterRequest();
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->value <= 0) { failures.fetch_add(1); return; }
                    break;
                }
                case 2: {
                    auto r = lib.primScalarRequest(true, 42, 1000, 3.14);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->flag != true || r->i32 != 42) { failures.fetch_add(1); return; }
                    break;
                }
                case 3: {
                    auto r = lib.stringSeqRequest("x", 3);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->items.size() != 3) { failures.fetch_add(1); return; }
                    break;
                }
                case 4: {
                    auto r = lib.fixedArrayRequest(7);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->values[0] != 7) { failures.fetch_add(1); return; }
                    break;
                }
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
    lib.shutdown();
}

/// Stress test: many foreign threads, many iterations, exercising all request
/// types including seq[object] results and params.  Designed to trigger GC
/// issues if foreign thread registration is broken.
static void test_foreign_thread_stress_all_types() {
    Typemappingtestlib lib;
    lib.createContext();
    lib.initializeRequest("stress");

    constexpr int kThreads = 8;
    constexpr int kIters = 30;

    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                switch (i % 8) {
                case 0: {
                    auto r = lib.echoRequest("stress-" + std::to_string(t));
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    break;
                }
                case 1: {
                    auto r = lib.counterRequest();
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    break;
                }
                case 2: {
                    auto r = lib.primScalarRequest(false, -100, -999999, -1.5);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    break;
                }
                case 3: {
                    auto r = lib.stringSeqRequest("s", 10);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->items.size() != 10) { failures.fetch_add(1); return; }
                    break;
                }
                case 4: {
                    auto r = lib.primSeqRequest(20);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->values.size() != 20) { failures.fetch_add(1); return; }
                    break;
                }
                case 5: {
                    auto r = lib.objSeqResultRequest(5);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->tags.size() != 5) { failures.fetch_add(1); return; }
                    break;
                }
                case 6: {
                    std::vector<Tag> tags;
                    for (int j = 0; j < 3; ++j) {
                        Tag tag;
                        tag.key = "k" + std::to_string(j);
                        tag.value = "v" + std::to_string(j);
                        tags.push_back(std::move(tag));
                    }
                    auto r = lib.objSeqParamRequest(tags);
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->count != 3) { failures.fetch_add(1); return; }
                    break;
                }
                case 7: {
                    auto r = lib.seqStringParamRequest({"a", "b", "c"});
                    if (!r.isOk()) { failures.fetch_add(1); return; }
                    if (r->count != 3) { failures.fetch_add(1); return; }
                    break;
                }
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    CHECK_EQ(failures.load(), 0);
    lib.shutdown();
}

// ============================================================================
// TestSeqObjectEventMemorySafety
// ============================================================================
// Tests for seq[object] event callbacks where CItem string fields are
// allocated via allocCStringCopy and must be freed after the callback returns.
// The old code leaked these strings.
// ============================================================================

/// Register a listener for TagSeqEvent (seq[Tag] with string fields), trigger
/// multiple events, and verify all tag data is correctly received.  The CItem
/// string fields must be freed after each callback — if they leak, this test
/// would consume excessive memory over many iterations.
static void test_seq_object_event_callback_data_correctness() {
    Typemappingtestlib lib;
    lib.createContext();

    struct TagData { std::string key; std::string value; };
    SafeList<std::vector<TagData>> received;

    auto h = lib.onTagSeqEvent(
        [&received](Typemappingtestlib&, std::span<const Tag> tags) {
            std::vector<TagData> snapshot;
            snapshot.reserve(tags.size());
            for (const auto& t : tags) {
                snapshot.push_back(TagData{t.key, t.value});
            }
            received.push(std::move(snapshot));
        });
    CHECK_NE(h, 0ull);

    // Trigger events via objSeqResultRequest (which emits TagSeqEvent)
    lib.objSeqResultRequest(3);
    lib.objSeqResultRequest(5);
    lib.objSeqResultRequest(0);

    waitFor([&] { return received.size() >= 3; });

    CHECK_EQ(received.size(), 3u);

    // First event: 3 tags
    auto snap0 = received.at(0);
    CHECK_EQ(snap0.size(), 3u);
    CHECK_EQ(snap0[0].key, "key-0");
    CHECK_EQ(snap0[0].value, "val-0");
    CHECK_EQ(snap0[2].key, "key-2");
    CHECK_EQ(snap0[2].value, "val-2");

    // Second event: 5 tags
    auto snap1 = received.at(1);
    CHECK_EQ(snap1.size(), 5u);
    CHECK_EQ(snap1[0].key, "key-0");
    CHECK_EQ(snap1[4].value, "val-4");

    // Third event: 0 tags (empty seq)
    auto snap2 = received.at(2);
    CHECK(snap2.empty());

    lib.offTagSeqEvent(h);
    lib.shutdown();
}

/// Rapid-fire seq[object] events to stress the CItem allocation/free path.
/// If string fields inside CItems are not freed (the old bug), this would
/// leak O(iterations * items * strings_per_item) allocations.
static void test_seq_object_event_rapid_fire_no_leak() {
    Typemappingtestlib lib;
    lib.createContext();

    std::atomic<int> eventCount{0};
    auto h = lib.onTagSeqEvent(
        [&eventCount](Typemappingtestlib&, std::span<const Tag>) {
            eventCount.fetch_add(1, std::memory_order_relaxed);
        });

    constexpr int kIterations = 100;
    for (int i = 0; i < kIterations; ++i) {
        lib.objSeqResultRequest(10); // each emits TagSeqEvent with 10 tags
    }

    waitFor([&] { return eventCount.load() >= kIterations; }, 10.0);
    CHECK_EQ(eventCount.load(), kIterations);

    lib.offTagSeqEvent(h);
    lib.shutdown();
}

/// Multiple foreign threads registering event listeners and triggering events
/// concurrently.  Verifies that event callback memory (CItem allocations) is
/// safe when the delivery thread runs concurrently with foreign requester threads.
static void test_seq_object_event_concurrent_listeners_and_requesters() {
    Typemappingtestlib lib;
    lib.createContext();

    std::atomic<int> eventCount{0};
    auto h = lib.onTagSeqEvent(
        [&eventCount](Typemappingtestlib&, std::span<const Tag> tags) {
            // Touch every string to force a read — catches use-after-free
            // in the trampoline's view-array materialisation.
            for (const auto& t : tags) {
                volatile size_t kl = t.key.size();
                volatile size_t vl = t.value.size();
                (void)kl;
                (void)vl;
            }
            eventCount.fetch_add(1, std::memory_order_relaxed);
        });

    constexpr int kRequesterThreads = 4;
    constexpr int kIters = 20;

    std::atomic<int> requestFailures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kRequesterThreads; ++t) {
        threads.emplace_back([&, t]() {
            for (int i = 0; i < kIters; ++i) {
                auto r = lib.objSeqResultRequest(5 + (t % 3));
                if (!r.isOk()) {
                    requestFailures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (r->tags.size() < 5) {
                    requestFailures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
            }
        });
    }

    for (auto& th : threads)
        th.join();

    int expectedEvents = kRequesterThreads * kIters;
    CHECK_EQ(requestFailures.load(), 0);
    // Events are delivered asynchronously on the delivery thread — wait
    // for them to catch up, especially on slower 32-bit CI runners.
    waitFor([&] { return eventCount.load() >= expectedEvents; });
    CHECK_EQ(eventCount.load(), expectedEvents);

    lib.offTagSeqEvent(h);
    lib.shutdown();
}

// ============================================================================
// main
// ============================================================================

int main() {
    printf("test_typemappingtestlib — C++ type mapping coverage\n\n");

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
    RUN(test_dual_sig_zero);
    RUN(test_dual_sig_with_label);

    printf("\n--- TestEvents ---\n");
    RUN(test_events_counter_changed);
    RUN(test_events_off_stops_delivery);

    printf("\n--- TestPrimitiveBrokerTypes ---\n");
    RUN(test_primitive_int_result_request);
    RUN(test_primitive_simple_int_event);
    RUN(test_void_action_request);
    RUN(test_void_ping_event);

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
    RUN(test_distinct_jobid_max_minus_one);
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

    printf("\n--- TestConstArraySize ---\n");
    RUN(test_const_array_result_length);
    RUN(test_const_array_result_values);
    RUN(test_const_array_result_zero_seed);
    RUN(test_const_array_result_negative_seed);
    RUN(test_const_array_event_values);
    RUN(test_const_array_event_length);
    RUN(test_const_array_event_zero_seed);
    RUN(test_const_array_event_neg_seed);

    printf("\n--- TestSeqObjectTypes ---\n");
    RUN(test_obj_seq_param_empty);
    RUN(test_obj_seq_param_single);
    RUN(test_obj_seq_param_multiple);
    RUN(test_obj_seq_param_string_encoding);
    RUN(test_opt_scalar_present);
    RUN(test_opt_scalar_absent);
    RUN(test_opt_string_present);
    RUN(test_opt_string_absent);
    RUN(test_opt_seq_present);
    RUN(test_opt_seq_absent);
    RUN(test_opt_obj_present);
    RUN(test_opt_obj_absent);
#ifdef USE_CBOR
    RUN(test_obj_as_param);
    RUN(test_scan_request_forward);
    RUN(test_scan_request_reverse);
    RUN(test_bytes_echo_request_roundtrip);
    RUN(test_bytes_echo_request_empty);
#endif
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

    printf("\n--- TestForeignThreadGcSafety ---\n");
    // These foreign-thread concurrent + stress tests historically tripped
    // §2.2 (Nim 2.2.4 macOS+refc+debug `Channel[T].send` race) and §2.6
    // (macOS+ORC channel slot-payload UAF). Both are closed by the
    // channel-dispatch refactor; see doc/LIMITATION.md.
    RUN(test_foreign_thread_concurrent_requests);
    RUN(test_foreign_thread_concurrent_seq_string_requests);
    RUN(test_foreign_thread_concurrent_seq_prim_requests);
    RUN(test_foreign_thread_concurrent_seq_object_requests);
    RUN(test_foreign_thread_concurrent_seq_object_param_requests);
    RUN(test_foreign_thread_concurrent_lifecycle);
    RUN(test_foreign_thread_mixed_request_types);
    RUN(test_foreign_thread_stress_all_types);

    printf("\n--- TestSeqObjectEventMemorySafety ---\n");
    RUN(test_seq_object_event_callback_data_correctness);
    RUN(test_seq_object_event_rapid_fire_no_leak);
    RUN(test_seq_object_event_concurrent_listeners_and_requesters);

    printf("\n----------------------------------------------------------------------\n");
    printf("Ran %d tests: %d ok, %d failed\n", gTotal, gTotal - gFailed, gFailed);

    return gFailed == 0 ? 0 : 1;
}
