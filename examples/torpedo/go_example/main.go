// Torpedo Duel — Go wrapper example.
//
// Counterpart to the C++/Python/Rust torpedo examples. Native build
// exercises lifecycle + primitive-arg requests. CBOR build exercises
// the full request/event surface.
//
//     go run .                # native FFI build (nimlib/build/)
//     go run -tags cbor .     # CBOR FFI build   (nimlib/build_cbor/)

package main

func main() {
	runExample()
}
