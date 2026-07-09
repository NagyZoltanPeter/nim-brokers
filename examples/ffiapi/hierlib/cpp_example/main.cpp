// C++ consumer for the hierlib interface-model FFI example.
// Mirrors python_example/main.py: lifecycle + requests + an event emitted
// through the interface facade (fireTick -> Tick -> onTick callback).
#include "hierlib.hpp"

#include <atomic>
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>

using namespace hierlib;

int main() {
  std::cout << "hierlib version: " << Hierlib::version() << "\n";

  Hierlib lib;
  assert(lib.createContext().isOk());
  assert(lib.initializeRequest("cfg").isOk());
  assert(lib.getValue().value() == 7);
  assert(lib.echoLen("abcd").value() == 4);

  // One-way signal (fire-and-forget, no response): nudge the value. The handler
  // runs on the processing thread, so poll getValue for the observable effect.
  assert(lib.nudgeSignal(10).isOk());
  {
    auto sigDl = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (lib.getValue().value() == 7 && std::chrono::steady_clock::now() < sigDl)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  assert(lib.getValue().value() == 17);

  std::atomic<int> received{-1};
  auto handle = lib.onTick([&](Hierlib&, int32_t n) { received.store(n); });
  assert(handle != 0);

  assert(lib.fireTick(99).value() == 99);

  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (received.load() < 0 && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  assert(received.load() == 99);

  lib.offTick(handle);

  // reduced-A: create a sub-interface instance, drive its own methods (routed
  // to the same processing thread via shared classCtx), then release it.
  {
    auto wr = lib.makeWidget(5);
    assert(wr.isOk());
    Widget widget = std::move(wr.take());
    assert(widget.ctx() != 0);
    assert(widget.area().value() == 25);
    assert(widget.scale(3).value() == 15);
    assert(widget.area().value() == 225);

    // A second, independent widget (own instanceCtx, same library).
    auto w2 = lib.makeWidget(2);
    assert(w2.isOk());
    assert(w2.value().area().value() == 4);

    widget.close();      // explicit release
    widget.close();      // idempotent
    assert(widget.area().isErr()); // post-release routes but has no provider
    // w2 released by its destructor at scope exit.
  }

  lib.shutdown();
  std::cout << "hierlib cpp example: OK\n";
  return 0;
}
