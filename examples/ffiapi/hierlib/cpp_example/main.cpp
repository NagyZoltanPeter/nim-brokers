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

  std::atomic<int> received{-1};
  auto handle = lib.onTick([&](Hierlib&, int32_t n) { received.store(n); });
  assert(handle != 0);

  assert(lib.fireTick(99).value() == 99);

  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (received.load() < 0 && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  assert(received.load() == 99);

  lib.offTick(handle);
  lib.shutdown();
  std::cout << "hierlib cpp example: OK\n";
  return 0;
}
