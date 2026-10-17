/* Raw EXTAPI plugin "life" for the lifecycle tests (test_ext_lifecycle.nim):
 *   life_work        ()  workers: blocks while the gate is closed, counts invokes
 *   life_bridge      ()  bridge: parks the call (never replies), counts cancels
 *   life_hook_bridge ()  bridge: calls the host hook, then replies
 *   life_hook_worker ()  workers: calls the host hook, then replies
 *   life_dual_zero / life_dual_args   bridge: the two slots of a dual-slot
 *                        request, reply at once
 *   life_echo   {"x": uint}  inplace: replies {"n": x}, then a duplicate
 *                        {"n": 7777} that must be dropped
 *   life_owned  ()       bridge, for autoWire = false brokers: replies at once
 *   life_tick            event {"n": uint} via life_emit_tick()
 *   life_sig    signal   bridge: records the invoking thread
 *   life_tid    ()       bridge: records the invoking thread, replies
 * life_work, life_echo and life_hook_worker also record their invoking thread
 * (mixed-dispatch test).
 * Other replies are {"n": 5}. life_bridge records the parked call id so a
 * test can answer it later, from this port or from a second one.
 */
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep(ms); }
static uintptr_t self_thread(void) { return (uintptr_t)GetCurrentThreadId(); }
#else
#include <time.h>
#include <pthread.h>
static uintptr_t self_thread(void) { return (uintptr_t)pthread_self(); }
static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}
#endif

#include "broker_ext.h"

typedef void (*life_hook_fn)(void);

static const broker_ext_host* H = NULL;
static _Atomic broker_ext_port P = 0;
static atomic_int workInvokes = 0;
static atomic_int cancels = 0;
static atomic_int gate = 1;
static _Atomic(life_hook_fn) hook = NULL;
static _Atomic broker_ext_port P2 = 0;
static _Atomic broker_ext_call_id parkedId = 0;
static _Atomic broker_ext_call_id doneId = 0;
static atomic_uintptr_t sigThread = 0;
static atomic_uintptr_t tidThread = 0;
static atomic_uintptr_t workThread = 0;
static atomic_uintptr_t echoThread = 0;
static atomic_uintptr_t hookWorkerThread = 0;

static size_t put_head(uint8_t* o, uint8_t major, uint64_t v) {
  if (v < 24) { o[0] = (uint8_t)(major << 5 | v); return 1; }
  if (v < 256) { o[0] = (uint8_t)(major << 5 | 24); o[1] = (uint8_t)v; return 2; }
  o[0] = (uint8_t)(major << 5 | 25); o[1] = (uint8_t)(v >> 8); o[2] = (uint8_t)v; return 3;
}

static size_t enc_n(uint8_t* o, uint64_t v) { /* {"n": v} */
  size_t k = 0;
  o[k++] = 0xa1; o[k++] = 0x61; o[k++] = 'n';
  return k + put_head(o + k, 0, v);
}

static uint64_t dec_x(const uint8_t* b, size_t n) { /* {"x": uint} */
  if (n < 4 || b[0] != 0xa1 || b[1] != 0x61 || b[2] != 'x') return 0;
  uint8_t ai = b[3] & 31;
  if (ai < 24) return ai;
  if (ai == 24 && n >= 5) return b[4];
  if (ai == 25 && n >= 6) return ((uint64_t)b[4] << 8) | b[5];
  return 0;
}

static const uint8_t REPLY[] = {0xa1, 0x61, 'n', 0x05};

static void reply_ok(broker_ext_call_id id) {
  H->reply(H->host, atomic_load(&P), id, BROKER_EXT_REPLY_OK, REPLY, sizeof REPLY);
}

static void on_invoke(void* user, broker_ext_call_id id, uint32_t idx,
                      const char* name, const uint8_t* buf, size_t len) {
  (void)user; (void)idx; (void)buf; (void)len;
  if (strcmp(name, "life_work") == 0) {
    atomic_fetch_add(&workInvokes, 1);
    atomic_store(&workThread, self_thread());
    while (atomic_load(&gate) == 0) sleep_ms(1);
    reply_ok(id);
  } else if (strncmp(name, "life_dual", 9) == 0 || strcmp(name, "life_owned") == 0) {
    reply_ok(id);
  } else if (strcmp(name, "life_echo") == 0) {
    atomic_store(&echoThread, self_thread());
    uint8_t out[8];
    size_t k = enc_n(out, dec_x(buf, len));
    H->reply(H->host, atomic_load(&P), id, BROKER_EXT_REPLY_OK, out, k);
    k = enc_n(out, 7777); /* duplicate: the host must drop it */
    H->reply(H->host, atomic_load(&P), id, BROKER_EXT_REPLY_OK, out, k);
    atomic_store(&doneId, id);
  } else if (strcmp(name, "life_sig") == 0) {
    atomic_store(&sigThread, self_thread());
  } else if (strcmp(name, "life_tid") == 0) {
    atomic_store(&tidThread, self_thread());
    reply_ok(id);
  } else if (strcmp(name, "life_bridge") == 0) {
    atomic_store(&parkedId, id); /* parked: answered by life_reply_parked */
  } else if (strcmp(name, "life_hook_bridge") == 0 ||
             strcmp(name, "life_hook_worker") == 0) {
    if (strcmp(name, "life_hook_worker") == 0)
      atomic_store(&hookWorkerThread, self_thread());
    life_hook_fn f = atomic_load(&hook);
    if (f) f();
    reply_ok(id);
  }
}

static void on_cancel(void* user, broker_ext_call_id id) {
  (void)user; (void)id;
  atomic_fetch_add(&cancels, 1);
}

int32_t life_open(const broker_ext_host* h, uint32_t ctx) {
  H = h;
  broker_ext_impl impl = {BROKER_EXT_ABI_VERSION, "life", NULL,
                          BROKER_EXT_CAP_NONBLOCKING | BROKER_EXT_CAP_REPLY_INLINE,
                          on_invoke, on_cancel, NULL, NULL};
  broker_ext_port p = 0;
  int32_t rc = h->open(h->host, ctx, &impl, &p);
  atomic_store(&P, p);
  return rc;
}

int32_t life_open2(uint32_t ctx) {
  broker_ext_impl impl = {BROKER_EXT_ABI_VERSION, "life", NULL,
                          BROKER_EXT_CAP_NONBLOCKING | BROKER_EXT_CAP_REPLY_INLINE,
                          on_invoke, on_cancel, NULL, NULL};
  broker_ext_port p = 0;
  int32_t rc = H->open(H->host, ctx, &impl, &p);
  atomic_store(&P2, p);
  return rc;
}

/* Answer the parked life_bridge call with {"n": v}, from port 1 or port 2. */
int32_t life_reply_parked(int32_t fromSecond, uint32_t v) {
  uint8_t out[8];
  size_t k = enc_n(out, v);
  broker_ext_port p = fromSecond ? atomic_load(&P2) : atomic_load(&P);
  return H->reply(H->host, p, atomic_load(&parkedId), BROKER_EXT_REPLY_OK, out, k);
}

/* A late reply to the last finished life_echo call. */
int32_t life_reply_late(uint32_t v) {
  uint8_t out[8];
  size_t k = enc_n(out, v);
  return H->reply(H->host, atomic_load(&P), atomic_load(&doneId), BROKER_EXT_REPLY_OK, out, k);
}

broker_ext_port life_port(void) { return atomic_load(&P); }
int32_t life_provide_on(broker_ext_port port, const char* name) {
  return H->provide(H->host, port, name);
}
/* Answer the parked life_bridge call with bytes that are not CBOR. */
int32_t life_reply_parked_garbage(void) {
  const uint8_t junk[] = {0xff, 0xff, 0x00};
  return H->reply(H->host, atomic_load(&P), atomic_load(&parkedId), BROKER_EXT_REPLY_OK,
                  junk, sizeof junk);
}

uintptr_t life_sig_thread(void) { return atomic_load(&sigThread); }
uintptr_t life_tid_thread(void) { return atomic_load(&tidThread); }
uintptr_t life_self_thread(void) { return self_thread(); }
uintptr_t life_work_thread(void) { return atomic_load(&workThread); }
uintptr_t life_echo_thread(void) { return atomic_load(&echoThread); }
uintptr_t life_hook_worker_thread(void) { return atomic_load(&hookWorkerThread); }

int32_t life_emit_tick(uint32_t n) {
  uint8_t out[8];
  size_t k = enc_n(out, n);
  return H->emit(H->host, atomic_load(&P), "life_tick", out, k);
}

int32_t life_provide(const char* name) { return H->provide(H->host, atomic_load(&P), name); }
int32_t life_withdraw(const char* name) { return H->withdraw(H->host, atomic_load(&P), name); }
int32_t life_close(void) { return H->close(H->host, atomic_load(&P)); }
int32_t life_work_invokes(void) { return atomic_load(&workInvokes); }
int32_t life_cancels(void) { return atomic_load(&cancels); }
void life_set_gate(int32_t open) { atomic_store(&gate, open); }
void life_set_hook(life_hook_fn f) { atomic_store(&hook, f); }
void life_reset(void) {
  atomic_store(&workInvokes, 0);
  atomic_store(&cancels, 0);
  atomic_store(&gate, 1);
  atomic_store(&hook, NULL);
}
