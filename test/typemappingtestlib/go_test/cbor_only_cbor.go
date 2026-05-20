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

// ScanRequest round-trip — exercises tuple-as-struct (TupleRow),
// seq[Tuple] (rows), and object-as-input-param (KeyRange). The
// keyword-escape (`range` → `rangeArg`) is implicitly verified by
// the generated method signature.
func test_scan_request_forward() {
	lib := newLib()
	lib.CreateContext()
	kr := typemappingtestlib.KeyRange{StartKey: "lo", StopKey: "hi"}
	r, err := lib.ScanRequest("scan", kr, false)
	check(err == nil, "is_ok")
	checkEq(len(r.Rows), 3, "row count")
	checkEq(r.Rows[0].Key, "0:lo", "row[0].key")
	checkEq(r.Rows[2].Key, "2:lo", "row[2].key")
	checkEq(r.Rows[0].Payload, "scan-row-0:hi", "row[0].payload")
	lib.Close()
}

func test_scan_request_reverse() {
	lib := newLib()
	lib.CreateContext()
	kr := typemappingtestlib.KeyRange{StartKey: "lo", StopKey: "hi"}
	r, err := lib.ScanRequest("scan", kr, true)
	check(err == nil, "is_ok")
	checkEq(len(r.Rows), 3, "row count")
	checkEq(r.Rows[0].Key, "2:lo", "row[0].key")
	checkEq(r.Rows[2].Key, "0:lo", "row[2].key")
	lib.Close()
}

func runCborOnly() {
	runTest("test_obj_as_param", test_obj_as_param)
	runTest("test_bytes_echo_request_roundtrip", test_bytes_echo_request_roundtrip)
	runTest("test_bytes_echo_request_empty", test_bytes_echo_request_empty)
	runTest("test_scan_request_forward", test_scan_request_forward)
	runTest("test_scan_request_reverse", test_scan_request_reverse)
}

// intResultValue extracts the scalar from a CBOR-mode IntResultRequest,
// which is the bare `int32` type alias.
func intResultValue(r typemappingtestlib.IntResultRequest) int32 { return int32(r) }
