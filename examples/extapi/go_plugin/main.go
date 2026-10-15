// EXTAPI example — the `storage` plugin in Go (implements the generated
// storage_ext.Storage interface). Built with -buildmode=c-shared; the Nim
// host loads it with ExtHost.loadPlugin(path), which calls
// broker_ext_plugin_entry().
//
// Uses only the generated storage_ext module; no Nim, no CBOR by hand.
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	ext "storage_ext"
)

var cancels atomic.Int32

type goStorage struct {
	mu      sync.Mutex
	emitter ext.Emitter
}

// Quick requests: each runs on its own goroutine (the port is NONBLOCKING).
func (s *goStorage) FetchBlob(ctx context.Context, key string) (ext.FetchBlob, error) {
	return ext.FetchBlob{Data: []byte("go:" + key)}, nil
}

func (s *goStorage) StoreBlob(ctx context.Context, key string, data []byte) (ext.StoreBlob, error) {
	return ext.StoreBlob{Etag: fmt.Sprintf("etag-%s-%d", key, len(data))}, nil
}

// Not provided by this plugin (attach never provides it).
func (s *goStorage) ListKeys(ctx context.Context) (ext.ListKeys, error) {
	return ext.ListKeys{}, fmt.Errorf("not provided")
}

// Slow: 2 s unless Nim cancels (explicit cancel or deadline cancels ctx).
func (s *goStorage) Compact(ctx context.Context, level int32) (ext.Compact, error) {
	select {
	case <-time.After(2 * time.Second):
		return ext.Compact{Freed: int64(level) * 1024}, nil
	case <-ctx.Done():
		cancels.Add(1)
		return ext.Compact{}, ctx.Err()
	}
}

// One-way: react by emitting an event from another goroutine.
func (s *goStorage) CompactHint(h ext.CompactHint) {
	s.mu.Lock()
	e := s.emitter
	s.mu.Unlock()
	go e.BlobEvicted(ext.BlobEvicted{Key: fmt.Sprintf("k%d", h.Urgency), Reason: "compact"})
}

var (
	portMu sync.Mutex
	port   *ext.Port
)

func attach(host unsafe.Pointer, ctx uint32) int32 {
	portMu.Lock()
	defer portMu.Unlock()
	impl := &goStorage{}
	p, err := ext.Open(ext.HostFromPtr(host), ctx, impl)
	if err != nil {
		return ext.BadArg
	}
	// Provide individually: list_keys is deliberately left out.
	for _, a := range []ext.Api{ext.ApiFetchBlob, ext.ApiStoreBlob, ext.ApiCompact, ext.ApiCompactHint} {
		if rc := p.Provide(a); rc != ext.OK {
			return rc
		}
	}
	impl.mu.Lock()
	impl.emitter = p.Emitter()
	impl.mu.Unlock()
	port = p
	return ext.OK
}

// broker_ext_plugin_entry is the exe-mode entry point, called by
// ExtHost.loadPlugin(). Opens on DefaultBrokerContext (1).
//
//export broker_ext_plugin_entry
func broker_ext_plugin_entry(host unsafe.Pointer) C.int32_t {
	return C.int32_t(attach(host, 1))
}

// Example-specific controls (scenario 2: detach / re-attach at runtime).
//
//export storage_plugin_attach
func storage_plugin_attach(host unsafe.Pointer, ctx C.uint32_t) C.int32_t {
	return C.int32_t(attach(host, uint32(ctx)))
}

//export storage_plugin_detach
func storage_plugin_detach() C.int32_t {
	portMu.Lock()
	defer portMu.Unlock()
	if port != nil {
		port.Close()
		port = nil
	}
	return C.int32_t(ext.OK)
}

//export storage_plugin_cancels
func storage_plugin_cancels() C.int32_t {
	return C.int32_t(cancels.Load())
}

func main() {}
