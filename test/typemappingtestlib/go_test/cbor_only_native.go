//go:build !cbor

package main

// runCborOnly is a no-op in native mode: ObjParamRequest is gated to
// -d:BrokerFfiApiCBOR in typemappingtestlib.nim because passing a whole
// object as a request parameter is unsupported on every native backend
// (see doc/TYPESUPPORT.md, Section 2).
func runCborOnly() {}
