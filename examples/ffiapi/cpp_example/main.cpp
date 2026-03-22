/**
 * Device Monitor — modern C++ example
 * =====================================
 * Demonstrates consuming the mylib Nim dynamic library through the
 * generated C++ wrapper class (Mylib).  Uses RAII, lambdas, and
 * structured bindings for a natural C++ feel.
 *
 * Exercises:
 *   - RAII lifecycle via the Mylib wrapper class
 *   - Request methods (addDevice, getDevice, listDevices, removeDevice)
 *   - Array-of-struct results (ListDevices → DeviceInfoCItem[])
 *   - Event callbacks (DeviceDiscovered, DeviceStatusChanged)
 *   - Generated free_*_result helpers for safe cleanup
 *
 * Build (from repo root):
 *   nimble buildFfiExample          # builds the Nim dynamic library
 *   nimble buildFfiExampleCpp       # compiles this C++ application
 *
 * Run:
 *   ./examples/ffiapi/cpp_example/build/example
 */

#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "mylib.h"

/* --------------------------------------------------------------------------
 * RAII helper: auto-free a CResult when it goes out of scope
 * -------------------------------------------------------------------------- */
template <typename T, typename FreeFn>
class AutoResult {
    T result_;
    FreeFn free_;
public:
    AutoResult(T r, FreeFn f) : result_(r), free_(f) {}
    ~AutoResult() { free_(&result_); }
    AutoResult(const AutoResult&) = delete;
    AutoResult& operator=(const AutoResult&) = delete;

    const T* operator->() const { return &result_; }
    const T& operator*()  const { return result_; }
    T*       ptr()               { return &result_; }
    bool     ok()          const { return result_.error_message == nullptr; }
    const char* error()    const { return result_.error_message; }
};

/* Deduction guide so we can write: AutoResult res{call(), free_fn}; */
template <typename T, typename F>
AutoResult(T, F) -> AutoResult<T, F>;

/* --------------------------------------------------------------------------
 * Pretty-print helpers
 * -------------------------------------------------------------------------- */
static void print_device(const DeviceInfoCItem& d, int idx = -1) {
    if (idx >= 0)
        printf("  [%d] ", idx);
    else
        printf("  ");
    printf("id=%-3lld  %-18s  type=%-10s  addr=%-16s  %s\n",
           (long long)d.deviceId,
           d.name ? d.name : "(null)",
           d.deviceType ? d.deviceType : "(null)",
           d.address ? d.address : "(null)",
           d.online ? "online" : "offline");
}

/* --------------------------------------------------------------------------
 * Event callbacks
 * -------------------------------------------------------------------------- */
static void on_discovered(
    int64_t id, const char* name, const char* type, const char* addr)
{
    printf("  >>> DeviceDiscovered: id=%lld  \"%s\"  [%s]  %s\n",
           (long long)id, name, type, addr);
}

static void on_status_changed(
    int64_t id, const char* name, bool online, int64_t ts)
{
    printf("  >>> DeviceStatusChanged: id=%lld  \"%s\"  %s  (ts=%lld)\n",
           (long long)id, name, online ? "ONLINE" : "OFFLINE", (long long)ts);
}

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */
int main() {
    printf("=== Device Monitor — C++ Example ===\n\n");

    // ── 1. Create the library wrapper (RAII) ─────────────────────────
    Mylib::initialize();
    Mylib lib;
    if (!lib.init()) {
        fprintf(stderr, "FATAL: library init failed\n");
        return 1;
    }
    printf("Library context: 0x%08X\n\n", lib.ctx());
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    // ── 2. Subscribe to events ───────────────────────────────────────
    printf("--- Subscribing to events ---\n");
    auto h_disc   = lib.onDeviceDiscovered(on_discovered);
    auto h_status = lib.onDeviceStatusChanged(on_status_changed);
    printf("  Handles: discovered=%llu  status=%llu\n\n",
           (unsigned long long)h_disc, (unsigned long long)h_status);

    // ── 3. Initialize the monitoring engine ──────────────────────────
    printf("--- Initializing ---\n");
    {
        AutoResult res{lib.initRequest("/opt/devices.yaml"),
                       free_init_request_result};
        if (!res.ok()) {
            fprintf(stderr, "Init error: %s\n", res.error());
            return 1;
        }
        printf("  config=%s  initialized=%s\n\n",
               res->configPath ? res->configPath : "(null)",
               res->initialized ? "yes" : "no");
    }

    // ── 4. Add a fleet of devices ────────────────────────────────────
    printf("--- Adding devices ---\n");
    struct DeviceDef { const char* name; const char* type; const char* addr; };
    std::vector<DeviceDef> fleet = {
        {"Core-Router",      "router",  "10.0.0.1"},
        {"Edge-Switch-A",    "switch",  "10.0.1.1"},
        {"Edge-Switch-B",    "switch",  "10.0.1.2"},
        {"AP-Floor-3",       "ap",      "10.0.2.10"},
        {"TempSensor-DC1",   "sensor",  "10.0.3.50"},
    };

    std::vector<int64_t> ids;
    for (auto& [name, type, addr] : fleet) {
        AutoResult res{lib.addDevice(name, type, addr),
                       free_add_device_result};
        if (!res.ok()) {
            fprintf(stderr, "  AddDevice error: %s\n", res.error());
            continue;
        }
        ids.push_back(res->deviceId);
        printf("  + %s -> id=%lld\n", name, (long long)res->deviceId);
    }
    /* Let discovery events fire */
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    printf("\n");

    // ── 5. List all devices ──────────────────────────────────────────
    printf("--- Device inventory (%zu added) ---\n", ids.size());
    {
        AutoResult res{lib.listDevices(), free_list_devices_result};
        if (!res.ok()) {
            fprintf(stderr, "  ListDevices error: %s\n", res.error());
        } else {
            printf("  Count: %d\n", res->devices_count);
            for (int32_t i = 0; i < res->devices_count; ++i) {
                print_device(res->devices[i], i);
            }
        }
    }
    printf("\n");

    // ── 6. Query one device ──────────────────────────────────────────
    if (!ids.empty()) {
        int64_t qid = ids[2];  // Edge-Switch-B
        printf("--- Query device id=%lld ---\n", (long long)qid);
        AutoResult res{lib.getDevice(qid), free_get_device_result};
        if (!res.ok()) {
            fprintf(stderr, "  GetDevice error: %s\n", res.error());
        } else {
            printf("  name=\"%s\"  type=\"%s\"  addr=\"%s\"  online=%s\n",
                   res->name, res->deviceType, res->address,
                   res->online ? "yes" : "no");
        }
        printf("\n");
    }

    // ── 7. Remove two devices (triggers DeviceStatusChanged) ─────────
    printf("--- Removing devices ---\n");
    for (int i : {0, 3}) {  // Core-Router, AP-Floor-3
        if (i >= (int)ids.size()) continue;
        AutoResult res{lib.removeDevice(ids[i]), free_remove_device_result};
        if (!res.ok()) {
            fprintf(stderr, "  RemoveDevice error: %s\n", res.error());
        } else {
            printf("  Removed id=%lld  success=%s\n",
                   (long long)ids[i], res->success ? "yes" : "no");
        }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    printf("\n");

    // ── 8. List again — should show 3 remaining ─────────────────────
    printf("--- Remaining devices ---\n");
    {
        AutoResult res{lib.listDevices(), free_list_devices_result};
        if (!res.ok()) {
            fprintf(stderr, "  ListDevices error: %s\n", res.error());
        } else {
            printf("  Count: %d\n", res->devices_count);
            for (int32_t i = 0; i < res->devices_count; ++i) {
                print_device(res->devices[i], i);
            }
        }
    }
    printf("\n");

    // ── 9. Unsubscribe from events ───────────────────────────────────
    printf("--- Unsubscribing ---\n");
    lib.offDeviceDiscovered(h_disc);
    printf("  Removed DeviceDiscovered listener.\n");
    lib.offDeviceStatusChanged(0);   // remove all status listeners
    printf("  Removed all DeviceStatusChanged listeners.\n\n");

    // ── 10. Shutdown (RAII destructor calls lib.shutdown()) ───────────
    printf("--- Shutting down (RAII) ---\n");
    // ~Mylib() will call mylib_shutdown(ctx_) automatically.

    printf("\n=== C++ example complete ===\n");
    return 0;
}
