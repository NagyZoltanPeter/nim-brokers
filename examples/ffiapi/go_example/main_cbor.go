//go:build cbor

// CBOR-mode entry point for the Device Monitor Go example.

package main

import (
	"fmt"
	"os"
	"sync"
	"time"

	"mylib"
)

func runExample() {
	fmt.Println("=== mylib Go example (cbor) ===")
	fmt.Println("library version:", mylib.Version())

	lib := mylib.New()
	if err := lib.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("context created: ctx = %d\n", lib.Ctx())

	var (
		mu         sync.Mutex
		discovered []string
	)
	hDisc := lib.OnDeviceDiscovered(func(deviceId int64, name string, deviceType string, address string) {
		mu.Lock()
		discovered = append(discovered, fmt.Sprintf(
			"id=%d name=%s type=%s addr=%s", deviceId, name, deviceType, address))
		mu.Unlock()
	})
	fmt.Printf("OnDeviceDiscovered handle = %d\n", hDisc)

	init, err := lib.InitializeRequest("/etc/mylib.toml")
	if err != nil {
		fmt.Fprintln(os.Stderr, "InitializeRequest failed:", err)
	} else {
		fmt.Printf("InitializeRequest OK: %+v\n", init)
	}

	fleet := []mylib.AddDeviceSpec{
		{Name: "Core-Router", DeviceType: "router", Address: "10.0.0.1"},
		{Name: "Edge-Switch-A", DeviceType: "switch", Address: "10.0.1.1"},
	}
	add, err := lib.AddDevice(fleet)
	if err != nil {
		fmt.Fprintln(os.Stderr, "AddDevice failed:", err)
	} else {
		fmt.Printf("AddDevice OK: success=%v devices=%d\n", add.Success, len(add.Devices))
	}

	time.Sleep(300 * time.Millisecond)

	mu.Lock()
	fmt.Printf("Observed %d DeviceDiscovered events:\n", len(discovered))
	for _, d := range discovered {
		fmt.Println("  ", d)
	}
	mu.Unlock()

	lib.OffDeviceDiscovered(hDisc)
	lib.Close()
	fmt.Println("OK")
}
