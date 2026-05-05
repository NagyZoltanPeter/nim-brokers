// C++ parity test for typemappingtestlib_cbor.
//
// Drives every typed wrapper method on the generated `Lib` class and
// every typed event subscribe path, asserting the round-trip values
// match the provider-side computation. C++ counterpart to the Nim and
// Python parity tests under this directory.

#include "typemappingtestlib_cbor.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iostream>
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

  std::cout << "--------------------------------------------------\n";
  if (g_fails > 0) {
    std::cerr << "FAILED: " << g_fails << " check(s) did not match\n";
    return 1;
  }
  std::cout << "PASS  typemappingtestlib_cbor C++ parity\n";
  return 0;
}
