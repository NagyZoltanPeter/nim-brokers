/* Raw EXTAPI plugin "calc" exercising dispatch policies:
 *   square  {"x": int}  -> {"v": int}   inplace: replies before invoke returns
 *   sleepy  {"ms": int} -> {"v": int}   workers(2): blocks its worker for ms
 *   lazy    ()          -> never replies inline (inplace contract violation)
 */
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(unsigned ms) { Sleep(ms); }
#else
#include <time.h>
static void sleep_ms(unsigned ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}
#endif

#include "broker_ext.h"

static const broker_ext_host* H = NULL;
static broker_ext_port P = 0;
static atomic_int cancelCount = 0;
static atomic_int sleepyStarted = 0;

static size_t put_head(uint8_t* o, uint8_t major, uint64_t v) {
  if (v < 24) { o[0] = (uint8_t)(major << 5 | v); return 1; }
  if (v < 256) { o[0] = (uint8_t)(major << 5 | 24); o[1] = (uint8_t)v; return 2; }
  if (v < 65536) { o[0] = (uint8_t)(major << 5 | 25); o[1] = (uint8_t)(v >> 8); o[2] = (uint8_t)v; return 3; }
  o[0] = (uint8_t)(major << 5 | 26);
  o[1] = (uint8_t)(v >> 24); o[2] = (uint8_t)(v >> 16); o[3] = (uint8_t)(v >> 8); o[4] = (uint8_t)v;
  return 5;
}

static size_t get_head(const uint8_t* b, size_t n, uint8_t* major, uint64_t* v) {
  if (n < 1) return 0;
  *major = b[0] >> 5;
  uint8_t ai = b[0] & 31;
  if (ai < 24) { *v = ai; return 1; }
  if (ai == 24 && n >= 2) { *v = b[1]; return 2; }
  if (ai == 25 && n >= 3) { *v = ((uint64_t)b[1] << 8) | b[2]; return 3; }
  if (ai == 26 && n >= 5) {
    *v = ((uint64_t)b[1] << 24) | ((uint64_t)b[2] << 16) | ((uint64_t)b[3] << 8) | b[4];
    return 5;
  }
  return 0;
}

static int find_uint(const uint8_t* b, size_t n, const char* key, uint64_t* out) {
  uint8_t mj; uint64_t cnt; size_t p = get_head(b, n, &mj, &cnt);
  if (!p || mj != 5) return 0;
  for (uint64_t i = 0; i < cnt; i++) {
    uint8_t km; uint64_t kl; size_t h = get_head(b + p, n - p, &km, &kl);
    if (!h || km != 3) return 0;
    const uint8_t* k = b + p + h; p += h + kl;
    uint8_t vm; uint64_t v; size_t vh = get_head(b + p, n - p, &vm, &v);
    if (!vh) return 0;
    if (kl == strlen(key) && memcmp(k, key, kl) == 0 && vm == 0) { *out = v; return 1; }
    p += vh + ((vm == 2 || vm == 3) ? v : 0);
  }
  return 0;
}

static void reply_v(broker_ext_call_id id, uint64_t v) {
  uint8_t out[16]; size_t o = 0;
  o += put_head(out + o, 5, 1);
  o += put_head(out + o, 3, 1); out[o++] = 'v';
  o += put_head(out + o, 0, v);
  H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, out, o);
}

static void on_invoke(void* user, broker_ext_call_id id, uint32_t idx,
                      const char* name, const uint8_t* buf, size_t len) {
  (void)user; (void)idx;
  uint64_t x = 0;
  if (strcmp(name, "square") == 0) {
    find_uint(buf, len, "x", &x);
    reply_v(id, x * x);
  } else if (strcmp(name, "sleepy") == 0) {
    find_uint(buf, len, "ms", &x);
    atomic_fetch_add(&sleepyStarted, 1);
    sleep_ms((unsigned)x);
    reply_v(id, x);
  } else if (strcmp(name, "counter") == 0) {
    uint8_t out[8]; size_t o = put_head(out, 0, 41);   /* bare uint, no map */
    H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, out, o);
  } else if (strcmp(name, "counter_arg") == 0) {
    find_uint(buf, len, "add", &x);
    uint8_t out[8]; size_t o = put_head(out, 0, 41 + x);
    H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, out, o);
  } else if (strcmp(name, "lazy") == 0) {
    /* deliberately no reply */
  }
}

static void on_cancel(void* user, broker_ext_call_id id) {
  (void)user; (void)id;
  atomic_fetch_add(&cancelCount, 1);
}

int32_t raw_calc_open(const broker_ext_host* h, uint32_t ctx, uint32_t caps) {
  H = h;
  broker_ext_impl impl = {BROKER_EXT_ABI_VERSION, "calc", NULL, caps,
                          on_invoke, on_cancel, NULL, NULL};
  return h->open(h->host, ctx, &impl, &P);
}

int32_t raw_calc_provide(const char* name) { return H->provide(H->host, P, name); }
int32_t raw_calc_withdraw(const char* name) { return H->withdraw(H->host, P, name); }
int32_t raw_calc_close(void) { return H->close(H->host, P); }
int32_t raw_calc_cancel_count(void) { return atomic_load(&cancelCount); }
int32_t raw_calc_sleepy_started(void) { return atomic_load(&sleepyStarted); }
