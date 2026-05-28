// C++ consumer for the persistence interface-model FFI example.
//
// Demonstrates two layers of interfaces (IPersistence -> IBackend), a factory
// that picks the concrete backend by input, requests + events at BOTH levels,
// coexisting backends with per-instance request routing and per-subscription
// event delivery, and targeted Nim-side teardown — all while ensuring no
// context is mismatched during routing.
#include "persistence.hpp"

#include <atomic>
#include <cassert>
#include <chrono>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <thread>

using namespace persistence;

namespace {
constexpr int32_t KIND_MEMORY = 0;
constexpr int32_t KIND_FILE = 1;

// Spin-wait (with timeout) for a delivery-thread event to land.
template <typename Pred>
bool waitFor(Pred p, std::chrono::milliseconds timeout = std::chrono::milliseconds(2000)) {
  auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!p() && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  return p();
}

// A backend's read result, populated from its ReadCompleted event.
struct ReadSink {
  std::mutex m;
  std::string value;
  bool found = false;
  std::atomic<int> count{0};
  void set(std::string_view v, bool f) {
    std::lock_guard<std::mutex> lk(m);
    value = std::string(v);
    found = f;
    count.fetch_add(1);
  }
};

// Store then read a key on a backend, returning the value delivered via event.
std::string roundtrip(Backend& b, const std::string& key, const std::string& val) {
  ReadSink sink;
  auto h = b.onReadCompleted(
      [&](Backend&, std::string_view, std::string_view v, bool f) { sink.set(v, f); });
  assert(h != 0);
  assert(b.store(key, val).isOk());
  const int before = sink.count.load();
  assert(b.read(key).isOk());
  assert(waitFor([&] { return sink.count.load() > before; }) && "read event timed out");
  b.offReadCompleted(h);
  std::lock_guard<std::mutex> lk(sink.m);
  assert(sink.found && "expected key to be found");
  return sink.value;
}
} // namespace

// Scenario A: two independent IPersistence contexts, each its own backend kind,
// each issuing store/read whose result arrives via an async event.
static void scenarioTwoContexts() {
  std::cout << "  [A] two IPersistence contexts (File + Memory)\n";

  Persistence pFile;
  assert(pFile.createContext().isOk());
  assert(pFile.initializeRequest("cfg").isOk());
  auto bf = std::move(pFile.makeBackend(KIND_FILE).take());
  assert(bf && bf->ctx() != 0);
  assert(roundtrip(*bf, "alpha", "file-payload") == "file-payload");

  Persistence pMem;
  assert(pMem.createContext().isOk());
  assert(pMem.initializeRequest("cfg").isOk());
  auto bm = std::move(pMem.makeBackend(KIND_MEMORY).take());
  assert(bm && bm->ctx() != 0);
  assert(roundtrip(*bm, "alpha", "memory-payload") == "memory-payload");

  // Distinct library contexts → distinct classCtx (low16).
  assert((bf->ctx() & 0xFFFFu) != (bm->ctx() & 0xFFFFu));

  pFile.shutdown();
  pMem.shutdown();
}

// Scenario B: ONE IPersistence context with BOTH backends coexisting — the
// strong "no context mismatch" test: the two sub-instances share the library
// classCtx and differ only by instanceCtx, so routing must keep them apart.
static void scenarioMixedOneContext() {
  std::cout << "  [B] one IPersistence context, File + Memory backends coexisting\n";

  Persistence p;
  assert(p.createContext().isOk());
  assert(p.initializeRequest("cfg").isOk());

  // BackendCreated (main-level event) fires for each makeBackend.
  std::atomic<int> created{0};
  auto ch = p.onBackendCreated([&](Persistence&, uint32_t, int32_t) { created.fetch_add(1); });

  auto bf = std::move(p.makeBackend(KIND_FILE).take());
  auto bm = std::move(p.makeBackend(KIND_MEMORY).take());
  assert(waitFor([&] { return created.load() == 2; }) && "BackendCreated events");
  p.offBackendCreated(ch);

  // Routing invariant: both backends share the persistence classCtx, differ in
  // instanceCtx, and neither equals the library ctx.
  assert((bf->ctx() & 0xFFFFu) == (p.ctx() & 0xFFFFu));
  assert((bm->ctx() & 0xFFFFu) == (p.ctx() & 0xFFFFu));
  assert((bf->ctx() >> 16) != (bm->ctx() >> 16));
  assert(bf->ctx() != bm->ctx());

  // Per-instance request routing + per-subscription event delivery: each
  // backend's read result comes back on ITS OWN subscriber, no crossing.
  assert(roundtrip(*bf, "x", "FILE-X") == "FILE-X");
  assert(roundtrip(*bm, "x", "MEM-X") == "MEM-X");

  // State check: both backends listed and alive.
  {
    auto st = p.listBackends();
    assert(st.isOk());
    const auto& items = st.value().backends;
    assert(items.size() == 2);
    for (const auto& it : items)
      assert(it.alive);
  }

  // Targeted teardown: terminate the File backend; the Memory one is untouched.
  assert(p.terminateBackend(bf->ctx()).isOk());
  {
    auto st = p.listBackends();
    assert(st.isOk());
    bool fileDead = false, memAlive = false;
    for (const auto& it : st.value().backends) {
      if (it.handle == bf->ctx())
        fileDead = !it.alive;
      if (it.handle == bm->ctx())
        memAlive = it.alive;
    }
    assert(fileDead && "File backend should be terminated");
    assert(memAlive && "Memory backend should still be alive");
  }

  // The terminated backend's providers are gone → its requests now error;
  // the sibling keeps working (no collateral teardown, no context mismatch).
  assert(bf->store("y", "z").isErr() && "terminated backend must reject requests");
  assert(roundtrip(*bm, "y", "MEM-Y") == "MEM-Y");

  // Releasing an already-terminated backend wrapper is safe (idempotent).
  bf->close();
  p.shutdown();
}

// Scenario C: TWO IPersistence library contexts live and run AT THE SAME TIME,
// each on its own thread, each driving its own backend under a load of many
// store/read operations whose results arrive via random-delayed async events.
// Verifies that concurrent contexts + variable impl timing never cross results.
static void scenarioConcurrentLoad() {
  constexpr int N = 30;
  std::cout << "  [C] two IPersistence contexts running concurrently, " << N
            << " roundtrips each under load\n";

  // Drives one library context end-to-end on its own thread. `okCount` receives
  // the number of correctly round-tripped (store -> read -> async event) ops.
  auto runLib = [](int32_t kind, std::string tag, std::atomic<int>& okCount) {
    Persistence p;
    if (!p.createContext().isOk())
      return;
    p.initializeRequest("cfg");
    auto be = std::move(p.makeBackend(kind).take());
    if (!be)
      return;

    std::mutex m;
    std::map<std::string, std::string> results; // key -> value, from events
    auto h = be->onReadCompleted(
        [&](Backend&, std::string_view k, std::string_view v, bool) {
          std::lock_guard<std::mutex> lk(m);
          results[std::string(k)] = std::string(v);
        });

    int local = 0;
    for (int i = 0; i < N; ++i) {
      const std::string key = tag + "_" + std::to_string(i);
      const std::string val = tag + "_val_" + std::to_string(i);
      if (!be->store(key, val).isOk())
        continue;
      if (!be->read(key).isOk())
        continue;
      const bool got = waitFor(
          [&] {
            std::lock_guard<std::mutex> lk(m);
            return results.count(key) > 0;
          },
          std::chrono::milliseconds(3000));
      if (got) {
        std::lock_guard<std::mutex> lk(m);
        if (results[key] == val)
          ++local;
      }
    }
    be->offReadCompleted(h);
    okCount.fetch_add(local);
    p.shutdown();
  };

  std::atomic<int> okFile{0}, okMem{0};
  std::thread tFile(runLib, KIND_FILE, std::string("fileLib"), std::ref(okFile));
  std::thread tMem(runLib, KIND_MEMORY, std::string("memLib"), std::ref(okMem));
  tFile.join();
  tMem.join();

  std::cout << "      File lib: " << okFile.load() << "/" << N
            << "  Memory lib: " << okMem.load() << "/" << N << " roundtrips OK\n";
  assert(okFile.load() == N && "all File-lib roundtrips correct under concurrent load");
  assert(okMem.load() == N && "all Memory-lib roundtrips correct under concurrent load");
}

int main() {
  std::cout << "persistence version: " << Persistence::version() << "\n";
  scenarioTwoContexts();
  scenarioMixedOneContext();
  scenarioConcurrentLoad();
  std::cout << "persistence cpp example: OK\n";
  return 0;
}
