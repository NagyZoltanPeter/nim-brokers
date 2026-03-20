/**
 * mylib C++ example application
 * =============================
 * Demonstrates consuming a Nim dynamic library built with nim-brokers FFI API.
 *
 * Build:
 *   1. Build the Nim library first (from nimlib/):
 *      nim c -d:BrokerFfiApi --threads:on --app:lib --path:../../../src \
 *        --outdir:build mylib.nim
 *
 *   2. Build this C++ app (from cppapp/):
 *      mkdir -p build && cd build
 *      cmake .. && make
 *
 *   3. Run:
 *      ./build/example
 */

#include <cstdio>
#include <cstring>
#include <thread>
#include <chrono>
#include "mylib.h"

// Event callback: called when library status changes
void onStatusChanged(bool healthy, const char* message) {
    printf("[Event] StatusChanged: healthy=%s, message=\"%s\"\n",
           healthy ? "true" : "false",
           message ? message : "(null)");
}

int main() {
    printf("=== mylib FFI API Example ===\n\n");

    // Step 1: Initialize library context (spawns processing thread)
    printf("1. Initializing library context...\n");
    uint32_t ctx = mylib_init();
    printf("   Context: 0x%08X\n\n", ctx);

    // Give the processing thread time to start
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // Step 2: Register event listener
    printf("2. Registering StatusChanged event listener...\n");
    onStatusChanged(ctx, onStatusChanged);
    printf("   Listener registered.\n\n");

    // Step 3: Initialize the library via InitRequest
    printf("3. Calling init_request_with_args...\n");
    InitRequestCResult initResult = init_request_with_args(ctx, "/etc/mylib.conf");
    if (initResult.error_message) {
        printf("   ERROR: %s\n", initResult.error_message);
        mylib_free_string(initResult.error_message);
        mylib_shutdown(ctx);
        return 1;
    }
    printf("   Initialized: %s, configPath: \"%s\"\n\n",
           initResult.initialized ? "true" : "false",
           initResult.configPath ? initResult.configPath : "(null)");
    if (initResult.configPath) mylib_free_string(initResult.configPath);

    // Step 4: Query library status
    printf("4. Querying GetStatus...\n");
    GetStatusCResult status = get_status_request(ctx);
    if (status.error_message) {
        printf("   ERROR: %s\n", status.error_message);
        mylib_free_string(status.error_message);
    } else {
        printf("   Healthy: %s, Uptime: %lld ms, Message: \"%s\"\n\n",
               status.healthy ? "true" : "false",
               (long long)status.uptimeMs,
               status.message ? status.message : "(null)");
        if (status.message) mylib_free_string(status.message);
    }

    // Step 5: Destroy library state (triggers StatusChanged event)
    printf("5. Calling destroy_request...\n");
    DestroyRequestCResult destroyResult = destroy_request(ctx);
    if (destroyResult.error_message) {
        printf("   ERROR: %s\n", destroyResult.error_message);
        mylib_free_string(destroyResult.error_message);
    } else {
        printf("   Destroy status: %d\n\n", destroyResult.status);
    }

    // Give time for the StatusChanged event to be delivered
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // Step 6: Shutdown library context (tears down processing thread)
    printf("6. Shutting down library context...\n");
    mylib_shutdown(ctx);
    printf("   Done.\n");

    return 0;
}
