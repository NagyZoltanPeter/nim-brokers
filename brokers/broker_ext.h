/* broker_ext.h — nim-brokers EXTAPI plugin ABI.
 *
 * Fixed, hand-written, versioned. Never regenerated per plugin.
 * See doc/design/EXTAPI_PLAN.md §6.
 *
 * Every `broker_ext_host` entry may be called from ANY thread. provide /
 * withdraw / close wait until the host's bridge thread has applied them (never
 * across a host stop: they return BROKER_EXT_SHUTDOWN instead); a bridge
 * stalled by a blocking `invoke` stalls them too. open / reply / emit never
 * wait. Buffers passed to the host are copied before the call returns.
 * The `buf` passed to `invoke` is valid only for the duration of that call.
 */
#ifndef BROKER_EXT_H
#define BROKER_EXT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BROKER_EXT_ABI_VERSION 1u

typedef uint64_t broker_ext_port;    /* opaque; 0 = invalid */
typedef uint64_t broker_ext_call_id; /* 0 = one-way (signal) */

enum {
  BROKER_EXT_OK = 0,
  BROKER_EXT_BAD_ARG = -1,
  BROKER_EXT_UNKNOWN_NAME = -4,      /* plugin / name not declared by the host */
  BROKER_EXT_AGAIN = -6,             /* ring full: retry or drop */
  BROKER_EXT_SHUTDOWN = -11,
  BROKER_EXT_SCHEMA_MISMATCH = -14,
  BROKER_EXT_STALE = -15,            /* port closed / gen mismatch */
  BROKER_EXT_ALREADY_PROVIDED = -16, /* another port is the source of this name */
  BROKER_EXT_NOT_PROVIDED = -17,     /* withdraw of a name this port does not provide */
  BROKER_EXT_DISPATCH_MISMATCH = -18 /* port caps cannot serve the broker's dispatch */
};

enum { BROKER_EXT_REPLY_OK = 0, BROKER_EXT_REPLY_ERR = 1 };

enum {
  BROKER_EXT_CAP_NONBLOCKING = 1u << 0,  /* invoke returns promptly (may reply later) */
  BROKER_EXT_CAP_REPLY_INLINE = 1u << 1  /* invoke always replies before returning */
};

/* Foreign side, called by the host. `buf` valid only during the call.
 * `invoke` runs on: the host's single bridge thread for `bridge` names
 * (requests and signals alike), one of the plugin's host-owned worker threads
 * for `workers(n)` names, and the Nim caller's own thread for `inplace` names.
 * A port serving names of several modes is invoked concurrently from those
 * threads. `cancel` runs on the bridge thread. */
typedef void (*broker_ext_invoke_fn)(void* user, broker_ext_call_id id,
                                     uint32_t nameIdx, const char* name,
                                     const uint8_t* buf, size_t len);
typedef void (*broker_ext_cancel_fn)(void* user, broker_ext_call_id id);
typedef void (*broker_ext_release_fn)(void* user);

typedef struct {
  uint32_t abiVersion;          /* BROKER_EXT_ABI_VERSION */
  const char* plugin;           /* e.g. "storage" */
  const char* schemaHash;       /* 32 hex chars, or NULL = unchecked raw tunnel */
  uint32_t caps;                /* BROKER_EXT_CAP_* */
  broker_ext_invoke_fn invoke;
  broker_ext_cancel_fn cancel;   /* may be NULL */
  broker_ext_release_fn release; /* may be NULL */
  void* user;
} broker_ext_impl;

typedef struct broker_ext_host {
  uint32_t abiVersion;
  void* host;

  /* wiring */
  int32_t (*open)(void* host, uint32_t ctx, const broker_ext_impl* impl,
                  broker_ext_port* out);
  int32_t (*close)(void* host, broker_ext_port port);
  int32_t (*provide)(void* host, broker_ext_port port, const char* name);
  int32_t (*withdraw)(void* host, broker_ext_port port, const char* name);

  /* traffic: the CBOR tunnel. buf is copied before return. */
  int32_t (*reply)(void* host, broker_ext_port port, broker_ext_call_id id,
                   int32_t status, const uint8_t* buf, size_t len);
  int32_t (*emit)(void* host, broker_ext_port port, const char* name,
                  const uint8_t* buf, size_t len);

  /* discovery: CBOR descriptors, buffer owned by the host */
  int32_t (*listApis)(void* host, const char* plugin, uint8_t** out, size_t* outLen);
  int32_t (*getSchema)(void* host, const char* plugin, uint8_t** out, size_t* outLen);
  void (*freeBuffer)(void* host, uint8_t* buf);
  int32_t (*schemaHash)(void* host, const char* plugin, char hashOut[33]);
} broker_ext_host;

/* Exe mode: a plugin shared library exports this entry point; the Nim host
 * calls it after dlopen / LoadLibrary. */
typedef int32_t (*broker_ext_plugin_entry_fn)(const broker_ext_host* host);

#ifdef __cplusplus
}
#endif

#endif /* BROKER_EXT_H */
