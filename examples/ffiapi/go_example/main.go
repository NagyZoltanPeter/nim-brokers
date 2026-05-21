// Device Monitor — Go wrapper example.
//
// Functional parity with cpp_example/main.cpp: same event printouts,
// same request flow, same listener-removal pattern. Linked against
// the FFI library produced by `nimble buildFfiExample` into
// nimlib/build/.
//
//     go run .

package main

import (
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"mylib"
)

func main() {
	fmt.Println("=== Device Monitor — Go Example ===")
	fmt.Println()

	lib := mylib.New()
	if err := lib.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
	fmt.Printf("Library context: 0x%08X\n\n", lib.Ctx())

	// --- Subscribe to events (matches cpp inline-print style) ----------
	fmt.Println("--- Subscribing to events ---")

	var discoveryCount, statusCount, batchCount int32
	hDisc := lib.OnDeviceDiscovered(func(id int64, name string, typ string, addr string) {
		n := atomic.AddInt32(&discoveryCount, 1)
		fmt.Printf("  >>> DeviceDiscovered #%d: id=%d  %q  [%s]  %s\n", n, id, name, typ, addr)
	})
	hStatus := lib.OnDeviceStatusChanged(func(id int64, name string, online bool, ts int64) {
		n := atomic.AddInt32(&statusCount, 1)
		state := "OFFLINE"
		if online {
			state = "ONLINE"
		}
		fmt.Printf("  >>> DeviceStatusChanged #%d: id=%d  %q  %s  (ts=%d)\n", n, id, name, state, ts)
	})
	hBatch := lib.OnDeviceBatch(func(labels []string, deviceIds []int64, capabilities []int32) {
		n := atomic.AddInt32(&batchCount, 1)
		fmt.Printf("  >>> DeviceBatch #%d: %d devices\n", n, len(labels))
		fmt.Printf("      labels:       [%s]\n", quoteStrings(labels))
		fmt.Printf("      ids:          [%s]\n", joinInt64(deviceIds))
		fmt.Printf("      capabilities: [%s]\n", joinInt32(capabilities))
	})
	hAlert := lib.OnSensorAlert(func(sensorId int32, deviceId int64, status mylib.DeviceStatus, ts int64) {
		fmt.Printf("  >>> SensorAlert: sensorId=%d  deviceId=%d  status=%d  ts=%d\n",
			sensorId, deviceId, int(status), ts)
	})
	fmt.Printf("  SensorAlert handle: %d\n", hAlert)
	hStatus2 := lib.OnDeviceStatusChanged(func(_ int64, name string, online bool, _ int64) {
		state := "DOWN"
		if online {
			state = "UP"
		}
		fmt.Printf("  >>> [Logger] %s is now %s\n", name, state)
	})
	fmt.Printf("  Handles: discovered=%d  status=%d  status2=%d  batch=%d\n\n",
		hDisc, hStatus, hStatus2, hBatch)

	// --- Configure ------------------------------------------------------
	fmt.Println("--- Configuring library ---")
	init, err := lib.InitializeRequest("/opt/devices.yaml")
	if err != nil {
		fmt.Fprintln(os.Stderr, "Initialize error:", err)
		lib.Close()
		os.Exit(1)
	}
	yes := "no"
	if init.Initialized {
		yes = "yes"
	}
	fmt.Printf("  config=%s  initialized=%s\n\n", init.ConfigPath, yes)

	// --- Add devices ----------------------------------------------------
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
		fmt.Fprintln(os.Stderr, "  AddDevice error:", err)
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

	// --- Inventory ------------------------------------------------------
	fmt.Printf("--- Device inventory (%d added) ---\n", len(ids))
	if listed, err := lib.ListDevices(); err == nil {
		fmt.Printf("  Count: %d\n", len(listed.Devices))
		for i, d := range listed.Devices {
			state := "offline"
			if d.Online {
				state = "online"
			}
			fmt.Printf("  [%d] id=%-3d  %-18s  type=%-10s  addr=%-16s  %s\n",
				i, d.DeviceId, d.Name, d.DeviceType, d.Address, state)
		}
	}
	fmt.Println()

	// --- Query one device (cpp picks ids[2] = Edge-Switch-B) -----------
	if len(ids) > 2 {
		qid := ids[2]
		fmt.Printf("--- Query device id=%d ---\n", qid)
		if gd, err := lib.GetDevice(qid); err == nil {
			online := "no"
			if gd.Online {
				online = "yes"
			}
			fmt.Printf("  name=%q  type=%q  addr=%q  online=%s\n",
				gd.Name, gd.DeviceType, gd.Address, online)
		}
		fmt.Println()
	}

	// --- New type demos (cpp uses ids[0] = Core-Router) ----------------
	if len(ids) > 0 {
		qid := ids[0]
		fmt.Println("--- GetSensorData (seq[byte] + enum + distinct) ---")
		if sd, err := lib.GetSensorData(qid); err == nil {
			n := len(sd.RawData)
			if n > 8 {
				n = 8
			}
			parts := make([]string, n)
			for i := 0; i < n; i++ {
				parts[i] = fmt.Sprintf("0x%02X", sd.RawData[i])
			}
			fmt.Printf("  sensorId=%d  status=%d  rawData[%d]: %s\n",
				sd.SensorId, int(sd.Status), len(sd.RawData), strings.Join(parts, " "))
		}
		fmt.Println("--- GetDeviceTags (seq[string]) ---")
		if tg, err := lib.GetDeviceTags(qid); err == nil {
			fmt.Printf("  tags[%d]: %s\n", len(tg.Tags), quoteStrings(tg.Tags))
		}
		fmt.Println("--- GetDeviceCapabilities (array[4,int32] + Timestamp) ---")
		if cp, err := lib.GetDeviceCapabilities(qid); err == nil {
			fmt.Printf("  capturedAt=%d  caps=[%s]\n",
				int64(cp.CapturedAt), joinInt32(cp.Capabilities))
		}
		time.Sleep(200 * time.Millisecond)
		fmt.Println()
	}

	// --- Remove two (cpp removes idx 0 and 3) --------------------------
	fmt.Println("--- Removing devices ---")
	for _, i := range []int{0, 3} {
		if i >= len(ids) {
			continue
		}
		if rm, err := lib.RemoveDevice(ids[i]); err == nil {
			ok := "no"
			if rm.Success {
				ok = "yes"
			}
			fmt.Printf("  Removed id=%d  success=%s\n", ids[i], ok)
		} else {
			fmt.Fprintln(os.Stderr, "  RemoveDevice error:", err)
		}
	}
	time.Sleep(200 * time.Millisecond)
	fmt.Println()

	// --- Drop primary status listener (logger keeps firing) ------------
	fmt.Println("--- Removing first status listener (keeping logger) ---")
	lib.OffDeviceStatusChanged(hStatus)
	fmt.Printf("  Removed handle %d\n\n", hStatus)

	// --- Remove one more device, only logger should fire ----------------
	fmt.Println("--- Removing one more device (only logger active) ---")
	if len(ids) > 1 {
		if _, err := lib.RemoveDevice(ids[1]); err == nil {
			fmt.Printf("  Removed id=%d\n", ids[1])
		}
	}
	time.Sleep(200 * time.Millisecond)
	fmt.Println()

	// --- Remaining inventory --------------------------------------------
	fmt.Println("--- Remaining devices ---")
	if listed, err := lib.ListDevices(); err == nil {
		fmt.Printf("  Count: %d\n", len(listed.Devices))
		for _, d := range listed.Devices {
			state := "offline"
			if d.Online {
				state = "online"
			}
			fmt.Printf("  id=%-3d  %-18s  type=%-10s  addr=%-16s  %s\n",
				d.DeviceId, d.Name, d.DeviceType, d.Address, state)
		}
	}
	fmt.Println()

	// --- Unsubscribe all ------------------------------------------------
	fmt.Println("--- Unsubscribing all ---")
	lib.OffDeviceDiscovered(0)    // 0 -> remove all
	lib.OffSensorAlert(0)         // 0 -> remove all
	lib.OffDeviceBatch(hBatch)    // by handle
	lib.OffDeviceStatusChanged(0) // 0 -> remove all
	fmt.Println("  All event listeners removed.")
	fmt.Println()

	// --- Summary --------------------------------------------------------
	fmt.Printf("  Total discovery events received: %d\n", atomic.LoadInt32(&discoveryCount))
	fmt.Printf("  Total status events received: %d\n\n", atomic.LoadInt32(&statusCount))
	fmt.Printf("  Total batch events received:    %d\n\n", atomic.LoadInt32(&batchCount))

	fmt.Println("--- Shutting down (RAII) ---")
	lib.Close()
	fmt.Println()
	fmt.Println("=== Go example complete ===")
}

func quoteStrings(ss []string) string {
	parts := make([]string, len(ss))
	for i, s := range ss {
		parts[i] = fmt.Sprintf("%q", s)
	}
	return strings.Join(parts, ", ")
}

func joinInt64(vs []int64) string {
	parts := make([]string, len(vs))
	for i, v := range vs {
		parts[i] = fmt.Sprintf("%d", v)
	}
	return strings.Join(parts, ", ")
}

func joinInt32(vs []int32) string {
	parts := make([]string, len(vs))
	for i, v := range vs {
		parts[i] = fmt.Sprintf("%d", v)
	}
	return strings.Join(parts, ", ")
}
