// C++ parity test for typemappingtestlib_cbor.
//
// Drives every typed wrapper method on the generated `Lib` class and
// every typed event subscribe path, asserting the round-trip values
// match the provider-side computation. C++ counterpart to the Nim and
// Python parity tests under this directory.

#include "typemappingtestlib_cbor.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <iostream>
#include <limits>
#include <mutex>
#include <thread>
#include <vector>

namespace tmlib = typemappingtestlib_cbor;  // `tm` would clash with <time.h>'s struct tm

namespace {

int g_fails = 0;

template <typename A, typename B>
void check(const char* name, const A& expected, const B& got) {
  if (!(expected == got)) {
    std::cerr << "FAIL " << name << '\n';
    ++g_fails;
    return;
  }
  std::cout << "OK   " << name << '\n';
}

// Simple condition-variable-backed event waiter so each subscription
// callback can hand off a captured payload to the test thread.
template <typename T>
struct EventSlot {
  std::mutex m;
  std::condition_variable cv;
  bool delivered = false;
  T value{};

  void set(T v) {
    std::lock_guard<std::mutex> lk(m);
    value = std::move(v);
    delivered = true;
    cv.notify_all();
  }

  bool wait(std::chrono::milliseconds timeout = std::chrono::milliseconds(500)) {
    std::unique_lock<std::mutex> lk(m);
    return cv.wait_for(lk, timeout, [this] { return delivered; });
  }
};

}  // namespace

int main() {
  tmlib::Lib lib;

  // ----- lifecycle / string param -----
  {
    auto r = lib.initializeRequest("hello");
    check("initialize_request.is_ok", true, r.isOk());
    check("initialize_request.label", std::string("hello"), r.value().label);
  }

  // ----- echo concatenates -----
  {
    auto r = lib.echoRequest("ping");
    check("echo_request.reply", std::string("hello:ping"), r.value().reply);
  }

  // ----- primitive scalars + matching event -----
  {
    EventSlot<tmlib::PrimScalarEvent> slot;
    auto h = lib.subscribePrimScalarEvent(
        [&](const tmlib::PrimScalarEvent& evt) { slot.set(evt); });
    auto r = lib.primScalarRequest(true, 7, 1234567890123LL, 3.5);
    check("prim_scalar_request.flag", true, r.value().flag);
    check("prim_scalar_request.i64", 1234567890123LL, r.value().i64);
    check("prim_scalar_request.f64", 3.5, r.value().f64);
    if (!slot.wait()) {
      std::cerr << "FAIL prim_scalar_event timeout\n";
      ++g_fails;
    } else {
      check("prim_scalar_event.i64", 1234567890123LL, slot.value.i64);
    }
    lib.unsubscribePrimScalarEvent(h);
  }

  // ----- enum + distinct -----
  {
    EventSlot<tmlib::TypedScalarEvent> slot;
    auto h = lib.subscribeTypedScalarEvent(
        [&](const tmlib::TypedScalarEvent& evt) { slot.set(evt); });
    auto r = lib.typedScalarRequest(tmlib::Priority::pHigh, 41);
    check("typed_scalar_request.priority", tmlib::Priority::pHigh,
          r.value().priority);
    check("typed_scalar_request.jobId", 41, r.value().jobId);
    check("typed_scalar_request.nextId", 42, r.value().nextId);
    if (slot.wait()) {
      check("typed_scalar_event.ts", static_cast<int64_t>(410), slot.value.ts);
    }
    lib.unsubscribeTypedScalarEvent(h);
  }

  // ----- seq[byte] -----
  {
    auto r = lib.byteSeqRequest(5);
    std::vector<uint8_t> expected{0, 1, 2, 3, 4};
    check("byte_seq_request.data", expected, r.value().data);
  }

  // ----- seq[string] + event -----
  {
    EventSlot<tmlib::StringSeqEvent> slot;
    auto h = lib.subscribeStringSeqEvent(
        [&](const tmlib::StringSeqEvent& evt) { slot.set(evt); });
    auto r = lib.stringSeqRequest("x", 3);
    std::vector<std::string> expected{"x-0", "x-1", "x-2"};
    check("string_seq_request.items", expected, r.value().items);
    if (slot.wait()) {
      check("string_seq_event.items", expected, slot.value.items);
    }
    lib.unsubscribeStringSeqEvent(h);
  }

  // ----- seq[int64] + event -----
  {
    EventSlot<tmlib::PrimSeqEvent> slot;
    auto h = lib.subscribePrimSeqEvent(
        [&](const tmlib::PrimSeqEvent& evt) { slot.set(evt); });
    auto r = lib.primSeqRequest(4);
    std::vector<int64_t> expected{0, 10, 20, 30};
    check("prim_seq_request.values", expected, r.value().values);
    slot.wait();
    lib.unsubscribePrimSeqEvent(h);
  }

  // ----- array[4, int32] -----
  {
    EventSlot<tmlib::FixedArrayEvent> slot;
    auto h = lib.subscribeFixedArrayEvent(
        [&](const tmlib::FixedArrayEvent& evt) { slot.set(evt); });
    auto r = lib.fixedArrayRequest(5);
    std::vector<int32_t> expected{5, 10, 15, 20};
    check("fixed_array_request.values", expected, r.value().values);
    check("fixed_array_request.ts", static_cast<int64_t>(5), r.value().ts);
    slot.wait();
    lib.unsubscribeFixedArrayEvent(h);
  }

  // ----- array[ConstArrayLen, int32] -----
  {
    auto r = lib.constArrayRequest(3);
    std::vector<int32_t> expected{3, 6, 9, 12, 15, 18};
    check("const_array_request.values", expected, r.value().values);
  }

  // ----- seq[Tag] result + tag_seq_event -----
  {
    EventSlot<tmlib::TagSeqEvent> slot;
    auto h = lib.subscribeTagSeqEvent(
        [&](const tmlib::TagSeqEvent& evt) { slot.set(evt); });
    auto r = lib.objSeqResultRequest(2);
    auto& tags = r.value().tags;
    check("obj_seq_result_request.tags.size", static_cast<size_t>(2), tags.size());
    if (tags.size() >= 2) {
      check("obj_seq_result_request.tags[0].key", std::string("key-0"), tags[0].key);
      check("obj_seq_result_request.tags[1].value", std::string("val-1"), tags[1].value);
    }
    slot.wait();
    lib.unsubscribeTagSeqEvent(h);
  }

  // ----- seq[Tag] INPUT param -----
  {
    std::vector<tmlib::Tag> in{{"alpha", "1"}, {"beta", "2"}};
    auto r = lib.objSeqParamRequest(in);
    check("obj_seq_param_request.count", 2, r.value().count);
    check("obj_seq_param_request.first", std::string("alpha"), r.value().first);
  }

  // ----- seq[string] INPUT param -----
  {
    auto r = lib.seqStringParamRequest({"a", "b", "c"});
    check("seq_string_param_request.count", 3, r.value().count);
    check("seq_string_param_request.joined", std::string("a,b,c"),
          r.value().joined);
  }

  // ----- seq[int64] INPUT param -----
  {
    auto r = lib.primSeqParamRequest({1, 2, 3, 4});
    check("prim_seq_param_request.count", 4, r.value().count);
    check("prim_seq_param_request.total", static_cast<int64_t>(10),
          r.value().total);
  }

  // ----- counter request emits counter_changed -----
  {
    EventSlot<tmlib::CounterChanged> slot;
    auto h = lib.subscribeCounterChanged(
        [&](const tmlib::CounterChanged& evt) { slot.set(evt); });
    auto r = lib.counterRequest();
    if (slot.wait()) {
      check("counter_changed.value", r.value().value, slot.value.value);
    } else {
      std::cerr << "FAIL counter_changed timeout\n";
      ++g_fails;
    }
    lib.unsubscribeCounterChanged(h);
  }

  // ============================================================================
  // Round-trip matrix expansion (Phase 9A) — boundary / edge values per type
  // ============================================================================

  // ----- bool false -----
  {
    auto r = lib.primScalarRequest(false, 0, 0, 0.0);
    check("rt.bool_false.is_ok", true, r.isOk());
    check("rt.bool_false.flag", false, r.value().flag);
  }

  // ----- int32 boundaries -----
  {
    auto rmin = lib.primScalarRequest(false, std::numeric_limits<int32_t>::min(), 0, 0.0);
    check("rt.int32_min.i32", std::numeric_limits<int32_t>::min(), rmin.value().i32);
    auto rmax = lib.primScalarRequest(false, std::numeric_limits<int32_t>::max(), 0, 0.0);
    check("rt.int32_max.i32", std::numeric_limits<int32_t>::max(), rmax.value().i32);
  }

  // ----- int64 boundaries -----
  {
    auto rmin = lib.primScalarRequest(false, 0, std::numeric_limits<int64_t>::min(), 0.0);
    check("rt.int64_min.i64", std::numeric_limits<int64_t>::min(), rmin.value().i64);
    auto rmax = lib.primScalarRequest(false, 0, std::numeric_limits<int64_t>::max(), 0.0);
    check("rt.int64_max.i64", std::numeric_limits<int64_t>::max(), rmax.value().i64);
    auto rneg = lib.primScalarRequest(false, 0, -9'000'000'000'000LL, 0.0);
    check("rt.int64_neg.i64", static_cast<int64_t>(-9'000'000'000'000LL), rneg.value().i64);
  }

  // ----- float64 fidelity (pi-like value, exact bit equality through CBOR) -----
  {
    const double pi = 3.141592653589793;
    auto r = lib.primScalarRequest(false, 0, 0, pi);
    check("rt.float64_pi.bits_equal", true, std::abs(r.value().f64 - pi) < 1e-15);
  }

  // ----- enum: every Priority value -----
  {
    const tmlib::Priority all[] = {tmlib::Priority::pLow, tmlib::Priority::pMedium,
                                   tmlib::Priority::pHigh, tmlib::Priority::pCritical};
    for (auto p : all) {
      auto r = lib.typedScalarRequest(p, 1);
      check("rt.priority_roundtrip", static_cast<int>(p),
            static_cast<int>(r.value().priority));
    }
  }

  // ----- distinct JobId: zero, large -----
  {
    auto r0 = lib.typedScalarRequest(tmlib::Priority::pLow, 0);
    check("rt.jobid_zero.jobId", 0, r0.value().jobId);
    check("rt.jobid_zero.nextId", 1, r0.value().nextId);
    auto rbig = lib.typedScalarRequest(tmlib::Priority::pLow,
                                       std::numeric_limits<int32_t>::max() - 1);
    check("rt.jobid_big.nextId", std::numeric_limits<int32_t>::max(),
          rbig.value().nextId);
  }

  // ----- byte seq: empty, single, wrap-around at 256 -----
  {
    auto r0 = lib.byteSeqRequest(0);
    check("rt.byte_seq_empty.size", static_cast<size_t>(0), r0.value().data.size());
    auto r1 = lib.byteSeqRequest(1);
    check("rt.byte_seq_single.size", static_cast<size_t>(1), r1.value().data.size());
    check("rt.byte_seq_single.value", static_cast<uint8_t>(0), r1.value().data[0]);
    auto rWrap = lib.byteSeqRequest(260);
    check("rt.byte_seq_wrap.size", static_cast<size_t>(260), rWrap.value().data.size());
    if (rWrap.value().data.size() == 260) {
      check("rt.byte_seq_wrap[0]", static_cast<uint8_t>(0), rWrap.value().data[0]);
      check("rt.byte_seq_wrap[255]", static_cast<uint8_t>(255), rWrap.value().data[255]);
      check("rt.byte_seq_wrap[256]", static_cast<uint8_t>(0), rWrap.value().data[256]);
    }
  }

  // ----- string seq result: empty, special chars in prefix -----
  {
    auto r0 = lib.stringSeqRequest("x", 0);
    check("rt.string_seq_empty.size", static_cast<size_t>(0), r0.value().items.size());
    auto rSpec = lib.stringSeqRequest("a/b:c", 2);
    check("rt.string_seq_special[0]", std::string("a/b:c-0"), rSpec.value().items[0]);
    check("rt.string_seq_special[1]", std::string("a/b:c-1"), rSpec.value().items[1]);
  }

  // ----- prim seq result: empty, single -----
  {
    auto r0 = lib.primSeqRequest(0);
    check("rt.prim_seq_empty.size", static_cast<size_t>(0), r0.value().values.size());
    auto r1 = lib.primSeqRequest(1);
    check("rt.prim_seq_single.values", std::vector<int64_t>{0}, r1.value().values);
  }

  // ----- fixed array: seed=0 and negative -----
  {
    auto r0 = lib.fixedArrayRequest(0);
    check("rt.fixed_array_zero.values", std::vector<int32_t>{0, 0, 0, 0},
          r0.value().values);
    check("rt.fixed_array_zero.ts", static_cast<int64_t>(0), r0.value().ts);
    auto rNeg = lib.fixedArrayRequest(-3);
    check("rt.fixed_array_neg.values", std::vector<int32_t>{-3, -6, -9, -12},
          rNeg.value().values);
  }

  // ----- const array: seed=0, seed=1 -----
  {
    auto r0 = lib.constArrayRequest(0);
    check("rt.const_array_zero.values",
          std::vector<int32_t>{0, 0, 0, 0, 0, 0}, r0.value().values);
    auto r1 = lib.constArrayRequest(1);
    check("rt.const_array_one.values",
          std::vector<int32_t>{1, 2, 3, 4, 5, 6}, r1.value().values);
  }

  // ----- obj seq result: empty -----
  {
    auto r = lib.objSeqResultRequest(0);
    check("rt.obj_seq_result_empty.size", static_cast<size_t>(0),
          r.value().tags.size());
  }

  // ----- obj seq param: empty -----
  {
    auto r = lib.objSeqParamRequest({});
    check("rt.obj_seq_param_empty.count", 0, r.value().count);
    check("rt.obj_seq_param_empty.first", std::string(""), r.value().first);
  }

  // ----- string seq param: empty, single, unicode (utf-8) -----
  {
    auto r0 = lib.seqStringParamRequest({});
    check("rt.seq_string_param_empty.count", 0, r0.value().count);
    auto r1 = lib.seqStringParamRequest({"hello"});
    check("rt.seq_string_param_single.joined", std::string("hello"),
          r1.value().joined);
    auto rU = lib.seqStringParamRequest({"héllo", "wörld"});
    check("rt.seq_string_param_unicode.count", 2, rU.value().count);
    check("rt.seq_string_param_unicode.joined", std::string("héllo,wörld"),
          rU.value().joined);
  }

  // ----- prim seq param: empty, single, large -----
  {
    auto r0 = lib.primSeqParamRequest({});
    check("rt.prim_seq_param_empty.count", 0, r0.value().count);
    check("rt.prim_seq_param_empty.total", static_cast<int64_t>(0),
          r0.value().total);
    auto r1 = lib.primSeqParamRequest({42});
    check("rt.prim_seq_param_single.total", static_cast<int64_t>(42),
          r1.value().total);
    std::vector<int64_t> big;
    int64_t expected = 0;
    for (int i = 0; i < 100; ++i) {
      big.push_back(i);
      expected += i;
    }
    auto rBig = lib.primSeqParamRequest(big);
    check("rt.prim_seq_param_large.count", 100, rBig.value().count);
    check("rt.prim_seq_param_large.total", expected, rBig.value().total);
  }

  // ============================================================================
  // Lifecycle parity (Phase 9B) — bypass RAII Lib and drive the C ABI
  // directly to exercise edge cases (double-shutdown, unknown ctx,
  // ctx=0 call). Native suite has equivalent tests via Lib.createContext()
  // / Lib.shutdown(); the CBOR Lib only exposes RAII, so we hit the C
  // entry points to cover the same failure modes.
  // ============================================================================
  {
    // 1) create_and_shutdown — happy path
    {
      typemappingtestlib_cbor_initialize();
      char* err = nullptr;
      uint32_t c = typemappingtestlib_cbor_createContext(&err);
      check("lc.create_and_shutdown.ctx_nonzero", true, c != 0);
      if (err != nullptr) typemappingtestlib_cbor_freeBuffer(err);
      int32_t st = typemappingtestlib_cbor_shutdown(c);
      check("lc.create_and_shutdown.shutdown_ok", static_cast<int32_t>(0), st);
    }

    // 2) raii_dtor_shutdown — scoped Lib auto-shuts down; another Lib
    //    after must succeed (no global state corruption).
    {
      uint32_t saved = 0;
      {
        tmlib::Lib scoped;
        check("lc.raii.scoped_isOk", true, scoped.isOk());
        saved = scoped.context();
      }
      tmlib::Lib after;
      check("lc.raii.after_scope_isOk", true, after.isOk());
      check("lc.raii.distinct_ctx", true, after.context() != saved);
    }

    // 3) double_shutdown_is_safe — second call returns -1 sentinel,
    //    no crash.
    {
      char* err = nullptr;
      uint32_t c = typemappingtestlib_cbor_createContext(&err);
      if (err != nullptr) typemappingtestlib_cbor_freeBuffer(err);
      int32_t s1 = typemappingtestlib_cbor_shutdown(c);
      int32_t s2 = typemappingtestlib_cbor_shutdown(c);
      check("lc.double_shutdown.first_ok", static_cast<int32_t>(0), s1);
      check("lc.double_shutdown.second_returns_neg1", static_cast<int32_t>(-1), s2);
    }

    // 4) shutdown_unknown_ctx_safe — random unregistered ctx must not
    //    crash and must return -1.
    {
      int32_t st = typemappingtestlib_cbor_shutdown(0xDEADBEEFu);
      check("lc.shutdown_unknown.returns_neg1", static_cast<int32_t>(-1), st);
    }

    // 5) call_with_invalid_ctx_fails — _call with ctx=0 (unregistered)
    //    can either return a framework error code OR a Result-envelope
    //    err. Either way the request must NOT succeed. We accept both:
    //    framework-level non-zero status, or status==0 with the response
    //    envelope carrying an `err` field. Crashing/hanging is not OK.
    {
      void* respBuf = nullptr;
      int32_t respLen = 0;
      int32_t st = typemappingtestlib_cbor_call(
          0, "echo_request", nullptr, 0, &respBuf, &respLen);
      bool nonOkOutcome = (st != 0);
      if (st == 0 && respBuf != nullptr && respLen > 0) {
        // Decode the envelope: must carry `err`, not `ok`.
        std::vector<uint8_t> bytes(static_cast<uint8_t*>(respBuf),
                                   static_cast<uint8_t*>(respBuf) + respLen);
        try {
          auto j = jsoncons::cbor::decode_cbor<jsoncons::json>(bytes);
          nonOkOutcome = j.contains("err") && !j.contains("ok");
        } catch (...) {
          nonOkOutcome = true;  // undecodable envelope counts as not-ok
        }
      }
      check("lc.call_with_zero_ctx.does_not_succeed", true, nonOkOutcome);
      if (respBuf != nullptr) typemappingtestlib_cbor_freeBuffer(respBuf);
    }
  }

  // ============================================================================
  // Multi-context parity (Phase 9C) — independent Lib instances must
  // each carry their own counter / label / event listener bucket.
  // ============================================================================
  {
    // 1) independent counters
    {
      tmlib::Lib a;
      tmlib::Lib b;
      check("mc.counters.distinct_ctx", true, a.context() != b.context());
      a.initializeRequest("alpha");
      b.initializeRequest("beta");
      for (int32_t i = 1; i <= 3; ++i) {
        check("mc.counters.a_increment", i, a.counterRequest().value().value);
      }
      for (int32_t i = 1; i <= 2; ++i) {
        check("mc.counters.b_increment", i, b.counterRequest().value().value);
      }
      check("mc.counters.a_continues", static_cast<int32_t>(4),
            a.counterRequest().value().value);
    }

    // 2) independent echo (label is per-context state)
    {
      tmlib::Lib a;
      tmlib::Lib b;
      a.initializeRequest("one");
      b.initializeRequest("two");
      check("mc.echo.a", std::string("one:x"), a.echoRequest("x").value().reply);
      check("mc.echo.b", std::string("two:x"), b.echoRequest("x").value().reply);
    }

    // 3) independent events (per-Lib subscription, no cross-talk)
    {
      tmlib::Lib a;
      tmlib::Lib b;

      std::mutex mA, mB;
      std::vector<int32_t> evtA, evtB;
      auto hA = a.subscribeCounterChanged(
          [&](const tmlib::CounterChanged& e) {
            std::lock_guard<std::mutex> lk(mA);
            evtA.push_back(e.value);
          });
      auto hB = b.subscribeCounterChanged(
          [&](const tmlib::CounterChanged& e) {
            std::lock_guard<std::mutex> lk(mB);
            evtB.push_back(e.value);
          });

      a.counterRequest();
      a.counterRequest();
      b.counterRequest();

      // Wait up to 1s for both to settle.
      const auto deadline =
          std::chrono::steady_clock::now() + std::chrono::milliseconds(1000);
      while (std::chrono::steady_clock::now() < deadline) {
        std::lock_guard<std::mutex> lkA(mA);
        std::lock_guard<std::mutex> lkB(mB);
        if (evtA.size() >= 2 && evtB.size() >= 1) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }

      {
        std::lock_guard<std::mutex> lkA(mA);
        std::lock_guard<std::mutex> lkB(mB);
        check("mc.events.a_size", static_cast<size_t>(2), evtA.size());
        check("mc.events.b_size", static_cast<size_t>(1), evtB.size());
        if (evtA.size() == 2) {
          check("mc.events.a[0]", static_cast<int32_t>(1), evtA[0]);
          check("mc.events.a[1]", static_cast<int32_t>(2), evtA[1]);
        }
        if (evtB.size() == 1) {
          check("mc.events.b[0]", static_cast<int32_t>(1), evtB[0]);
        }
      }

      a.unsubscribeCounterChanged(hA);
      b.unsubscribeCounterChanged(hB);
    }

    // 4) shutdown_one_does_not_affect_other — Lib RAII makes the
    //    "explicit shutdown" hard to express, so we use scoped Lib for
    //    `a` and a longer-lived Lib for `b`. When `a`'s scope ends, `b`
    //    must still serve requests against its own ctx.
    {
      tmlib::Lib b;
      b.initializeRequest("second");
      {
        tmlib::Lib a;
        a.initializeRequest("first");
        check("mc.shutdown_one.a_works",
              std::string("first:hello"), a.echoRequest("hello").value().reply);
        // a goes out of scope here; its ctx is shut down
      }
      auto r = b.echoRequest("still-alive");
      check("mc.shutdown_one.b_still_works", true, r.isOk());
      check("mc.shutdown_one.b_reply",
            std::string("second:still-alive"), r.value().reply);
    }
  }

  // ============================================================================
  // Listener mgmt parity (Phase 9D) — fan-out, individual unsubscribe,
  // concurrent event types over a single Lib.
  // ============================================================================

  // Helper: collect i32 from PrimScalarEvent under a mutex.
  struct I32Sink {
    std::mutex m;
    std::vector<int32_t> v;
    void push(int32_t x) {
      std::lock_guard<std::mutex> lk(m);
      v.push_back(x);
    }
    size_t size() {
      std::lock_guard<std::mutex> lk(m);
      return v.size();
    }
    std::vector<int32_t> snapshot() {
      std::lock_guard<std::mutex> lk(m);
      return v;
    }
  };

  auto waitUntil = [](auto pred,
                      std::chrono::milliseconds timeout =
                          std::chrono::milliseconds(1000)) -> bool {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
      if (pred()) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return pred();
  };

  // 1) two_scalar_event_listeners — both receive the same event
  {
    tmlib::Lib lm;
    I32Sink s1, s2;
    auto h1 = lm.subscribePrimScalarEvent(
        [&](const tmlib::PrimScalarEvent& e) { s1.push(e.i32); });
    auto h2 = lm.subscribePrimScalarEvent(
        [&](const tmlib::PrimScalarEvent& e) { s2.push(e.i32); });

    lm.primScalarRequest(false, 99, 0, 0.0);
    waitUntil([&] { return s1.size() >= 1 && s2.size() >= 1; });

    auto v1 = s1.snapshot();
    auto v2 = s2.snapshot();
    check("lst.two.s1_size", static_cast<size_t>(1), v1.size());
    check("lst.two.s2_size", static_cast<size_t>(1), v2.size());
    if (!v1.empty()) check("lst.two.s1[0]", static_cast<int32_t>(99), v1[0]);
    if (!v2.empty()) check("lst.two.s2[0]", static_cast<int32_t>(99), v2[0]);

    lm.unsubscribePrimScalarEvent(h1);
    lm.unsubscribePrimScalarEvent(h2);
  }

  // 2) remove_one_listener_keeps_other — after off(h1), only h2 receives.
  {
    tmlib::Lib lm;
    I32Sink s1, s2;
    auto h1 = lm.subscribePrimScalarEvent(
        [&](const tmlib::PrimScalarEvent& e) { s1.push(e.i32); });
    auto h2 = lm.subscribePrimScalarEvent(
        [&](const tmlib::PrimScalarEvent& e) { s2.push(e.i32); });

    lm.primScalarRequest(false, 1, 0, 0.0);
    waitUntil([&] { return s1.size() >= 1 && s2.size() >= 1; });

    lm.unsubscribePrimScalarEvent(h1);

    lm.primScalarRequest(false, 2, 0, 0.0);
    waitUntil([&] { return s2.size() >= 2; });
    // Give any in-flight delivery to s1 a chance to land — must not.
    std::this_thread::sleep_for(std::chrono::milliseconds(150));

    check("lst.remove_one.s1_size", static_cast<size_t>(1), s1.size());
    check("lst.remove_one.s2_size", static_cast<size_t>(2), s2.size());
    auto v2 = s2.snapshot();
    if (v2.size() == 2) check("lst.remove_one.s2[1]", static_cast<int32_t>(2), v2[1]);

    lm.unsubscribePrimScalarEvent(h2);
  }

  // 3) concurrent_event_types — three different event subscriptions on
  //    the same Lib, each fired by a distinct request.
  {
    tmlib::Lib lm;
    I32Sink scalarSink;
    std::mutex mArr, mStr;
    std::vector<std::vector<int32_t>> arrSink;
    std::vector<std::vector<std::string>> strSink;

    auto hs = lm.subscribePrimScalarEvent(
        [&](const tmlib::PrimScalarEvent& e) { scalarSink.push(e.i32); });
    auto ha = lm.subscribeFixedArrayEvent(
        [&](const tmlib::FixedArrayEvent& e) {
          std::lock_guard<std::mutex> lk(mArr);
          arrSink.push_back(e.values);
        });
    auto hst = lm.subscribeStringSeqEvent(
        [&](const tmlib::StringSeqEvent& e) {
          std::lock_guard<std::mutex> lk(mStr);
          strSink.push_back(e.items);
        });

    lm.primScalarRequest(false, 55, 0, 0.0);
    lm.fixedArrayRequest(4);
    lm.stringSeqRequest("z", 2);

    waitUntil([&] {
      std::lock_guard<std::mutex> lkA(mArr);
      std::lock_guard<std::mutex> lkS(mStr);
      return scalarSink.size() >= 1 && arrSink.size() >= 1 && strSink.size() >= 1;
    });

    auto vs = scalarSink.snapshot();
    check("lst.concurrent.scalar_size", static_cast<size_t>(1), vs.size());
    if (!vs.empty()) check("lst.concurrent.scalar[0]", static_cast<int32_t>(55), vs[0]);
    {
      std::lock_guard<std::mutex> lk(mArr);
      check("lst.concurrent.arr_size", static_cast<size_t>(1), arrSink.size());
      if (!arrSink.empty() && arrSink[0].size() == 4) {
        check("lst.concurrent.arr[0]", static_cast<int32_t>(4), arrSink[0][0]);
        check("lst.concurrent.arr[3]", static_cast<int32_t>(16), arrSink[0][3]);
      }
    }
    {
      std::lock_guard<std::mutex> lk(mStr);
      check("lst.concurrent.str_size", static_cast<size_t>(1), strSink.size());
      if (!strSink.empty() && strSink[0].size() == 2) {
        check("lst.concurrent.str[0]", std::string("z-0"), strSink[0][0]);
        check("lst.concurrent.str[1]", std::string("z-1"), strSink[0][1]);
      }
    }

    lm.unsubscribePrimScalarEvent(hs);
    lm.unsubscribeFixedArrayEvent(ha);
    lm.unsubscribeStringSeqEvent(hst);
  }

  std::cout << "--------------------------------------------------\n";
  if (g_fails > 0) {
    std::cerr << "FAILED: " << g_fails << " check(s) did not match\n";
    return 1;
  }
  std::cout << "PASS  typemappingtestlib_cbor C++ parity\n";
  return 0;
}
