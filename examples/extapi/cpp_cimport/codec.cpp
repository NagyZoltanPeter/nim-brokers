// EXTAPI example — scenario 4: a plain C-ABI library written in C++. It knows
// nothing about brokers; the Nim host imports its functions with
// RequestBroker(EXTAPI[codec], importc = ..., dynlib = ...).

#include <chrono>
#include <cstdint>
#include <thread>

#if defined(_WIN32)
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

EXPORT uint32_t codec_crc(uint32_t seed, const uint8_t* buf, uint32_t len) {
  uint32_t h = seed;
  for (uint32_t i = 0; i < len; ++i) h = h * 31u + buf[i];
  return h;
}

// Blocking on purpose: sleeps `ms`, then sums the bytes. 0 = ok.
EXPORT int32_t codec_slow_sum(const uint8_t* src, uint32_t len, uint32_t ms,
                              uint64_t* out) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
  uint64_t t = 0;
  for (uint32_t i = 0; i < len; ++i) t += src[i];
  *out = t;
  return 0;
}
