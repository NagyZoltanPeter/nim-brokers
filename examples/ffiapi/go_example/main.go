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
//   On<Event>(closure) -> uint64                 each registered EventBroker (step 2)
//   Off<Event>(handle)                           (step 2)
//
// v1 native limitations: requests / events whose payloads use seq[T] /
// array[N, T] / nested objects beyond flat primitives emit a TODO stub
// in the generated module. Those are exercised by the CBOR build (step 3).

package main

import (
	"fmt"
	"os"

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

	nativeExercise(lib)

	lib.Close()
	fmt.Println("OK")
}

func nativeExercise(lib *mylib.Mylib) {
	// Initialize the library with a config path — primitive String arg,
	// returns (InitializeRequest, error). This is the smoke test that
	// the generated cgo + (T, error) path is wired up correctly.
	init, err := lib.InitializeRequest("/etc/mylib.toml")
	if err != nil {
		fmt.Fprintln(os.Stderr, "InitializeRequest failed:", err)
		return
	}
	fmt.Printf("InitializeRequest OK: %+v\n", init)
}
