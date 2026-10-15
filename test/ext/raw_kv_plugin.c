/* Raw EXTAPI plugin "kv" for the phase 1b switching tests:
 *   kv_get    {"key": tstr} -> {"value": "plugin:" + key}   bridge, inline reply
 *   kv_slow   ()            -> parked until raw_kv_release(); cancel counted
 *   kv_note   {"text": tstr}   one-way signal, counted
 *   kv_square {"x": uint}   -> {"v": x*x}  inplace; records the invoking thread
 *   kv_tick   event {"n": uint} via raw_kv_emit_tick()
 */
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>

#include "broker_ext.h"

static const broker_ext_host* H = NULL;
static broker_ext_port P = 0;
static atomic_int noteCount = 0;
static atomic_int cancelCount = 0;
static atomic_int parkedCount = 0;
static broker_ext_call_id parked[64];
static atomic_uintptr_t squareThread = 0;

static size_t put_head(uint8_t* o, uint8_t major, uint64_t v) {
  if (v < 24) { o[0] = (uint8_t)(major << 5 | v); return 1; }
  if (v < 256) { o[0] = (uint8_t)(major << 5 | 24); o[1] = (uint8_t)v; return 2; }
  o[0] = (uint8_t)(major << 5 | 25); o[1] = (uint8_t)(v >> 8); o[2] = (uint8_t)v; return 3;
}

static size_t get_head(const uint8_t* b, size_t n, uint8_t* major, uint64_t* v) {
  if (n < 1) return 0;
  *major = b[0] >> 5;
  uint8_t ai = b[0] & 31;
  if (ai < 24) { *v = ai; return 1; }
  if (ai == 24 && n >= 2) { *v = b[1]; return 2; }
  if (ai == 25 && n >= 3) { *v = ((uint64_t)b[1] << 8) | b[2]; return 3; }
  return 0;
}

/* one-level map lookup: major 3 (text) or 0 (uint) value */
static int find_val(const uint8_t* b, size_t n, const char* key, uint8_t want,
                    const uint8_t** out, uint64_t* val) {
  uint8_t mj; uint64_t cnt; size_t p = get_head(b, n, &mj, &cnt);
  if (!p || mj != 5) return 0;
  for (uint64_t i = 0; i < cnt; i++) {
    uint8_t km; uint64_t kl; size_t h = get_head(b + p, n - p, &km, &kl);
    if (!h || km != 3) return 0;
    const uint8_t* k = b + p + h; p += h + kl;
    uint8_t vm; uint64_t v; size_t vh = get_head(b + p, n - p, &vm, &v);
    if (!vh) return 0;
    if (kl == strlen(key) && memcmp(k, key, kl) == 0 && vm == want) {
      *out = b + p + vh; *val = v; return 1;
    }
    p += vh + ((vm == 2 || vm == 3) ? v : 0);
  }
  return 0;
}

static void on_invoke(void* user, broker_ext_call_id id, uint32_t idx,
                      const char* name, const uint8_t* buf, size_t len) {
  (void)user; (void)idx;
  const uint8_t* s; uint64_t v;
  if (strcmp(name, "kv_get") == 0) {
    if (!find_val(buf, len, "key", 3, &s, &v)) v = 0;
    uint8_t out[300]; size_t o = 0;
    o += put_head(out + o, 5, 1);
    o += put_head(out + o, 3, 5); memcpy(out + o, "value", 5); o += 5;
    o += put_head(out + o, 3, 7 + v); memcpy(out + o, "plugin:", 7); o += 7;
    memcpy(out + o, s, v); o += v;
    H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, out, o);
  } else if (strcmp(name, "kv_slow") == 0) {
    int i = atomic_fetch_add(&parkedCount, 1);
    if (i < 64) parked[i] = id;
  } else if (strcmp(name, "kv_note") == 0) {
    if (id == 0) atomic_fetch_add(&noteCount, 1);
  } else if (strcmp(name, "kv_square") == 0) {
    atomic_store(&squareThread, (uintptr_t)pthread_self());
    if (!find_val(buf, len, "x", 0, &s, &v)) v = 0;
    uint8_t out[16]; size_t o = 0;
    o += put_head(out + o, 5, 1);
    o += put_head(out + o, 3, 1); out[o++] = 'v';
    o += put_head(out + o, 0, v * v);
    H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, out, o);
  }
}

static void on_cancel(void* user, broker_ext_call_id id) {
  (void)user; (void)id;
  atomic_fetch_add(&cancelCount, 1);
}

int32_t raw_kv_open(const broker_ext_host* h, uint32_t ctx) {
  H = h;
  broker_ext_impl impl = {BROKER_EXT_ABI_VERSION, "kv", NULL,
                          BROKER_EXT_CAP_NONBLOCKING | BROKER_EXT_CAP_REPLY_INLINE,
                          on_invoke, on_cancel, NULL, NULL};
  return h->open(h->host, ctx, &impl, &P);
}

int32_t raw_kv_provide(const char* name) { return H->provide(H->host, P, name); }
int32_t raw_kv_withdraw(const char* name) { return H->withdraw(H->host, P, name); }
int32_t raw_kv_close(void) { return H->close(H->host, P); }
int32_t raw_kv_note_count(void) { return atomic_load(&noteCount); }
int32_t raw_kv_cancel_count(void) { return atomic_load(&cancelCount); }
int32_t raw_kv_parked(void) { return atomic_load(&parkedCount); }
uintptr_t raw_kv_square_thread(void) { return atomic_load(&squareThread); }
uintptr_t raw_kv_self_thread(void) { return (uintptr_t)pthread_self(); }

int32_t raw_kv_release(void) {
  int n = atomic_exchange(&parkedCount, 0);
  if (n > 64) n = 64;
  const uint8_t out[] = {0xa1, 0x61, 'n', 0x05};
  for (int i = 0; i < n; i++)
    H->reply(H->host, P, parked[i], BROKER_EXT_REPLY_OK, out, sizeof out);
  return n;
}

int32_t raw_kv_emit_tick(uint32_t n) {
  uint8_t out[8]; size_t o = 0;
  o += put_head(out + o, 5, 1);
  o += put_head(out + o, 3, 1); out[o++] = 'n';
  o += put_head(out + o, 0, n);
  return H->emit(H->host, P, "kv_tick", out, o);
}
