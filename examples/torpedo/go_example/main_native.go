//go:build !cbor

package main

import (
	"fmt"
	"os"

	"torpedolib"
)

func runExample() {
	fmt.Println("=== torpedolib Go example (native) ===")
	fmt.Println("library version:", torpedolib.Version())

	red := torpedolib.New()
	if err := red.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "red.CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("red ctx: %d\n", red.Ctx())

	blue := torpedolib.New()
	if err := blue.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "blue.CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("blue ctx: %d\n", blue.Ctx())

	// Native-mode v1 only emits primitive-arg request stubs, but
	// initialize_captain_request fits — strings + int32/int64.
	init, err := red.InitializeCaptainRequest("Red", 8, "balanced", 101, 50)
	if err != nil {
		fmt.Fprintln(os.Stderr, "red.InitializeCaptainRequest failed:", err)
	} else {
		fmt.Printf("red InitializeCaptainRequest OK: %+v\n", init)
	}

	blue.Close()
	red.Close()
	fmt.Println("OK")
}
