// EXTAPI example — scenario 1b in Go: this application hosts the Nim library
// `storagelib` and implements the `notes` plugin that the library consumes,
// in-process, with notes_ext.OpenFuncs (per-name funcs, provides exactly what
// is set). Then it calls the library's own (API) request, whose Nim provider
// calls back into this app through EXTAPI.
//
//	go run .   # after `nimble runExtExampleGo` built nimlib/build/
package main

/*
// storagelib_extHost lives in libstoragelib, which the storagelib module links.
extern const void* storagelib_extHost(void);
static const void* ext_host(void) { return storagelib_extHost(); }
*/
import "C"

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"unsafe"

	"notes_ext"
	"storagelib"
)

var failures int

func expect(cond bool, what string) {
	mark := "ok  "
	if !cond {
		mark = "FAIL"
		failures++
	}
	fmt.Printf("  %s  %s\n", mark, what)
}

func main() {
	fmt.Println("== scenario 1b: lib mode, plugin implemented by the host app (Go)")
	lib := storagelib.New()
	err := lib.CreateContext()
	expect(err == nil, "storagelib CreateContext")
	if err != nil {
		os.Exit(1)
	}

	raw := unsafe.Pointer(C.ext_host())
	expect(raw != nil, "storagelib_extHost()")

	var stored atomic.Int32
	port, err := notes_ext.OpenFuncs(notes_ext.HostFromPtr(raw), lib.Ctx(), notes_ext.Funcs{
		NoteStored: func(ctx context.Context, text string) (notes_ext.NoteStored, error) {
			stored.Add(1)
			return notes_ext.NoteStored{Id: fmt.Sprintf("note-%d", len(text))}, nil
		},
	})
	expect(err == nil, "notes OpenFuncs (provides note_stored)")

	saved, err := lib.SaveNote("hello")
	expect(err == nil, "SaveNote via the library's (API)")
	if err != nil {
		fmt.Println("        error:", err)
	} else {
		expect(saved.Id == "note-5", "id produced by the app's plugin")
		expect(saved.Via == "notes plugin", "Nim provider routed through EXTAPI")
	}
	expect(stored.Load() == 1, "plugin func invoked once")

	if port != nil {
		port.Close()
	}
	_, err = lib.SaveNote("again")
	expect(err != nil, "after close: no provider")

	lib.Close()
	if failures > 0 {
		fmt.Printf("go_host_lib: %d check(s) failed\n", failures)
		os.Exit(1)
	}
	fmt.Println("go_host_lib: all checks passed")
}
