//go:build cbor

package main

import "typemappingtestlib"

func cborOnlyMatrix(t *typemappingtestlib.Typemappingtestlib) {
	op, err := t.ObjParamRequest(typemappingtestlib.Tag{Key: "k", Value: "v"})
	check(err == nil, "ObjParamRequest is_ok")
	if err == nil {
		check(op.Summary == "k=v", "ObjParamRequest.summary == k=v")
	}
}
