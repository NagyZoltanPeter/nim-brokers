/**
 * mylib C++ example application
 * =============================
 * Demonstrates consuming a Nim dynamic library built with nim-brokers FFI API.
 *
 * This example exercises the API surface:
 * - Library lifecycle (init / shutdown)
 * - Zero-arg requests (GetStatus, DestroyRequest)
 * - Arg-based requests (InitRequest)
 * - Event callbacks via delivery-thread-based delivery (StatusChanged)
 * - Handle-based listener management (on/off with uint64_t handles)
 * - Proper memory management via mylib_free_string
 *
 * Build:
 *   1. Build the Nim library first (from repo root):
 *      nimble buildFfiExample
 *
 *   2. Build this C++ app (from repo root):
 *      nimble buildFfiExampleApp
 *
 *   3. Run:
 *      ./examples/ffiapi/cppapp/build/example
 *
 * NOTE: C callbacks run on the Nim delivery thread.
 *       They MUST NOT block — offload long work to other threads.
 */

#include <cstdio>
#include <cstring>
#include <thread>
#include <chrono>
#include "mylib.h"

// ---------------------------------------------------------------------------
// Helper: free a C result string field if non-null
// ---------------------------------------------------------------------------

static inline void free_if(char* s) {
    if (s) mylib_free_string(s);
}

// ---------------------------------------------------------------------------
// Event callbacks
// ---------------------------------------------------------------------------

void on_status_changed(bool healthy, const char* message) {
    printf("  [event] StatusChanged: healthy=%s, message=\"%s\"\n",
           healthy ? "true" : "false",
           message ? message : "(null)");
}

void on_status_changed_2(bool healthy, const char* message) {
    printf("  [event] StatusChanged (listener 2): healthy=%s\n",
           healthy ? "true" : "false");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main() {
    printf("=== mylib FFI API Example (delivery thread events) ===\n\n");

    // ── Step 0: Initialize Nim runtime ──────────────────────────────────
    printf("Step 0: Initialize Nim runtime\n");
    mylib_initialize();
    printf("  Nim runtime initialized.\n\n");

    // ── Step 1: Initialize library context ──────────────────────────────
    printf("Step 1: Initialize library context\n");
    uint32_t ctx = mylib_init();
    printf("  ctx = 0x%08X\n\n", ctx);

    // Give threads time to start
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    // ── Step 2: Register event listener ─────────────────────────────────
    printf("Step 2: Register StatusChanged event listener\n");
    uint64_t handle1 = onStatusChanged(ctx, on_status_changed);
    printf("  Listener handle: %llu\n\n", (unsigned long long)handle1);

    // ── Step 3: Initialize library via InitRequest ──────────────────────
    printf("Step 3: Initialize library (InitRequest)\n");
    {
        InitRequestCResult res =
            init_request_request_with_args(ctx, "/etc/mylib.conf");
        if (res.error_message) {
            printf("  ERROR: %s\n", res.error_message);
            free_if(res.error_message);
            mylib_shutdown(ctx);
            return 1;
        }
        printf("  initialized=%s, configPath=\"%s\"\n",
               res.initialized ? "true" : "false",
               res.configPath ? res.configPath : "(null)");
        free_if(res.configPath);
    }
    printf("\n");

    // ── Step 4: Query status ────────────────────────────────────────────
    printf("Step 4: Query status\n");
    {
        GetStatusCResult st = get_status_request(ctx);
        if (st.error_message) {
            printf("  ERROR: %s\n", st.error_message);
            free_if(st.error_message);
        } else {
            printf("  healthy=%s, uptime=%lld ms\n",
                   st.healthy ? "true" : "false",
                   (long long)st.uptimeMs);
            printf("  message=\"%s\"\n",
                   st.message ? st.message : "(null)");
            free_if(st.message);
        }
    }
    printf("\n");

    // ── Step 5: Register a second listener ──────────────────────────────
    printf("Step 5: Register second StatusChanged listener\n");
    uint64_t handle2 = onStatusChanged(ctx, on_status_changed_2);
    printf("  Listener 2 handle: %llu\n\n", (unsigned long long)handle2);

    // ── Step 6: Destroy library state (triggers StatusChanged) ──────────
    printf("Step 6: Destroy library (triggers StatusChanged event)\n");
    {
        DestroyRequestCResult res = destroy_request_request(ctx);
        if (res.error_message) {
            printf("  ERROR: %s\n", res.error_message);
            free_if(res.error_message);
        } else {
            printf("  Destroy status: %d\n", res.status);
        }
    }
    // Events fire automatically on delivery thread — brief sleep to see output
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    printf("\n");

    // ── Step 7: Remove first listener by handle ─────────────────────────
    printf("Step 7: Remove first listener by handle\n");
    offStatusChanged(ctx, handle1);
    printf("  Listener 1 removed.\n\n");

    // ── Step 8: Remove all remaining listeners ──────────────────────────
    printf("Step 8: Remove all remaining listeners (handle=0)\n");
    offStatusChanged(ctx, 0);
    printf("  All listeners removed.\n\n");

    // ── Step 9: Shutdown library context ────────────────────────────────
    printf("Step 9: Shutdown library context\n");
    mylib_shutdown(ctx);
    printf("  Done.\n\n");

    printf("=== Example complete ===\n");
    return 0;
}
