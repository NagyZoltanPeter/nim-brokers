//go:build cbor

package main

import "typemappingtestlib"

func test_obj_as_param() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjParamRequest(typemappingtestlib.Tag{Key: "k", Value: "v"})
	check(err == nil, "is_ok")
	checkEq(r.Summary, "k=v", "summary")
	lib.Close()
}

// Option[seq[byte]] probe — gated to CBOR (native codegen rejects
// Option[T]). The Go CBOR wrapper maps it to *[]byte (nil = absent).
func test_opt_seq_present() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptSeqRequest(true)
	check(err == nil, "is_ok")
	check(r.Value != nil, "value present")
	if r.Value != nil {
		checkEq(len(*r.Value), 4, "len")
		checkEq((*r.Value)[0], byte(1), "byte[0]")
		checkEq((*r.Value)[3], byte(4), "byte[3]")
	}
	lib.Close()
}

func test_opt_seq_absent() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptSeqRequest(false)
	check(err == nil, "is_ok")
	check(r.Value == nil, "value absent")
	lib.Close()
}

// Inbound seq[byte] probe — Go's fxamacker/cbor encodes []byte as CBOR
// byte string (major type 2) by default, which the Nim provider expects.
func test_bytes_echo_request_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.BytesEchoRequest([]byte{10, 20, 30, 40, 50})
	check(err == nil, "is_ok")
	checkEq(r.Length, int32(5), "length")
	checkEq(r.First, int32(10), "first")
	checkEq(r.Last, int32(50), "last")
	lib.Close()
}

func test_bytes_echo_request_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.BytesEchoRequest([]byte{})
	check(err == nil, "is_ok")
	checkEq(r.Length, int32(0), "length")
	checkEq(r.First, int32(-1), "first")
	checkEq(r.Last, int32(-1), "last")
	lib.Close()
}

// ScanRequest STRUCTURAL probe — proves the Go wrapper compiled with
// the generated KeyRange / TupleRow / ScanRequest types and that
// ScanRequest is a method on the lib. Round-trip is NOT asserted: Nim
// cbor_serialization writes named tuples positionally (CBOR array)
// while the wrapper struct expects a CBOR map. The keyword-escape
// (`range` → `rangeArg`) is verified by virtue of the file compiling
// with the generated method signature.
func test_scan_request_types_emitted() {
	kr := typemappingtestlib.KeyRange{StartKey: "lo", StopKey: "hi"}
	checkEq(kr.StartKey, "lo", "kr.StartKey")
	tr := typemappingtestlib.TupleRow{Key: "k", Payload: "p"}
	sr := typemappingtestlib.ScanRequest{Rows: []typemappingtestlib.TupleRow{tr}}
	checkEq(len(sr.Rows), 1, "row count")
	checkEq(sr.Rows[0].Key, "k", "row[0].Key")
	// Reference the method without calling it.
	_ = (&typemappingtestlib.Typemappingtestlib{}).ScanRequest
}

func runCborOnly() {
	runTest("test_obj_as_param", test_obj_as_param)
	runTest("test_opt_seq_present", test_opt_seq_present)
	runTest("test_opt_seq_absent", test_opt_seq_absent)
	runTest("test_bytes_echo_request_roundtrip", test_bytes_echo_request_roundtrip)
	runTest("test_bytes_echo_request_empty", test_bytes_echo_request_empty)
	runTest("test_scan_request_types_emitted", test_scan_request_types_emitted)
}
