// Persistence — Go wrapper example.
//
// Exercises the two-layer interface (IPersistence -> IBackend) with
// per-instance routing and per-subscription event delivery, replicating
// the C++ Scenario B.
//
//     go run .

package main

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"persistence"
)

func waitFor(pred func() bool, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for !pred() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	return pred()
}

func roundtrip(lib *persistence.Persistence, be *persistence.Backend, key, val string) string {
	var mu sync.Mutex
	var resultVal string
	var resultCount int32

	h := be.OnReadCompleted(func(k string, v string, found bool) {
		if k == key && found {
			mu.Lock()
			resultVal = v
			mu.Unlock()
			atomic.AddInt32(&resultCount, 1)
		}
	})
	if h == 0 {
		panic("on_read_completed subscription failed")
	}

	if _, err := be.Store(key, val); err != nil {
		panic(fmt.Sprintf("store failed: %v", err))
	}

	before := atomic.LoadInt32(&resultCount)
	if _, err := be.Read(key); err != nil {
		panic(fmt.Sprintf("read failed: %v", err))
	}

	if !waitFor(func() bool { return atomic.LoadInt32(&resultCount) > before }, 2*time.Second) {
		panic("read event timed out")
	}
	be.OffReadCompleted(h)

	mu.Lock()
	defer mu.Unlock()
	return resultVal
}

const (
	kindMemory = 0
	kindFile   = 1
)

func scenarioTwoContexts() {
	fmt.Println("  [A] two IPersistence contexts (File + Memory)")

	pFile := persistence.New()
	if err := pFile.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
	if _, err := pFile.InitializeRequest("cfg"); err != nil {
		panic(err)
	}
	bf, err := pFile.MakeBackend(kindFile)
	if err != nil {
		panic(fmt.Sprintf("make_backend(FILE): %v", err))
	}
	if !bf.Valid() {
		panic("bf not valid")
	}
	got := roundtrip(pFile, bf, "alpha", "file-payload")
	if got != "file-payload" {
		panic(fmt.Sprintf("expected file-payload, got %s", got))
	}

	pMem := persistence.New()
	if err := pMem.CreateContext(); err != nil {
		panic(err)
	}
	if _, err := pMem.InitializeRequest("cfg"); err != nil {
		panic(err)
	}
	bm, err := pMem.MakeBackend(kindMemory)
	if err != nil {
		panic(fmt.Sprintf("make_backend(MEMORY): %v", err))
	}
	if !bm.Valid() {
		panic("bm not valid")
	}
	got = roundtrip(pMem, bm, "alpha", "memory-payload")
	if got != "memory-payload" {
		panic(fmt.Sprintf("expected memory-payload, got %s", got))
	}

	if (bf.Ctx() & 0xFFFF) == (bm.Ctx() & 0xFFFF) {
		panic("classCtx should differ between independent contexts")
	}

	bm.Close()
	pMem.Close()
	bf.Close()
	pFile.Close()
}

func scenarioMixedOneContext() {
	fmt.Println("  [B] one IPersistence context, File + Memory backends coexisting")

	p := persistence.New()
	if err := p.CreateContext(); err != nil {
		panic(err)
	}
	if _, err := p.InitializeRequest("cfg"); err != nil {
		panic(err)
	}

	var createdCount int32
	ch := p.OnBackendCreated(func(handle uint32, kind int32) {
		atomic.AddInt32(&createdCount, 1)
	})

	bf, err := p.MakeBackend(kindFile)
	if err != nil {
		panic(err)
	}
	bm, err := p.MakeBackend(kindMemory)
	if err != nil {
		panic(err)
	}

	if !waitFor(func() bool { return atomic.LoadInt32(&createdCount) == 2 }, 2*time.Second) {
		panic("BackendCreated events")
	}
	p.OffBackendCreated(ch)

	// Routing invariant: both backends share classCtx, differ in instanceCtx.
	if (bf.Ctx() & 0xFFFF) != (p.Ctx() & 0xFFFF) {
		panic("bf classCtx mismatch")
	}
	if (bm.Ctx() & 0xFFFF) != (p.Ctx() & 0xFFFF) {
		panic("bm classCtx mismatch")
	}
	if (bf.Ctx() >> 16) == (bm.Ctx() >> 16) {
		panic("instanceCtx should differ")
	}
	if bf.Ctx() == bm.Ctx() {
		panic("full ctx should differ")
	}

	// Per-instance request routing + per-subscription event delivery.
	if roundtrip(p, bf, "x", "FILE-X") != "FILE-X" {
		panic("FILE-X roundtrip")
	}
	if roundtrip(p, bm, "x", "MEM-X") != "MEM-X" {
		panic("MEM-X roundtrip")
	}

	// State check: both backends listed and alive.
	st, err := p.ListBackends()
	if err != nil {
		panic(err)
	}
	if len(st.Backends) != 2 {
		panic(fmt.Sprintf("expected 2 backends, got %d", len(st.Backends)))
	}
	for _, it := range st.Backends {
		if !it.Alive {
			panic("expected all backends alive")
		}
	}

	// Targeted teardown: terminate the File backend.
	if _, err := p.TerminateBackend(bf.Ctx()); err != nil {
		panic(err)
	}
	st, err = p.ListBackends()
	if err != nil {
		panic(err)
	}
	fileDead := false
	memAlive := false
	for _, it := range st.Backends {
		if it.Handle == bf.Ctx() {
			fileDead = !it.Alive
		}
		if it.Handle == bm.Ctx() {
			memAlive = it.Alive
		}
	}
	if !fileDead {
		panic("File backend should be terminated")
	}
	if !memAlive {
		panic("Memory backend should still be alive")
	}

	// Terminated backend rejects requests; sibling keeps working.
	if _, err := bf.Store("y", "z"); err == nil {
		panic("terminated backend must reject requests")
	}
	if roundtrip(p, bm, "y", "MEM-Y") != "MEM-Y" {
		panic("MEM-Y roundtrip")
	}

	bf.Close()
	bm.Close()
	p.Close()
}

func scenarioConcurrentLoad() {
	const N = 30
	fmt.Printf("  [C] two IPersistence contexts running concurrently, %d roundtrips each under load\n", N)

	var okFile, okMem int32

	runLib := func(kind int32, tag string, okCount *int32) {
		p := persistence.New()
		if err := p.CreateContext(); err != nil {
			return
		}
		p.InitializeRequest("cfg")
		be, err := p.MakeBackend(kind)
		if err != nil {
			p.Close()
			return
		}

		var mu sync.Mutex
		results := make(map[string]string)

		h := be.OnReadCompleted(func(k string, v string, found bool) {
			mu.Lock()
			results[k] = v
			mu.Unlock()
		})

		local := int32(0)
		for i := 0; i < N; i++ {
			key := fmt.Sprintf("%s_%d", tag, i)
			val := fmt.Sprintf("%s_val_%d", tag, i)
			if _, err := be.Store(key, val); err != nil {
				continue
			}
			if _, err := be.Read(key); err != nil {
				continue
			}
			k := key
			got := waitFor(func() bool {
				mu.Lock()
				_, ok := results[k]
				mu.Unlock()
				return ok
			}, 3*time.Second)
			if got {
				mu.Lock()
				if results[key] == val {
					local++
				}
				mu.Unlock()
			}
		}

		be.OffReadCompleted(h)
		atomic.StoreInt32(okCount, local)

		// No barrier: each context's teardown must be isolated from the
		// sibling context still delivering events.
		be.Close()
		p.Close()
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); runLib(kindFile, "fileLib", &okFile) }()
	go func() { defer wg.Done(); runLib(kindMemory, "memLib", &okMem) }()
	wg.Wait()

	f := atomic.LoadInt32(&okFile)
	m := atomic.LoadInt32(&okMem)
	fmt.Printf("      File lib: %d/%d  Memory lib: %d/%d roundtrips OK\n", f, N, m, N)
	if f != N {
		panic(fmt.Sprintf("File roundtrips: %d/%d", f, N))
	}
	if m != N {
		panic(fmt.Sprintf("Memory roundtrips: %d/%d", m, N))
	}
}

func main() {
	fmt.Printf("persistence version: %s\n", persistence.Version())
	scenarioTwoContexts()
	scenarioMixedOneContext()
	scenarioConcurrentLoad()
	fmt.Println("persistence go example: OK")
}
