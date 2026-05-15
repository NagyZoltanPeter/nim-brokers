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
	runTest("test_scan_request_types_emitted", test_scan_request_types_emitted)
}
