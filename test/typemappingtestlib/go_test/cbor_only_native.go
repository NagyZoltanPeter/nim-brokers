//go:build !cbor

package main

import "typemappingtestlib"

// runCborOnly is a no-op in native mode: ObjParamRequest is gated to
// -d:BrokerFfiApiCBOR in typemappingtestlib.nim because passing a whole
// object as a request parameter is unsupported on every native backend
// (see doc/TYPESUPPORT.md, Section 2).
func runCborOnly() {}

// intResultValue extracts the scalar from a native-mode IntResultRequest,
// which is a struct with a single `Value` field.
func intResultValue(r typemappingtestlib.IntResultRequest) int32 { return r.Value }
