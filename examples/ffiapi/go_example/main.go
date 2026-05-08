// Device Monitor — Go wrapper example.
//
// Drives the same `mylib` shared library that the C, C++, Python, and
// Rust examples consume. Two modes are exercised via Go build tags:
//
//     go run .                # native FFI build  (nimlib/build/)
//     go run -tags cbor .     # CBOR FFI build    (nimlib/build_cbor/)
//
// Each mode has its own `main_<mode>.go` defining `runExample`. The
// generated wrapper module's <libName>.go (native) and <libName>_cbor.go
// (cbor) are guarded by matching `//go:build` constraints, so a single
// import path "mylib" works in either mode.

package main

func main() {
	runExample()
}
