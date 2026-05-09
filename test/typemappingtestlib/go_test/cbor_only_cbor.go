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

func runCborOnly() {
	runTest("test_obj_as_param", test_obj_as_param)
}
