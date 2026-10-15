/* A plain C library imported by test_ext_imports.nim through
 * RequestBroker(EXTAPI[codec], dynlib = ...) — it knows nothing about brokers. */
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#define EXPORT __declspec(dllexport)
static void sleep_ms(uint32_t ms) { Sleep(ms); }
static uintptr_t self_thread(void) { return (uintptr_t)GetCurrentThreadId(); }
#else
#include <time.h>
#include <pthread.h>
#define EXPORT __attribute__((visibility("default")))
static uintptr_t self_thread(void) { return (uintptr_t)pthread_self(); }
static void sleep_ms(uint32_t ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}
#endif

static uintptr_t lastCrcThread = 0;

/* Simple checksum; records the calling thread (inplace check). */
EXPORT uint32_t codec_crc(uint32_t seed, const uint8_t* buf, uint32_t len) {
  lastCrcThread = self_thread();
  uint32_t h = seed;
  for (uint32_t i = 0; i < len; i++) h = h * 31u + buf[i];
  return h;
}

EXPORT uintptr_t codec_last_crc_thread(void) { return lastCrcThread; }

/* Blocking: sleeps `ms`, then sums the bytes. 0 = ok. */
EXPORT int32_t codec_slow_sum(const uint8_t* src, uint32_t len, uint32_t ms,
                              uint64_t* out) {
  sleep_ms(ms);
  uint64_t t = 0;
  for (uint32_t i = 0; i < len; i++) t += src[i];
  *out = t;
  return 0;
}
