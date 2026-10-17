/* Raw EXTAPI plugin "echo", built as a shared library and loaded by the Nim
 * host through ExtHost.loadPlugin() → broker_ext_plugin_entry().
 *   echo_msg {"text": tstr} -> {"text": tstr}   (bridge dispatch, inline reply)
 * It pins the schema hash read from the host's discovery entry. */
#include <stdint.h>
#include <string.h>

#include "broker_ext.h"

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

static const broker_ext_host* H = NULL;
static broker_ext_port P = 0;

static void on_invoke(void* user, broker_ext_call_id id, uint32_t idx,
                      const char* name, const uint8_t* buf, size_t len) {
  (void)user; (void)idx; (void)name;
  /* {"text": x} in, {"text": x} out: the request map IS the reply map. */
  H->reply(H->host, P, id, BROKER_EXT_REPLY_OK, buf, len);
}

EXPORT int32_t broker_ext_plugin_entry(const broker_ext_host* h) {
  H = h;
  char hash[33];
  int32_t rc = h->schemaHash(h->host, "echo", hash);
  if (rc != BROKER_EXT_OK) return rc;
  broker_ext_impl impl = {BROKER_EXT_ABI_VERSION, "echo", hash,
                          BROKER_EXT_CAP_NONBLOCKING, on_invoke, NULL, NULL, NULL};
  rc = h->open(h->host, 1 /* DefaultBrokerContext */, &impl, &P);
  if (rc != BROKER_EXT_OK) return rc;
  return h->provide(h->host, P, "echo_msg");
}
