// Device Monitor — Go wrapper example.
//
// Drives the same `mylib` shared library that the C, C++, Python, and
// Rust examples consume. Exercises the full FFI surface: lifecycle,
// every request, every event broker. The same source compiles for
// both native and CBOR builds because the generated wrapper exposes
// an identical method set in either mode (the build-tag split lives
// inside the generated `<libName>_go/` module, not here).
//
//     go run .                # native FFI build  (nimlib/build/)
//     go run -tags cbor .     # CBOR FFI build    (nimlib/build_cbor/)

package main

import (
	"fmt"
	"os"
	"sync"
	"time"

	"mylib"
)

func main() {
	fmt.Println("=== mylib Go example ===")
	fmt.Println("library version:", mylib.Version())

	lib := mylib.New()
	if err := lib.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("Library context: 0x%08X\n\n", lib.Ctx())

	// --- Subscribe to every event broker -------------------------------
	var (
		mu          sync.Mutex
		discovered  []string
		statusLog   []string
		alertLog    []string
		batchCount  int
	)

	hDisc := lib.OnDeviceDiscovered(func(deviceId int64, name string, deviceType string, address string) {
		mu.Lock()
		discovered = append(discovered, fmt.Sprintf("id=%d name=%s type=%s addr=%s", deviceId, name, deviceType, address))
		mu.Unlock()
	})
	hStatus := lib.OnDeviceStatusChanged(func(deviceId int64, name string, online bool, timestampMs int64) {
		mu.Lock()
		state := "offline"
		if online {
			state = "online"
		}
		statusLog = append(statusLog, fmt.Sprintf("id=%d %s %s ts=%d", deviceId, name, state, timestampMs))
		mu.Unlock()
	})
	// Second listener on the same event — exercises the dispatcher's
	// fan-out path. Mirrors the cpp example's `h_status2`.
	hStatus2 := lib.OnDeviceStatusChanged(func(deviceId int64, _ string, _ bool, _ int64) {
		_ = deviceId
	})
	hAlert := lib.OnSensorAlert(func(sensorId int32, deviceId int64, status mylib.DeviceStatus, timestampMs int64) {
		mu.Lock()
		alertLog = append(alertLog, fmt.Sprintf("sensor=%d device=%d status=%d ts=%d", sensorId, deviceId, status, timestampMs))
		mu.Unlock()
	})
	hBatch := lib.OnDeviceBatch(func(labels []string, deviceIds []int64, capabilities []int32) {
		mu.Lock()
		batchCount++
		fmt.Printf("  >>> DeviceBatch #%d: labels=%v ids=%v caps=%v\n", batchCount, labels, deviceIds, capabilities)
		mu.Unlock()
	})
	fmt.Printf("Handles: disc=%d status=%d status2=%d alert=%d batch=%d\n\n",
		hDisc, hStatus, hStatus2, hAlert, hBatch)

	// --- Configure the library -----------------------------------------
	fmt.Println("--- Configuring library ---")
	if init, err := lib.InitializeRequest("/opt/devices.yaml"); err != nil {
		fmt.Fprintln(os.Stderr, "InitializeRequest failed:", err)
	} else {
		fmt.Printf("  config=%s initialized=%v\n\n", init.ConfigPath, init.Initialized)
	}

	// --- Add a fleet of devices ----------------------------------------
	fmt.Println("--- Adding devices ---")
	fleet := []mylib.AddDeviceSpec{
		{Name: "Core-Router", DeviceType: "router", Address: "10.0.0.1"},
		{Name: "Edge-Switch-A", DeviceType: "switch", Address: "10.0.1.1"},
		{Name: "Edge-Switch-B", DeviceType: "switch", Address: "10.0.1.2"},
		{Name: "AP-Floor-3", DeviceType: "ap", Address: "10.0.2.10"},
		{Name: "TempSensor-DC1", DeviceType: "sensor", Address: "10.0.3.50"},
	}
	add, err := lib.AddDevice(fleet)
	if err != nil {
		fmt.Fprintln(os.Stderr, "AddDevice failed:", err)
		lib.Close()
		os.Exit(1)
	}
	ids := make([]int64, 0, len(add.Devices))
	for _, d := range add.Devices {
		ids = append(ids, d.DeviceId)
		fmt.Printf("  + %s -> id=%d\n", d.Name, d.DeviceId)
	}
	time.Sleep(300 * time.Millisecond)
	fmt.Println()

	// --- Inventory -----------------------------------------------------
	fmt.Printf("--- Device inventory (%d added) ---\n", len(ids))
	if listed, err := lib.ListDevices(); err != nil {
		fmt.Fprintln(os.Stderr, "ListDevices failed:", err)
	} else {
		fmt.Printf("  Count: %d\n", len(listed.Devices))
		for i, d := range listed.Devices {
			state := "offline"
			if d.Online {
				state = "online"
			}
			fmt.Printf("  [%d] id=%d %-18s type=%-10s addr=%-16s %s\n",
				i, d.DeviceId, d.Name, d.DeviceType, d.Address, state)
		}
	}
	fmt.Println()

	// --- Per-device queries: getDevice / getSensorData / getDeviceTags
	//     / getDeviceCapabilities ----------------------------------------
	fmt.Println("--- Per-device queries ---")
	for _, qid := range ids {
		gd, err := lib.GetDevice(qid)
		if err != nil {
			continue
		}
		fmt.Printf("  GetDevice(%d): %s [%s]\n", qid, gd.Name, gd.Address)

		if sd, err := lib.GetSensorData(qid); err == nil {
			fmt.Printf("    GetSensorData: sensor=%d %d bytes\n", sd.SensorId, len(sd.RawData))
		}
		if tg, err := lib.GetDeviceTags(qid); err == nil {
			fmt.Printf("    GetDeviceTags: %v\n", tg.Tags)
		}
		if cp, err := lib.GetDeviceCapabilities(qid); err == nil {
			fmt.Printf("    GetDeviceCapabilities: %v\n", cp.Capabilities)
		}
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Println()

	// --- Remove a couple of devices ------------------------------------
	if len(ids) > 1 {
		fmt.Println("--- Removing devices ---")
		if _, err := lib.RemoveDevice(ids[1]); err == nil {
			fmt.Printf("  RemoveDevice(%d) ok\n", ids[1])
		}
		if len(ids) > 2 {
			if _, err := lib.RemoveDevice(ids[2]); err == nil {
				fmt.Printf("  RemoveDevice(%d) ok\n", ids[2])
			}
		}
		time.Sleep(200 * time.Millisecond)
		fmt.Println()
	}

	// --- Drop one of the listeners, let the rest keep firing -----------
	lib.OffDeviceStatusChanged(hStatus)
	time.Sleep(200 * time.Millisecond)

	// --- Final report ---------------------------------------------------
	mu.Lock()
	fmt.Println("--- Event totals ---")
	fmt.Printf("  DeviceDiscovered events: %d\n", len(discovered))
	fmt.Printf("  DeviceStatusChanged events: %d\n", len(statusLog))
	fmt.Printf("  SensorAlert events: %d\n", len(alertLog))
	fmt.Printf("  DeviceBatch events: %d\n", batchCount)
	mu.Unlock()

	lib.Close()
	fmt.Println("OK")
}
