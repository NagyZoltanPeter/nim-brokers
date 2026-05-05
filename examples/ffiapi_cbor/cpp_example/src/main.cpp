// Example C++ consumer of the CBOR-mode FFI library.
//
// Exercises every flavor of the generated typed wrapper:
// - Lib RAII lifecycle (createContext / shutdown via destructor)
// - Zero-arg request (getStatus)
// - Arg-based request (addNumbers)
// - Event subscribe with a typed lambda handler
// - Trigger a Nim-side emit through a request and verify delivery
// - Unsubscribe and exit
//
// Build via the bundled CMakeLists.txt. The generated mylibcbor.h and
// mylibcbor.hpp live next to the shared library under
// examples/ffiapi_cbor/nimlib/build/.

#include "mylibcbor.hpp"

#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>

namespace {

void waitForDeliveries(std::atomic<int>& counter, int target,
                       std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (counter.load() < target &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
}

}  // namespace

int main() {
  mylibcbor::Lib lib;
  if (!lib.isOk()) {
    std::cerr << "createContext failed: " << lib.lastError() << std::endl;
    return 1;
  }

  // ----- Zero-arg request -----
  auto status = lib.getStatus();
  if (status.isErr()) {
    std::cerr << "getStatus failed: " << status.error() << std::endl;
    return 2;
  }
  std::cout << "[getStatus] online=" << status.value().online
            << " counter=" << status.value().counter
            << " label=\"" << status.value().label << "\"\n";

  // ----- Arg-based request -----
  auto sum = lib.addNumbers(40, 2);
  if (sum.isErr()) {
    std::cerr << "addNumbers failed: " << sum.error() << std::endl;
    return 3;
  }
  std::cout << "[addNumbers] 40 + 2 = " << sum.value().sum << "\n";

  // ----- Event subscribe + emit + delivery -----
  std::atomic<int> deliveryCount{0};
  int64_t lastDeviceId = 0;
  bool lastOnline = false;

  uint64_t handle = lib.subscribeDeviceUpdated(
      [&](const mylibcbor::DeviceUpdated& evt) {
        lastDeviceId = evt.deviceId;
        lastOnline = evt.online;
        deliveryCount.fetch_add(1);
      });
  if (handle == 0) {
    std::cerr << "subscribe failed: " << lib.lastError() << std::endl;
    return 4;
  }
  std::cout << "[subscribe] device_updated handle=" << handle << "\n";

  auto fired = lib.fireDevice(0xC0FFEE, true);
  if (fired.isErr()) {
    std::cerr << "fireDevice failed: " << fired.error() << std::endl;
    return 5;
  }

  waitForDeliveries(deliveryCount, 1, std::chrono::milliseconds(500));
  std::cout << "[delivered] count=" << deliveryCount.load()
            << " deviceId=0x" << std::hex << lastDeviceId
            << std::dec << " online=" << lastOnline << "\n";
  if (deliveryCount.load() != 1 || lastDeviceId != 0xC0FFEE || !lastOnline) {
    std::cerr << "event delivery did not match expectations\n";
    return 6;
  }

  auto unsubStatus = lib.unsubscribeDeviceUpdated(handle);
  std::cout << "[unsubscribe] status=" << unsubStatus << "\n";
  if (unsubStatus != 0) {
    return 7;
  }

  uint64_t probe =
      mylibcbor_subscribe(lib.context(), "no_such_event", nullptr, nullptr);
  std::cout << "[probe missing] no_such_event -> " << probe
            << " (expected 0)\n";

  return 0;
}
