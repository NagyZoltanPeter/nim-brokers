package main

// Raw-ABI check of <lib>_verifySchema, which the generated wrapper keeps
// private. Links the same build output the wrapper module links.

/*
#cgo CFLAGS: -I${SRCDIR}/../build
#cgo LDFLAGS: -L${SRCDIR}/../build -ltypemappingtestlib
#cgo darwin LDFLAGS: -Wl,-rpath,${SRCDIR}/../build
#cgo linux LDFLAGS: -Wl,-rpath,${SRCDIR}/../build
#include <stdlib.h>
#include "typemappingtestlib.h"
*/
import "C"

import (
	"os"
	"unsafe"

	"typemappingtestlib"
)

// The wrapper's burned-in fingerprint matches the loaded library; a corrupted
// one is reported (-14) and the per-lib opt-out env turns it into 1.
func test_schema_hash_verify() {
	const env = "TYPEMAPPINGTESTLIB_SKIP_SCHEMA_CHECK"
	h := typemappingtestlib.SchemaHash
	checkEq(len(h), 32, "schema hash length")

	ours := C.CString(h)
	defer C.free(unsafe.Pointer(ours))
	var libHash [33]C.char
	checkEq(int32(C.typemappingtestlib_verifySchema(ours, &libHash[0])), int32(0), "verify match")
	checkEq(C.GoString(&libHash[0]), h, "library hash equals wrapper hash")

	bad := []byte(h)
	if bad[0] == '0' {
		bad[0] = '1'
	} else {
		bad[0] = '0'
	}
	badC := C.CString(string(bad))
	defer C.free(unsafe.Pointer(badC))
	checkEq(int32(C.typemappingtestlib_verifySchema(badC, nil)), int32(-14), "verify mismatch")
	os.Setenv(env, "1")
	checkEq(int32(C.typemappingtestlib_verifySchema(badC, nil)), int32(1), "verify mismatch skipped")
	os.Unsetenv(env)
	checkEq(int32(C.typemappingtestlib_verifySchema(badC, nil)), int32(-14), "verify mismatch after unset")

	// CreateContext ran the same check and succeeded.
	lib := typemappingtestlib.New()
	checkEq(lib.CreateContext(), error(nil), "CreateContext after verify")
	lib.Close()
}
