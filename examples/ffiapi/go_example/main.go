// Device Monitor — Go wrapper example.
//
// Drives the same `mylib` shared library that the C, C++, Python, and
// Rust examples consume. The generated wrapper module is included via
// the `replace mylib => ../nimlib/build/mylib_go` directive in go.mod.
//
// The wrapper's public surface mirrors the C++ wrapper class:
//   mylib.Version()                              static
//   mylib.New() + lib.CreateContext()            lifecycle
//   <Request>(args) -> (T, error)                each registered RequestBroker
//   On<Event>(callback) -> uint64                each registered EventBroker
//   Off<Event>(handle)
//
// v1 native limitations: requests / events whose payloads use seq[T] /
// array[N, T] / nested objects beyond flat primitives emit a TODO stub
// in the generated module. Those are exercised by the CBOR build (step 3).

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
	fmt.Printf("context created: ctx = %d\n", lib.Ctx())

	// --- Event subscription smoke test --------------------------------
	var (
		mu        sync.Mutex
		discovered []string
	)
	hDisc := lib.OnDeviceDiscovered(func(deviceId int64, name string, deviceType string, address string) {
		mu.Lock()
		discovered = append(discovered, fmt.Sprintf("id=%d name=%s type=%s addr=%s", deviceId, name, deviceType, address))
		mu.Unlock()
	})
	fmt.Printf("OnDeviceDiscovered handle = %d\n", hDisc)

	// --- Configure -----------------------------------------------------
	init, err := lib.InitializeRequest("/etc/mylib.toml")
	if err != nil {
		fmt.Fprintln(os.Stderr, "InitializeRequest failed:", err)
	} else {
		fmt.Printf("InitializeRequest OK: %+v\n", init)
	}

	// --- AddDevice triggers DeviceDiscovered events --------------------
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

	// Allow the delivery thread to drain any pending event callbacks.
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
