// EXTAPI example — the `storage` plugin in C++ (C1: implement the generated
// abstract class). Built as a shared library; the Nim host loads it with
// ExtHost.loadPlugin(path), which calls broker_ext_plugin_entry().
//
// Uses only the generated storage_ext.hpp (+ broker_ext.h); no Nim, no CBOR
// by hand.

#include "storage_ext.hpp"

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#if defined(_WIN32)
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

using namespace storage_ext;

namespace {

std::atomic<int> gCancels{0};

class CppStorage final : public IStorage {
public:
  void setEmitter(Emitter e) {
    std::lock_guard<std::mutex> g(m_);
    emitter_ = e;
  }

  // Quick requests: answer inline (bridge dispatch requires NONBLOCKING).
  void fetchBlob(std::string key, Responder<FetchBlob> r) override {
    FetchBlob b;
    std::string v = "cpp:" + key;
    b.data.assign(v.begin(), v.end());
    r.ok(b);
  }

  void storeBlob(std::string key, Bytes data, Responder<StoreBlob> r) override {
    r.ok(StoreBlob{"etag-" + key + "-" + std::to_string(data.size())});
  }

  // Not provided by this plugin (the port never calls provide for it).
  void listKeys(Responder<ListKeys> r) override { r.err("not provided"); }

  // Slow: work on our own thread, honour the stop_token (cancel / timeout).
  void compact(int32_t level, Responder<Compact> r) override {
    std::thread([level, r = std::move(r)]() mutable {
      auto st = r.stop_token();
      for (int i = 0; i < 200; ++i) {
        if (st.stop_requested()) {
          gCancels.fetch_add(1);
          return; // dropping r replies err("dropped"); the host drops it by id
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      r.ok(Compact{static_cast<int64_t>(level) * 1024});
    }).detach();
  }

  // One-way: react by emitting an event from another thread.
  void compactHint(CompactHint h) override {
    Emitter e;
    {
      std::lock_guard<std::mutex> g(m_);
      e = emitter_;
    }
    std::thread([e, h]() {
      e.blobEvicted(BlobEvicted{"k" + std::to_string(h.urgency), "compact"});
    }).detach();
  }

private:
  std::mutex m_;
  Emitter emitter_;
};

std::mutex gPortMutex;
std::unique_ptr<Port> gPort;
std::shared_ptr<CppStorage> gImpl = std::make_shared<CppStorage>();

int32_t attach(const broker_ext_host* host, uint32_t ctx) {
  std::lock_guard<std::mutex> g(gPortMutex);
  auto p = Port::open(host, ctx, gImpl);
  if (!p) return BROKER_EXT_BAD_ARG;
  // Provide individually: list_keys is deliberately left out.
  for (Api a : {Api::FetchBlob, Api::StoreBlob, Api::Compact, Api::CompactHint}) {
    int32_t rc = p.value().provide(a);
    if (rc != BROKER_EXT_OK) return rc;
  }
  gImpl->setEmitter(p.value().emitter());
  gPort = std::make_unique<Port>(std::move(p.value()));
  return BROKER_EXT_OK;
}

} // namespace

// Exe mode entry point, called by ExtHost.loadPlugin(). Opens on
// DefaultBrokerContext (1).
EXPORT int32_t broker_ext_plugin_entry(const broker_ext_host* host) {
  return attach(host, 1);
}

// Example-specific controls (scenario 2: detach / re-attach at runtime).
EXPORT int32_t storage_plugin_attach(const broker_ext_host* host, uint32_t ctx) {
  return attach(host, ctx);
}

EXPORT int32_t storage_plugin_detach() {
  std::lock_guard<std::mutex> g(gPortMutex);
  if (gPort) gPort->close();
  gPort.reset();
  return BROKER_EXT_OK;
}

EXPORT int32_t storage_plugin_cancels() { return gCancels.load(); }
