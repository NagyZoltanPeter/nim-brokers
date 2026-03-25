/**
 * Device Monitor — pure C example
 * ================================
 * Demonstrates consuming the mylib Nim dynamic library from plain C.
 *
 * Exercises:
 *   - Library lifecycle (createContext / shutdown)
 *   - Adding devices in a single AddDevice batch request
 *   - Querying a single device (GetDevice request)
 *   - Listing all devices (ListDevices — returns an array of structs)
 *   - Removing a device (RemoveDevice request)
 *   - Event callbacks for DeviceDiscovered and DeviceStatusChanged
 *   - Proper memory cleanup via free_*_result functions
 *
 * Build (from repo root):
 *   nimble buildFfiExample        # builds the Nim dynamic library
 *   nimble buildFfiExampleC       # compiles this C application
 *
 * Run:
 *   ./examples/ffiapi/example/build/example
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mylib.h"

/* --------------------------------------------------------------------------
 * Platform-specific sleep
 * -------------------------------------------------------------------------- */
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif

/* --------------------------------------------------------------------------
 * Event callbacks (called on the Nim delivery thread — must not block)
 * -------------------------------------------------------------------------- */

static void on_device_discovered(
    int64_t deviceId, const char* name,
    const char* deviceType, const char* address)
{
    printf("  [event] DeviceDiscovered: id=%lld name=\"%s\" type=\"%s\" addr=\"%s\"\n",
           (long long)deviceId,
           name ? name : "(null)",
           deviceType ? deviceType : "(null)",
           address ? address : "(null)");
}

static void on_device_status_changed(
    int64_t deviceId, const char* name,
    _Bool online, int64_t timestampMs)
{
    printf("  [event] DeviceStatusChanged: id=%lld name=\"%s\" online=%s ts=%lld\n",
           (long long)deviceId,
           name ? name : "(null)",
           online ? "true" : "false",
           (long long)timestampMs);
}

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */

int main(void) {
    printf("=== Device Monitor — C Example ===\n\n");

    /* ── 1. Create library context ────────────────────────────────────── */
    printf("1. Create library context\n");
    mylibCreateContextResult create_res = mylib_createContext();
    if (create_res.error_message) {
        fprintf(stderr, "   FATAL: %s\n", create_res.error_message);
        free_mylib_create_context_result(&create_res);
        return 1;
    }
    uint32_t ctx = create_res.ctx;
    free_mylib_create_context_result(&create_res);
    printf("   ctx = 0x%08X\n\n", ctx);

    /* ── 2. Register event listeners ──────────────────────────────────── */
    printf("2. Register event listeners\n");
    uint64_t h_discovered = mylib_onDeviceDiscovered(ctx, on_device_discovered);
    uint64_t h_status     = mylib_onDeviceStatusChanged(ctx, on_device_status_changed);
    printf("   DeviceDiscovered handle:     %llu\n", (unsigned long long)h_discovered);
    printf("   DeviceStatusChanged handle:  %llu\n\n", (unsigned long long)h_status);

    /* ── 3. Initialize the library ────────────────────────────────────── */
    printf("3. Configure library (InitializeRequest)\n");
    {
        InitializeRequestCResult res =
            mylib_initialize(ctx, "/etc/devices.conf");
        if (res.error_message) {
            fprintf(stderr, "   ERROR: %s\n", res.error_message);
            mylib_free_initialize_result(&res);
            mylib_shutdown(ctx);
            return 1;
        }
        printf("   initialized=%s  configPath=\"%s\"\n",
               res.initialized ? "true" : "false",
               res.configPath ? res.configPath : "(null)");
         mylib_free_initialize_result(&res);
    }
    printf("\n");

    /* ── 4. Add some devices ──────────────────────────────────────────── */
    printf("4. Add devices\n");
    int64_t id_gw = 0, id_sensor = 0, id_cam = 0;
    {
        AddDeviceSpecCItem fleet[] = {
            {(char *)"Gateway-01", (char *)"gateway", (char *)"192.168.1.1"},
            {(char *)"TempSensor-A3", (char *)"sensor", (char *)"192.168.1.42"},
            {(char *)"Camera-North", (char *)"camera", (char *)"192.168.1.80"},
        };
        AddDeviceCResult r = mylib_add_device(ctx, fleet, 3);
        if (r.error_message) {
            fprintf(stderr, "   ERROR: %s\n", r.error_message);
        } else {
            DeviceInfoCItem* added = r.devices;
            if (r.devices_count >= 3 && added != NULL) {
                id_gw = added[0].deviceId;
                id_sensor = added[1].deviceId;
                id_cam = added[2].deviceId;
            }
            for (int32_t i = 0; i < r.devices_count; ++i) {
                printf("   Added %-14s -> id=%lld\n",
                       added[i].name ? added[i].name : "(null)",
                       (long long)added[i].deviceId);
            }
        }
        mylib_free_add_device_result(&r);
    }
    /* Let discovery events fire */
    sleep_ms(200);
    printf("\n");

    /* ── 5. List all devices ──────────────────────────────────────────── */
    printf("5. List all devices\n");
    {
        ListDevicesCResult lr = mylib_list_devices(ctx);
        if (lr.error_message) {
            fprintf(stderr, "   ERROR: %s\n", lr.error_message);
        } else {
            printf("   Total devices: %d\n", lr.devices_count);
            for (int32_t i = 0; i < lr.devices_count; i++) {
                DeviceInfoCItem* d = &lr.devices[i];
                printf("   [%d] id=%lld  name=\"%s\"  type=\"%s\"  addr=\"%s\"  online=%s\n",
                       i,
                       (long long)d->deviceId,
                       d->name ? d->name : "(null)",
                       d->deviceType ? d->deviceType : "(null)",
                       d->address ? d->address : "(null)",
                       d->online ? "true" : "false");
            }
        }
        mylib_free_list_devices_result(&lr);
    }
    printf("\n");

    /* ── 6. Query a single device ─────────────────────────────────────── */
    printf("6. Query single device (id=%lld)\n", (long long)id_sensor);
    {
        GetDeviceCResult gr = mylib_get_device(ctx, id_sensor);
        if (gr.error_message) {
            fprintf(stderr, "   ERROR: %s\n", gr.error_message);
        } else {
            printf("   name=\"%s\"  type=\"%s\"  addr=\"%s\"  online=%s\n",
                   gr.name ? gr.name : "(null)",
                   gr.deviceType ? gr.deviceType : "(null)",
                   gr.address ? gr.address : "(null)",
                   gr.online ? "true" : "false");
        }
        mylib_free_get_device_result(&gr);
    }
    printf("\n");

    /* ── 7. Remove a device (triggers DeviceStatusChanged) ────────────── */
    printf("7. Remove device (id=%lld)\n", (long long)id_cam);
    {
        RemoveDeviceCResult rr = mylib_remove_device(ctx, id_cam);
        if (rr.error_message) {
            fprintf(stderr, "   ERROR: %s\n", rr.error_message);
        } else {
            printf("   success=%s\n", rr.success ? "true" : "false");
        }
        mylib_free_remove_device_result(&rr);
    }
    sleep_ms(200);
    printf("\n");

    /* ── 8. List again — should show 2 devices ────────────────────────── */
    printf("8. List devices after removal\n");
    {
        ListDevicesCResult lr = mylib_list_devices(ctx);
        if (lr.error_message) {
            fprintf(stderr, "   ERROR: %s\n", lr.error_message);
        } else {
            printf("   Total devices: %d\n", lr.devices_count);
            for (int32_t i = 0; i < lr.devices_count; i++) {
                DeviceInfoCItem* d = &lr.devices[i];
                printf("   [%d] id=%lld  name=\"%s\"\n",
                       i, (long long)d->deviceId,
                       d->name ? d->name : "(null)");
            }
        }
        mylib_free_list_devices_result(&lr);
    }
    printf("\n");

    /* ── 10. Unregister listeners & shutdown ───────────────────────────── */
    printf("10. Cleanup and shutdown\n");
    mylib_offDeviceDiscovered(ctx, 0);        /* remove all discovery listeners */
    mylib_offDeviceStatusChanged(ctx, 0);     /* remove all status listeners */
    printf("    Listeners removed.\n");

    mylib_shutdown(ctx);
    printf("    Context shut down.\n\n");

    printf("=== C example complete ===\n");
    return 0;
}
