/**
 * Device Monitor — modern C++ example
 * =====================================
 * Demonstrates consuming the mylib Nim dynamic library through the
 * generated modern C++ wrapper class.
 *
 * Key features exercised:
 *   - mylib:: namespace for Result<T>, structs, and value types
 *   - Result<T> return type with ok()/error()/value() + operator->
 *   - Explicit lifecycle with inert construction and createContext()
 *   - std::string inputs (no raw const char*)
 *   - std::vector<AddDeviceSpec> batch request input
 *   - const std::string_view in event callbacks (zero-copy, lifetime-safe)
 *   - Lambda callbacks with captures via std::function
 *   - std::vector<DeviceInfo> in ListDevicesResult (no raw arrays)
 *   - Multiple event listeners with individual handle-based removal
 *   - No manual free_xxx_result calls — all hidden inside RAII ctors
 *
 * Build (from repo root):
 *   nimble buildFfiExample          # builds the Nim dynamic library
 *   nimble buildFfiExampleCpp       # compiles this C++ application
 *
 * Run:
 *   ./examples/ffiapi/cpp_example/build/example
 */

#include <cstdio>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "mylib.h"

using namespace mylib;

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */
int main() {
    printf("=== Device Monitor — Modern C++ Example ===\n\n");

    // ── 1. Create the library wrapper and context explicitly ─────────
    Mylib lib;
    auto createContextResult = lib.createContext();
    if (!createContextResult.ok()) {
        fprintf(stderr, "FATAL: %s\n", createContextResult.error().c_str());
        return 1;
    }
    printf("Library context: 0x%08X\n\n", lib.ctx());

    // ── 2. Subscribe to events using lambdas ─────────────────────────
    //    Callbacks receive std::string_view (zero-copy, valid during call).
    //    Captures work naturally — these are std::function, not C ptrs.
    printf("--- Subscribing to events ---\n");

    int discoveryCount = 0;
    auto h_disc = lib.onDeviceDiscovered(
        [&discoveryCount](Mylib& owner, int64_t id, const std::string_view name,
                          const std::string_view type, const std::string_view addr) {
            (void)owner;
            ++discoveryCount;
            printf("  >>> DeviceDiscovered #%d: id=%lld  \"%.*s\"  [%.*s]  %.*s\n",
                   discoveryCount,
                   (long long)id,
                   (int)name.size(), name.data(),
                   (int)type.size(), type.data(),
                   (int)addr.size(), addr.data());
        });

    int statusCount = 0;
    auto h_status = lib.onDeviceStatusChanged(
        [&statusCount](Mylib& owner, int64_t id, const std::string_view name,
                       bool online, int64_t ts) {
            (void)owner;
            ++statusCount;
            printf("  >>> DeviceStatusChanged #%d: id=%lld  \"%.*s\"  %s  (ts=%lld)\n",
                   statusCount,
                   (long long)id,
                   (int)name.size(), name.data(),
                   online ? "ONLINE" : "OFFLINE",
                   (long long)ts);
        });

    // Register a second status listener to demonstrate multiplexing
    auto h_status2 = lib.onDeviceStatusChanged(
        [](Mylib& owner, int64_t id, const std::string_view name, bool online, int64_t) {
            (void)owner;
            (void)id;
            printf("  >>> [Logger] %.*s is now %s\n",
                   (int)name.size(), name.data(),
                   online ? "UP" : "DOWN");
        });

    printf("  Handles: discovered=%llu  status=%llu  status2=%llu\n\n",
           (unsigned long long)h_disc,
           (unsigned long long)h_status,
           (unsigned long long)h_status2);

    // ── 3. Configure library — returns Result<InitializeRequestResult> ─
    printf("--- Configuring library ---\n");
    {
        auto res = lib.initializeRequest("/opt/devices.yaml");
        if (!res.ok()) {
            fprintf(stderr, "Initialize error: %s\n", res.error().c_str());
            return 1;
        }
        // res->configPath is std::string, res->initialized is bool
        printf("  config=%s  initialized=%s\n\n",
               res->configPath.c_str(),
               res->initialized ? "yes" : "no");
    }

    // ── 4. Add a fleet of devices ────────────────────────────────────
    printf("--- Adding devices ---\n");
    auto makeDeviceSpec = [](std::string name, std::string deviceType, std::string address) {
        AddDeviceSpec spec;
        spec.name = std::move(name);
        spec.deviceType = std::move(deviceType);
        spec.address = std::move(address);
        return spec;
    };
    std::vector<AddDeviceSpec> fleet = {
        makeDeviceSpec("Core-Router", "router", "10.0.0.1"),
        makeDeviceSpec("Edge-Switch-A", "switch", "10.0.1.1"),
        makeDeviceSpec("Edge-Switch-B", "switch", "10.0.1.2"),
        makeDeviceSpec("AP-Floor-3", "ap", "10.0.2.10"),
        makeDeviceSpec("TempSensor-DC1", "sensor", "10.0.3.50"),
    };

    std::vector<int64_t> ids;
    {
        auto res = lib.addDevice(fleet);
        if (!res.ok()) {
            fprintf(stderr, "  AddDevice error: %s\n", res.error().c_str());
            return 1;
        }
        for (const auto& device : res->devices) {
            ids.push_back(device.deviceId);
            printf("  + %s -> id=%lld\n", device.name.c_str(), (long long)device.deviceId);
        }
    }
    // Let discovery events fire
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    printf("\n");

    // ── 5. List all devices — returns std::vector<DeviceInfo> ────────
    printf("--- Device inventory (%zu added) ---\n", ids.size());
    {
        auto res = lib.listDevices();
        if (!res.ok()) {
            fprintf(stderr, "  ListDevices error: %s\n", res.error().c_str());
        } else {
            // res->devices is std::vector<DeviceInfo>
            printf("  Count: %zu\n", res->devices.size());
            for (size_t i = 0; i < res->devices.size(); ++i) {
                auto& d = res->devices[i];
                printf("  [%zu] id=%-3lld  %-18s  type=%-10s  addr=%-16s  %s\n",
                       i, (long long)d.deviceId,
                       d.name.c_str(), d.deviceType.c_str(),
                       d.address.c_str(), d.online ? "online" : "offline");
            }
        }
    }
    printf("\n");

    // ── 6. Query one device ──────────────────────────────────────────
    if (!ids.empty()) {
        int64_t qid = ids[2];  // Edge-Switch-B
        printf("--- Query device id=%lld ---\n", (long long)qid);
        auto res = lib.getDevice(qid);
        if (!res.ok()) {
            fprintf(stderr, "  GetDevice error: %s\n", res.error().c_str());
        } else {
            printf("  name=\"%s\"  type=\"%s\"  addr=\"%s\"  online=%s\n",
                   res->name.c_str(), res->deviceType.c_str(),
                   res->address.c_str(), res->online ? "yes" : "no");
        }
        printf("\n");
    }

    // ── 7. Remove two devices (triggers DeviceStatusChanged × 2) ─────
    //    Both status listeners will fire for each removal.
    printf("--- Removing devices ---\n");
    for (int i : {0, 3}) {
        if (i >= (int)ids.size()) continue;
        auto res = lib.removeDevice(ids[i]);
        if (!res.ok()) {
            fprintf(stderr, "  RemoveDevice error: %s\n", res.error().c_str());
        } else {
            printf("  Removed id=%lld  success=%s\n",
                   (long long)ids[i], res->success ? "yes" : "no");
        }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    printf("\n");

    // ── 8. Remove individual status listener, keep the logger ────────
    printf("--- Removing first status listener (keeping logger) ---\n");
    lib.offDeviceStatusChanged(h_status);
    printf("  Removed handle %llu\n\n", (unsigned long long)h_status);

    // ── 9. Remove one more device — only logger should fire ──────────
    printf("--- Removing one more device (only logger active) ---\n");
    if (ids.size() > 1) {
        auto res = lib.removeDevice(ids[1]);
        if (res.ok())
            printf("  Removed id=%lld\n", (long long)ids[1]);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    printf("\n");

    // ── 10. List remaining ───────────────────────────────────────────
    printf("--- Remaining devices ---\n");
    {
        auto res = lib.listDevices();
        if (res.ok()) {
            printf("  Count: %zu\n", res->devices.size());
            for (auto& d : res->devices) {
                printf("  id=%-3lld  %-18s  type=%-10s  addr=%-16s  %s\n",
                       (long long)d.deviceId, d.name.c_str(),
                       d.deviceType.c_str(), d.address.c_str(),
                       d.online ? "online" : "offline");
            }
        }
    }
    printf("\n");

    // ── 11. Remove all event listeners ───────────────────────────────
    printf("--- Unsubscribing all ---\n");
    lib.offDeviceDiscovered();      // handle=0 → remove all
    lib.offDeviceStatusChanged();   // handle=0 → remove all
    printf("  All event listeners removed.\n\n");

    // ── 12. Summary ──────────────────────────────────────────────────
    printf("  Total discovery events received: %d\n", discoveryCount);
    printf("  Total status events received: %d\n\n", statusCount);

    // ── 13. Shutdown (RAII) ──────────────────────────────────────────
    printf("--- Shutting down (RAII) ---\n");
    // ~Mylib() calls mylib_shutdown(ctx_) automatically.

    printf("\n=== Modern C++ example complete ===\n");
    return 0;
}
