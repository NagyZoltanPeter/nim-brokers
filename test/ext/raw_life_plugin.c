/* Raw EXTAPI plugin "life" for the lifecycle tests (test_ext_lifecycle.nim):
 *   life_work        ()  workers: blocks while the gate is closed, counts invokes
 *   life_bridge      ()  bridge: parks the call (never replies), counts cancels
 *   life_hook_bridge ()  bridge: calls the host hook, then replies
 *   life_hook_worker ()  workers: calls the host hook, then replies
 * Every reply is {"n": 5}.
 */
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <time.h>
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

static const uint8_t REPLY[] = {0xa1, 0x61, 'n', 0x05};

static void reply_ok(broker_ext_call_id id) {
  H->reply(H->host, atomic_load(&P), id, BROKER_EXT_REPLY_OK, REPLY, sizeof REPLY);
}

static void on_invoke(void* user, broker_ext_call_id id, uint32_t idx,
                      const char* name, const uint8_t* buf, size_t len) {
  (void)user; (void)idx; (void)buf; (void)len;
  if (strcmp(name, "life_work") == 0) {
    atomic_fetch_add(&workInvokes, 1);
    while (atomic_load(&gate) == 0) sleep_ms(1);
    reply_ok(id);
  } else if (strcmp(name, "life_bridge") == 0) {
    /* parked: no reply */
  } else if (strcmp(name, "life_hook_bridge") == 0 ||
             strcmp(name, "life_hook_worker") == 0) {
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
