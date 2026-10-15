/* A raw EXTAPI plugin written against broker_ext.h only: no generated
 * wrapper, a few hand-rolled CBOR helpers. Drives test_ext_plugin.nim.
 *
 * Names served (plugin "storage"):
 *   fetch_blob  {"key": tstr}  -> {"data": bstr}  key bytes reversed, inline reply
 *   fail_op     ()             -> REPLY_ERR "boom"
 *   slow_op     ()             -> parked; answered by raw_storage_release_slow()
 *   compact_hint {"urgency": uint}  one-way signal, recorded
 * and emits:
 *   blob_evicted {"key": tstr}      via raw_storage_emit_evicted()
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#include "broker_ext.h"

static const broker_ext_host* H = NULL;
static broker_ext_port P = 0;

#define MAX_PARKED 64
static broker_ext_call_id parked[MAX_PARKED];
static atomic_int parkedCount = 0;
static atomic_int cancelCount = 0;
static atomic_int releaseCount = 0;
static atomic_int hintCount = 0;
static atomic_int lastUrgency = -1;

/* --- minimal CBOR ------------------------------------------------------- */

static size_t put_head(uint8_t* o, uint8_t major, uint64_t v) {
  if (v < 24) { o[0] = (uint8_t)(major << 5 | v); return 1; }
  if (v < 256) { o[0] = (uint8_t)(major << 5 | 24); o[1] = (uint8_t)v; return 2; }
  o[0] = (uint8_t)(major << 5 | 25); o[1] = (uint8_t)(v >> 8); o[2] = (uint8_t)v; return 3;
}

/* reads a head; returns bytes consumed, 0 on error */
static size_t get_head(const uint8_t* b, size_t n, uint8_t* major, uint64_t* v) {
  if (n < 1) return 0;
  *major = b[0] >> 5;
  uint8_t ai = b[0] & 31;
  if (ai < 24) { *v = ai; return 1; }
  if (ai == 24 && n >= 2) { *v = b[1]; return 2; }
  if (ai == 25 && n >= 3) { *v = ((uint64_t)b[1] << 8) | b[2]; return 3; }
  return 0;
}

/* finds text value of map key `key` in a one-level map; returns ptr+len */
static int find_text(const uint8_t* b, size_t n, const char* key,
                     const uint8_t** out, size_t* outLen) {
  uint8_t mj; uint64_t cnt; size_t p = get_head(b, n, &mj, &cnt);
  if (!p || mj != 5) return 0;
  for (uint64_t i = 0; i < cnt; i++) {
    uint8_t km; uint64_t kl; size_t h = get_head(b + p, n - p, &km, &kl);
    if (!h || km != 3) return 0;
    const uint8_t* k = b + p + h; p += h + kl;
    uint8_t vm; uint64_t vl; size_t vh = get_head(b + p, n - p, &vm, &vl);
    if (!vh) return 0;
    if (kl == strlen(key) && memcmp(k, key, kl) == 0 && vm == 3) {
      *out = b + p + vh; *outLen = (size_t)vl; return 1;
    }
    p += vh + ((vm == 2 || vm == 3) ? vl : 0);
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

/* --- plugin --------------------------------------------------------------- */

static void on_invoke(void* user, broker_ext_call_id id, uint32_t idx,
                      const char* name, const uint8_t* buf, size_t len) {
  (void)user; (void)idx;
  if (strcmp(name, "fetch_blob") == 0) {
    const uint8_t* key; size_t keyLen;
    if (!find_text(buf, len, "key", &key, &keyLen)) {
      const char* e = "bad request";
      H->reply(H->host, P, id, BROKER_EXT_REPLY_ERR, (const uint8_t*)e, strlen(e));
      return;
    }
    uint8_t out[300]; size_t o = 0;
    o += put_head(out + o, 5, 1);
    o += put_head(out + o, 3, 4); memcpy(out + o, "data", 4); o += 4;
    o += put_head(out + o, 2, keyLen);
    for (size_t i = 0; i < keyLen; i++) out[o + i] = key[keyLen - 1 - i];
    o += keyLen;
    H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, out, o);
  } else if (strcmp(name, "fail_op") == 0) {
    const char* e = "boom";
    H->reply(H->host, P, id, BROKER_EXT_REPLY_ERR, (const uint8_t*)e, strlen(e));
  } else if (strcmp(name, "compact_hint") == 0) {
    uint64_t u = 0;
    if (id == 0 && find_uint(buf, len, "urgency", &u)) {
      atomic_store(&lastUrgency, (int)u);
      atomic_fetch_add(&hintCount, 1);
    }
  } else if (strcmp(name, "slow_op") == 0) {
    int i = atomic_fetch_add(&parkedCount, 1);
    if (i < MAX_PARKED) parked[i] = id;
  }
}

static void on_cancel(void* user, broker_ext_call_id id) {
  (void)user; (void)id;
  atomic_fetch_add(&cancelCount, 1);
}

static void on_release(void* user) {
  (void)user;
  atomic_fetch_add(&releaseCount, 1);
}

int32_t raw_storage_open(const broker_ext_host* h, uint32_t ctx, const char* schemaHash) {
  H = h;
  atomic_store(&parkedCount, 0);
  atomic_store(&cancelCount, 0);
  broker_ext_impl impl = {BROKER_EXT_ABI_VERSION, "storage", schemaHash,
                          BROKER_EXT_CAP_NONBLOCKING, on_invoke, on_cancel,
                          on_release, NULL};
  return h->open(h->host, ctx, &impl, &P);
}

int32_t raw_storage_provide(const char* name) { return H->provide(H->host, P, name); }
int32_t raw_storage_withdraw(const char* name) { return H->withdraw(H->host, P, name); }
int32_t raw_storage_close(void) { return H->close(H->host, P); }

/* answers every parked slow_op with {"n": 7}; returns how many were answered */
int32_t raw_storage_release_slow(void) {
  int n = atomic_exchange(&parkedCount, 0);
  if (n > MAX_PARKED) n = MAX_PARKED;
  const uint8_t out[] = {0xa1, 0x61, 'n', 0x07};
  for (int i = 0; i < n; i++)
    H->reply(H->host, P, parked[i], BROKER_EXT_REPLY_OK, out, sizeof out);
  return n;
}

int32_t raw_storage_parked(void) { return atomic_load(&parkedCount); }
int32_t raw_storage_cancel_count(void) { return atomic_load(&cancelCount); }
int32_t raw_storage_release_count(void) { return atomic_load(&releaseCount); }

int32_t raw_storage_hint_count(void) { return atomic_load(&hintCount); }
int32_t raw_storage_last_urgency(void) { return atomic_load(&lastUrgency); }

int32_t raw_storage_emit_evicted(const char* key) {
  uint8_t out[300]; size_t o = 0; size_t kl = strlen(key);
  o += put_head(out + o, 5, 1);
  o += put_head(out + o, 3, 3); memcpy(out + o, "key", 3); o += 3;
  o += put_head(out + o, 3, kl); memcpy(out + o, key, kl); o += kl;
  return H->emit(H->host, P, "blob_evicted", out, o);
}
