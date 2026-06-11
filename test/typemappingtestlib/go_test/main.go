// Go port of test_typemappingtestlib.cpp — covers every Nim→C→Go type
// mapping through the generated Go wrapper (typemappingtestlib package).
//
//     go run .   # links against build/ (FFI build)

package main

import (
	"fmt"
	"math"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"typemappingtestlib"
)

// ============================================================================
// Minimal test framework — mirrors the cpp runner.
// ============================================================================

var (
	gTotal         int
	gFailed        int
	gCurrentFailed bool
	gCurrentName   string
)

func check(cond bool, expr string) {
	if !cond {
		fmt.Fprintf(os.Stderr, "  FAIL: %s\n", expr)
		gCurrentFailed = true
	}
}

func checkEq(a, b interface{}, label string) {
	if !reflectEq(a, b) {
		fmt.Fprintf(os.Stderr, "  FAIL: %s (%v != %v)\n", label, a, b)
		gCurrentFailed = true
	}
}

func checkNe(a, b interface{}, label string) {
	if reflectEq(a, b) {
		fmt.Fprintf(os.Stderr, "  FAIL: %s (%v == %v)\n", label, a, b)
		gCurrentFailed = true
	}
}

func checkNear(a, b, eps float64, label string) {
	if math.Abs(a-b) > eps {
		fmt.Fprintf(os.Stderr, "  FAIL: |%s| > %g (%v vs %v)\n", label, eps, a, b)
		gCurrentFailed = true
	}
}

func reflectEq(a, b interface{}) bool {
	return fmt.Sprintf("%v", a) == fmt.Sprintf("%v", b)
}

func runTest(name string, fn func()) {
	gCurrentFailed = false
	gCurrentName = name
	gTotal++
	fmt.Printf("  %-60s", name)
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "  PANIC: %v\n", r)
			gCurrentFailed = true
		}
		if gCurrentFailed {
			fmt.Println("FAIL")
			gFailed++
		} else {
			fmt.Println("ok")
		}
	}()
	fn()
}

// ============================================================================
// Helpers
// ============================================================================

// safeList[T] — thread-safe append-only list for event collection.
type safeList[T any] struct {
	mu    sync.Mutex
	items []T
}

func (s *safeList[T]) push(v T) {
	s.mu.Lock()
	s.items = append(s.items, v)
	s.mu.Unlock()
}

func (s *safeList[T]) size() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.items)
}

func (s *safeList[T]) at(i int) T {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.items[i]
}

func (s *safeList[T]) snapshot() []T {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := make([]T, len(s.items))
	copy(cp, s.items)
	return cp
}

// waitFor busy-waits up to timeoutSec for pred() to return true.
func waitFor(pred func() bool, timeoutSec ...float64) bool {
	t := 2.0
	if len(timeoutSec) > 0 {
		t = timeoutSec[0]
	}
	deadline := time.Now().Add(time.Duration(float64(time.Second) * t))
	for !pred() && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	return pred()
}

func sleepMs(ms int) {
	time.Sleep(time.Duration(ms) * time.Millisecond)
}

func newLib() *typemappingtestlib.Typemappingtestlib {
	return typemappingtestlib.New()
}

// ============================================================================
// TestLifecycle
// ============================================================================

func test_lifecycle_create_and_shutdown() {
	lib := newLib()
	check(!lib.ValidContext(), "!validContext")
	err := lib.CreateContext()
	check(err == nil, "createContext is_ok")
	check(lib.ValidContext(), "validContext")
	checkNe(lib.Ctx(), uint32(0), "ctx != 0")
	lib.Close()
	check(!lib.ValidContext(), "!validContext after shutdown")
}

func test_lifecycle_raii_shutdown() {
	var savedCtx uint32
	func() {
		lib := newLib()
		lib.CreateContext()
		savedCtx = lib.Ctx()
		checkNe(savedCtx, uint32(0), "ctx != 0")
		lib.Close() // simulate destructor
	}()
	checkNe(savedCtx, uint32(0), "ctx survived")
}

func test_lifecycle_double_shutdown_is_safe() {
	lib := newLib()
	lib.CreateContext()
	lib.Close()
	lib.Close() // must not panic
}

func test_lifecycle_double_create_returns_error() {
	lib := newLib()
	r1 := lib.CreateContext()
	check(r1 == nil, "createContext1 is_ok")
	r2 := lib.CreateContext()
	check(r2 != nil, "createContext2 fails")
	lib.Close()
}

func test_lifecycle_request_without_context_fails() {
	lib := newLib()
	_, err := lib.EchoRequest("hello")
	check(err != nil, "echoRequest without ctx fails")
}

// ============================================================================
// TestRequests
// ============================================================================

func test_requests_initialize() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.InitializeRequest("test-label")
	check(err == nil, "initializeRequest is_ok")
	checkEq(r.Label, "test-label", "label")
	lib.Close()
}

func test_requests_echo() {
	lib := newLib()
	lib.CreateContext()
	lib.InitializeRequest("ctx-A")
	r, err := lib.EchoRequest("hello")
	check(err == nil, "echoRequest is_ok")
	checkEq(r.Reply, "ctx-A:hello", "reply")
	lib.Close()
}

func test_requests_counter_increments() {
	lib := newLib()
	lib.CreateContext()
	for expected := int32(1); expected <= 3; expected++ {
		r, err := lib.CounterRequest()
		check(err == nil, "counterRequest is_ok")
		checkEq(r.Value, expected, "value")
	}
	lib.Close()
}

func test_requests_multiple_echo() {
	lib := newLib()
	lib.CreateContext()
	lib.InitializeRequest("multi")
	for i := 0; i < 5; i++ {
		msg := fmt.Sprintf("msg-%d", i)
		r, err := lib.EchoRequest(msg)
		check(err == nil, "echoRequest is_ok")
		checkEq(r.Reply, "multi:"+msg, "reply")
	}
	lib.Close()
}

func test_dual_sig_zero() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.DualSigRequestZero()
	check(err == nil, "dualSigRequestZero is_ok")
	checkEq(r.Label, "zero", "label")
	checkEq(r.Counter, int32(0), "counter")
	lib.Close()
}

func test_dual_sig_with_label() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.DualSigRequestWithLabel("hello", int32(7))
	check(err == nil, "dualSigRequestWithLabel is_ok")
	checkEq(r.Label, "hello", "label")
	checkEq(r.Counter, int32(7), "counter")
	lib.Close()
}

// ============================================================================
// TestPrimitiveBrokerTypes — non-object (primitive) request result + event
// payload. IntResultRequest is `type X = int32`; SimpleIntEvent is
// `type X = int64`. Native mode exposes the result as a struct with a single
// `Value` field; CBOR mode exposes it as the bare `int32` type alias. The
// build-tagged `intResultValue` helper bridges the two shapes.
// ============================================================================

func test_primitive_int_result_request() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.IntResultRequest(21)
	check(err == nil, "intResultRequest is_ok")
	checkEq(intResultValue(r), int32(42), "value") // provider returns value*2
	lib.Close()
}

func test_primitive_simple_int_event() {
	lib := newLib()
	lib.CreateContext()

	received := &safeList[int64]{}
	h := lib.OnSimpleIntEvent(func(value int64) { received.push(value) })
	checkNe(h, uint64(0), "handle != 0")

	lib.IntResultRequest(5) // provider emits SimpleIntEvent(value*10)
	waitFor(func() bool { return received.size() >= 1 })

	checkEq(received.size(), 1, "received.size")
	checkEq(received.snapshot()[0], int64(50), "value*10")

	lib.OffSimpleIntEvent(h)
	lib.Close()
}

// ============================================================================
// TestVoidBrokerTypes — payload-less request + event. VoidActionRequest is
// `type X = void`; VoidPing is a `void` event. The request returns only an
// error (nil = ok); the event handler takes no payload argument.
// ============================================================================

func test_void_action_request() {
	lib := newLib()
	lib.CreateContext()

	_, okErr := lib.VoidActionRequest("go")
	check(okErr == nil, "voidActionRequest ok")

	_, badErr := lib.VoidActionRequest("") // provider rejects empty label
	check(badErr != nil, "voidActionRequest err on empty label")

	lib.Close()
}

func test_void_ping_event() {
	lib := newLib()
	lib.CreateContext()

	received := &safeList[int]{}
	h := lib.OnVoidPing(func() { received.push(1) })
	checkNe(h, uint64(0), "handle != 0")

	lib.VoidActionRequest("trigger") // provider emits VoidPing
	waitFor(func() bool { return received.size() >= 1 })

	checkEq(received.size(), 1, "received.size")

	lib.OffVoidPing(h)
	lib.Close()
}

// ============================================================================
// TestEvents
// ============================================================================

func test_events_counter_changed() {
	lib := newLib()
	lib.CreateContext()

	type entry struct {
		ctx uint32
		v   int32
	}
	received := &safeList[entry]{}
	h := lib.OnCounterChanged(func(v int32) {
		received.push(entry{lib.Ctx(), v})
	})
	checkNe(h, uint64(0), "handle != 0")

	lib.CounterRequest()
	lib.CounterRequest()
	lib.CounterRequest()
	waitFor(func() bool { return received.size() >= 3 })

	checkEq(received.size(), 3, "received.size")
	snap := received.snapshot()
	for i, e := range snap {
		checkEq(e.v, int32(i+1), fmt.Sprintf("snap[%d].v", i))
		checkEq(e.ctx, lib.Ctx(), "ctx")
	}

	lib.OffCounterChanged(h)
	lib.Close()
}

func test_events_off_stops_delivery() {
	lib := newLib()
	lib.CreateContext()

	received := &safeList[int32]{}
	h := lib.OnCounterChanged(func(v int32) { received.push(v) })

	lib.CounterRequest()
	waitFor(func() bool { return received.size() >= 1 })

	lib.OffCounterChanged(h)
	countAfterOff := received.size()

	lib.CounterRequest()
	sleepMs(300)
	checkEq(received.size(), countAfterOff, "no new events after off")

	lib.Close()
}

// ============================================================================
// TestContextSeparation
// ============================================================================

func test_context_independent_counters() {
	lib1 := newLib()
	lib2 := newLib()
	lib1.CreateContext()
	lib2.CreateContext()
	checkNe(lib1.Ctx(), lib2.Ctx(), "ctx1 != ctx2")

	lib1.InitializeRequest("alpha")
	lib2.InitializeRequest("beta")

	for i := int32(1); i <= 3; i++ {
		r, _ := lib1.CounterRequest()
		checkEq(r.Value, i, "lib1.counter")
	}
	for i := int32(1); i <= 2; i++ {
		r, _ := lib2.CounterRequest()
		checkEq(r.Value, i, "lib2.counter")
	}
	r, _ := lib1.CounterRequest()
	checkEq(r.Value, int32(4), "lib1.counter==4")

	lib1.Close()
	lib2.Close()
	sleepMs(50)
}

func test_context_independent_echo() {
	lib1 := newLib()
	lib2 := newLib()
	lib1.CreateContext()
	lib2.CreateContext()

	lib1.InitializeRequest("one")
	lib2.InitializeRequest("two")

	r1, _ := lib1.EchoRequest("x")
	r2, _ := lib2.EchoRequest("x")
	checkEq(r1.Reply, "one:x", "lib1.echo")
	checkEq(r2.Reply, "two:x", "lib2.echo")

	lib1.Close()
	lib2.Close()
	sleepMs(50)
}

func test_context_independent_events() {
	events1 := &safeList[int32]{}
	events2 := &safeList[int32]{}
	lib1 := newLib()
	lib2 := newLib()
	lib1.CreateContext()
	lib2.CreateContext()

	h1 := lib1.OnCounterChanged(func(v int32) { events1.push(v) })
	h2 := lib2.OnCounterChanged(func(v int32) { events2.push(v) })

	lib1.CounterRequest()
	lib1.CounterRequest()
	lib2.CounterRequest()

	waitFor(func() bool { return events1.size() >= 2 && events2.size() >= 1 })

	s1 := events1.snapshot()
	s2 := events2.snapshot()
	checkEq(len(s1), 2, "events1.size")
	checkEq(len(s2), 1, "events2.size")
	checkEq(s1[0], int32(1), "s1[0]")
	checkEq(s1[1], int32(2), "s1[1]")
	checkEq(s2[0], int32(1), "s2[0]")

	lib1.OffCounterChanged(h1)
	lib2.OffCounterChanged(h2)
	lib1.Close()
	lib2.Close()
	sleepMs(50)
}

func test_context_shutdown_one_does_not_affect_other() {
	lib1 := newLib()
	lib2 := newLib()
	lib1.CreateContext()
	lib2.CreateContext()

	lib1.InitializeRequest("first")
	lib2.InitializeRequest("second")

	lib1.Close()

	r, err := lib2.EchoRequest("still-alive")
	check(err == nil, "lib2.echo is_ok")
	checkEq(r.Reply, "second:still-alive", "lib2.reply")

	lib2.Close()
	sleepMs(50)
}

// ============================================================================
// TestScalarTypes
// ============================================================================

func test_scalar_bool_true() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimScalarRequest(true, 0, 0, 0.0)
	check(err == nil, "is_ok")
	check(r.Flag == true, "flag == true")
	lib.Close()
}

func test_scalar_bool_false() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimScalarRequest(false, 0, 0, 0.0)
	check(err == nil, "is_ok")
	check(r.Flag == false, "flag == false")
	lib.Close()
}

func test_scalar_int32_roundtrip() {
	lib := newLib()
	lib.CreateContext()

	r1, err := lib.PrimScalarRequest(false, math.MinInt32, 0, 0.0)
	check(err == nil, "is_ok min")
	checkEq(r1.I32, int32(math.MinInt32), "min")

	r2, err := lib.PrimScalarRequest(false, math.MaxInt32, 0, 0.0)
	check(err == nil, "is_ok max")
	checkEq(r2.I32, int32(math.MaxInt32), "max")

	lib.Close()
}

func test_scalar_int64_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	big := int64(9_000_000_000_000)
	r, err := lib.PrimScalarRequest(false, 0, big, 0.0)
	check(err == nil, "is_ok")
	checkEq(r.I64, big, "i64")
	lib.Close()
}

func test_scalar_float64_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	pi := 3.141592653589793
	r, err := lib.PrimScalarRequest(false, 0, 0, pi)
	check(err == nil, "is_ok")
	checkNear(r.F64, pi, 1e-12, "f64==pi")
	lib.Close()
}

func test_scalar_all_fields_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimScalarRequest(true, 42, 1_000_000_000, 2.718)
	check(err == nil, "is_ok")
	check(r.Flag, "flag")
	checkEq(r.I32, int32(42), "i32")
	checkEq(r.I64, int64(1_000_000_000), "i64")
	checkNear(r.F64, 2.718, 1e-12, "f64")
	lib.Close()
}

func test_scalar_prim_scalar_event() {
	lib := newLib()
	lib.CreateContext()

	type evt struct {
		flag bool
		i32  int32
		i64  int64
		f64  float64
	}
	evts := &safeList[evt]{}
	h := lib.OnPrimScalarEvent(func(flag bool, i32 int32, i64 int64, f64 float64) {
		evts.push(evt{flag, i32, i64, f64})
	})

	lib.PrimScalarRequest(true, 7, 777777, 1.5)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "evts.size")
	e := evts.at(0)
	check(e.flag, "flag")
	checkEq(e.i32, int32(7), "i32")
	checkEq(e.i64, int64(777777), "i64")
	checkNear(e.f64, 1.5, 1e-12, "f64")

	lib.OffPrimScalarEvent(h)
	lib.Close()
}

func test_scalar_prim_scalar_event_false_flag() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[bool]{}
	h := lib.OnPrimScalarEvent(func(flag bool, _ int32, _ int64, _ float64) {
		evts.push(flag)
	})

	lib.PrimScalarRequest(false, 0, 0, 0.0)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	check(evts.at(0) == false, "flag false")

	lib.OffPrimScalarEvent(h)
	lib.Close()
}

// ============================================================================
// TestEnumDistinctTypes
// ============================================================================

func test_enum_roundtrip_low() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pLow, 10)
	check(err == nil, "is_ok")
	checkEq(r.Priority, typemappingtestlib.Priority_pLow, "priority")
	checkEq(int(r.Priority), 0, "priority==0")
	lib.Close()
}

func test_enum_roundtrip_high() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pHigh, 1)
	check(err == nil, "is_ok")
	checkEq(r.Priority, typemappingtestlib.Priority_pHigh, "priority")
	checkEq(int(r.Priority), 2, "priority==2")
	lib.Close()
}

func test_enum_roundtrip_critical() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pCritical, 1)
	check(err == nil, "is_ok")
	checkEq(int(r.Priority), 3, "priority==3")
	lib.Close()
}

func test_distinct_jobid_echoed() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pLow, 5)
	check(err == nil, "is_ok")
	checkEq(int32(r.JobId), int32(5), "jobId")
	lib.Close()
}

func test_distinct_jobid_next() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pLow, 5)
	check(err == nil, "is_ok")
	checkEq(int32(r.NextId), int32(6), "nextId")
	lib.Close()
}

func test_distinct_jobid_zero() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pMedium, 0)
	check(err == nil, "is_ok")
	checkEq(int32(r.JobId), int32(0), "jobId")
	checkEq(int32(r.NextId), int32(1), "nextId")
	lib.Close()
}

func test_all_priority_values() {
	lib := newLib()
	lib.CreateContext()
	priorities := []typemappingtestlib.Priority{
		typemappingtestlib.Priority_pLow,
		typemappingtestlib.Priority_pMedium,
		typemappingtestlib.Priority_pHigh,
		typemappingtestlib.Priority_pCritical,
	}
	for _, p := range priorities {
		r, err := lib.TypedScalarRequest(p, 1)
		check(err == nil, "is_ok")
		checkEq(r.Priority, p, "priority echo")
	}
	lib.Close()
}

func test_typed_scalar_event_enum() {
	lib := newLib()
	lib.CreateContext()

	type evt struct {
		p   typemappingtestlib.Priority
		jid int32
		ts  int64
	}
	evts := &safeList[evt]{}
	h := lib.OnTypedScalarEvent(func(p typemappingtestlib.Priority, jid int32, ts int64) {
		evts.push(evt{p, jid, ts})
	})

	lib.TypedScalarRequest(typemappingtestlib.Priority_pHigh, 7)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	e := evts.at(0)
	checkEq(e.p, typemappingtestlib.Priority_pHigh, "priority")
	checkEq(int(e.p), 2, "priority==2")
	checkEq(e.jid, int32(7), "jobId")
	checkEq(e.ts, int64(70), "ts")

	lib.OffTypedScalarEvent(h)
	lib.Close()
}

func test_typed_scalar_event_distinct_timestamp() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[int64]{}
	h := lib.OnTypedScalarEvent(func(_ typemappingtestlib.Priority, _ int32, ts int64) {
		evts.push(ts)
	})

	lib.TypedScalarRequest(typemappingtestlib.Priority_pLow, 3)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	checkEq(evts.at(0), int64(30), "ts==30")

	lib.OffTypedScalarEvent(h)
	lib.Close()
}

func test_fixedarray_result_contains_timestamp() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedArrayRequest(99)
	check(err == nil, "is_ok")
	checkEq(int64(r.Ts), int64(99), "ts")
	lib.Close()
}

// ============================================================================
// TestSeqByteResult
// ============================================================================

func test_seq_byte_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ByteSeqRequest(0)
	check(err == nil, "is_ok")
	check(len(r.Data) == 0, "empty")
	lib.Close()
}

func test_seq_byte_length() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ByteSeqRequest(8)
	check(err == nil, "is_ok")
	checkEq(len(r.Data), 8, "size")
	lib.Close()
}

func test_seq_byte_values() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ByteSeqRequest(5)
	check(err == nil, "is_ok")
	checkEq(len(r.Data), 5, "size")
	for i, v := range r.Data {
		checkEq(v, byte(i), fmt.Sprintf("data[%d]", i))
	}
	lib.Close()
}

func test_seq_byte_wrap_around() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ByteSeqRequest(260)
	check(err == nil, "is_ok")
	checkEq(len(r.Data), 260, "size")
	checkEq(r.Data[0], byte(0), "data[0]")
	checkEq(r.Data[255], byte(255), "data[255]")
	checkEq(r.Data[256], byte(0), "wrap")
	lib.Close()
}

func test_seq_byte_single_element() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ByteSeqRequest(1)
	check(err == nil, "is_ok")
	checkEq(len(r.Data), 1, "size")
	checkEq(r.Data[0], byte(0), "data[0]")
	lib.Close()
}

func test_seq_byte_large() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ByteSeqRequest(100)
	check(err == nil, "is_ok")
	checkEq(len(r.Data), 100, "size")
	for i, v := range r.Data {
		checkEq(v, byte(i%256), fmt.Sprintf("data[%d]", i))
	}
	lib.Close()
}

// ============================================================================
// TestSeqStringTypes
// ============================================================================

func test_seq_string_result_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.StringSeqRequest("x", 0)
	check(err == nil, "is_ok")
	check(len(r.Items) == 0, "empty")
	lib.Close()
}

func test_seq_string_result_count() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.StringSeqRequest("item", 4)
	check(err == nil, "is_ok")
	checkEq(len(r.Items), 4, "count")
	lib.Close()
}

func test_seq_string_result_values() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.StringSeqRequest("tag", 3)
	check(err == nil, "is_ok")
	checkEq(len(r.Items), 3, "count")
	checkEq(r.Items[0], "tag-0", "items[0]")
	checkEq(r.Items[1], "tag-1", "items[1]")
	checkEq(r.Items[2], "tag-2", "items[2]")
	lib.Close()
}

func test_seq_string_result_special_chars() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.StringSeqRequest("a/b:c", 2)
	check(err == nil, "is_ok")
	checkEq(len(r.Items), 2, "count")
	checkEq(r.Items[0], "a/b:c-0", "items[0]")
	checkEq(r.Items[1], "a/b:c-1", "items[1]")
	lib.Close()
}

func test_seq_string_param_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.SeqStringParamRequest([]string{})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(0), "count")
	checkEq(r.Joined, "", "joined")
	lib.Close()
}

func test_seq_string_param_single() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.SeqStringParamRequest([]string{"hello"})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(1), "count")
	checkEq(r.Joined, "hello", "joined")
	lib.Close()
}

func test_seq_string_param_multiple() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.SeqStringParamRequest([]string{"alpha", "beta", "gamma"})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(3), "count")
	checkEq(r.Joined, "alpha,beta,gamma", "joined")
	lib.Close()
}

func test_seq_string_param_unicode() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.SeqStringParamRequest([]string{"héllo", "wörld"})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(2), "count")
	checkEq(r.Joined, "héllo,wörld", "joined")
	lib.Close()
}

func test_string_seq_event() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]string]{}
	h := lib.OnStringSeqEvent(func(items []string) {
		cp := make([]string, len(items))
		copy(cp, items)
		evts.push(cp)
	})

	lib.StringSeqRequest("ev", 3)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	snap := evts.at(0)
	checkEq(len(snap), 3, "snap.size")
	checkEq(snap[0], "ev-0", "snap[0]")
	checkEq(snap[1], "ev-1", "snap[1]")
	checkEq(snap[2], "ev-2", "snap[2]")

	lib.OffStringSeqEvent(h)
	lib.Close()
}

func test_string_seq_event_empty() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]string]{}
	h := lib.OnStringSeqEvent(func(items []string) {
		cp := make([]string, len(items))
		copy(cp, items)
		evts.push(cp)
	})

	lib.StringSeqRequest("x", 0)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	check(len(evts.at(0)) == 0, "empty")

	lib.OffStringSeqEvent(h)
	lib.Close()
}

// ============================================================================
// TestSeqPrimTypes
// ============================================================================

func test_prim_seq_result_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqRequest(0)
	check(err == nil, "is_ok")
	check(len(r.Values) == 0, "empty")
	lib.Close()
}

func test_prim_seq_result_length() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqRequest(5)
	check(err == nil, "is_ok")
	checkEq(len(r.Values), 5, "size")
	lib.Close()
}

func test_prim_seq_result_values() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqRequest(4)
	check(err == nil, "is_ok")
	checkEq(len(r.Values), 4, "size")
	for i, v := range r.Values {
		checkEq(v, int64(i)*10, fmt.Sprintf("values[%d]", i))
	}
	lib.Close()
}

func test_prim_seq_result_large_int64() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqRequest(3)
	check(err == nil, "is_ok")
	checkEq(r.Values[2], int64(20), "values[2]")
	lib.Close()
}

func test_prim_seq_param_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqParamRequest([]int64{})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(0), "count")
	checkEq(r.Total, int64(0), "total")
	lib.Close()
}

func test_prim_seq_param_single() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqParamRequest([]int64{42})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(1), "count")
	checkEq(r.Total, int64(42), "total")
	lib.Close()
}

func test_prim_seq_param_sum() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.PrimSeqParamRequest([]int64{1, 2, 3, 4, 5})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(5), "count")
	checkEq(r.Total, int64(15), "total")
	lib.Close()
}

func test_prim_seq_param_large_values() {
	lib := newLib()
	lib.CreateContext()
	big := int64(1_000_000_000_000)
	r, err := lib.PrimSeqParamRequest([]int64{big, big})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(2), "count")
	checkEq(r.Total, 2*big, "total")
	lib.Close()
}

func test_prim_seq_event() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int64]{}
	h := lib.OnPrimSeqEvent(func(values []int64) {
		cp := make([]int64, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.PrimSeqRequest(3)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	snap := evts.at(0)
	checkEq(len(snap), 3, "size")
	checkEq(snap[0], int64(0), "snap[0]")
	checkEq(snap[1], int64(10), "snap[1]")
	checkEq(snap[2], int64(20), "snap[2]")

	lib.OffPrimSeqEvent(h)
	lib.Close()
}

func test_prim_seq_event_empty() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int64]{}
	h := lib.OnPrimSeqEvent(func(values []int64) {
		cp := make([]int64, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.PrimSeqRequest(0)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	check(len(evts.at(0)) == 0, "empty")

	lib.OffPrimSeqEvent(h)
	lib.Close()
}

// ============================================================================
// TestFixedArrayTypes
// ============================================================================

func test_array_result_values() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedArrayRequest(5)
	check(err == nil, "is_ok")
	checkEq(r.Values[0], int32(5), "v0")
	checkEq(r.Values[1], int32(10), "v1")
	checkEq(r.Values[2], int32(15), "v2")
	checkEq(r.Values[3], int32(20), "v3")
	lib.Close()
}

func test_array_result_length() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedArrayRequest(1)
	check(err == nil, "is_ok")
	checkEq(len(r.Values), 4, "size")
	lib.Close()
}

func test_array_result_seed_zero() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedArrayRequest(0)
	check(err == nil, "is_ok")
	for _, v := range r.Values {
		checkEq(v, int32(0), "v==0")
	}
	lib.Close()
}

func test_array_result_negative_seed() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedArrayRequest(-3)
	check(err == nil, "is_ok")
	checkEq(r.Values[0], int32(-3), "v0")
	checkEq(r.Values[1], int32(-6), "v1")
	checkEq(r.Values[2], int32(-9), "v2")
	checkEq(r.Values[3], int32(-12), "v3")
	lib.Close()
}

func test_array_result_timestamp() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedArrayRequest(42)
	check(err == nil, "is_ok")
	checkEq(int64(r.Ts), int64(42), "ts")
	lib.Close()
}

func test_fixed_array_event() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnFixedArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.FixedArrayRequest(3)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	snap := evts.at(0)
	checkEq(len(snap), 4, "size")
	checkEq(snap[0], int32(3), "[0]")
	checkEq(snap[1], int32(6), "[1]")
	checkEq(snap[2], int32(9), "[2]")
	checkEq(snap[3], int32(12), "[3]")

	lib.OffFixedArrayEvent(h)
	lib.Close()
}

func test_fixed_array_event_zero_seed() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnFixedArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.FixedArrayRequest(0)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	for _, v := range evts.at(0) {
		checkEq(v, int32(0), "v==0")
	}

	lib.OffFixedArrayEvent(h)
	lib.Close()
}

func test_fixed_array_multiple_requests() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnFixedArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.FixedArrayRequest(1)
	lib.FixedArrayRequest(2)
	waitFor(func() bool { return evts.size() >= 2 })

	checkEq(evts.size(), 2, "size")
	e0 := evts.at(0)
	e1 := evts.at(1)
	checkEq(len(e0), 4, "e0.size")
	checkEq(len(e1), 4, "e1.size")
	checkEq(e0[0], int32(1), "e0[0]")
	checkEq(e0[3], int32(4), "e0[3]")
	checkEq(e1[0], int32(2), "e1[0]")
	checkEq(e1[3], int32(8), "e1[3]")

	lib.OffFixedArrayEvent(h)
	lib.Close()
}

// ============================================================================
// TestConstArraySize
// ============================================================================

const kConstArrayLen = 6

func test_const_array_result_length() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ConstArrayRequest(1)
	check(err == nil, "is_ok")
	checkEq(len(r.Values), kConstArrayLen, "size")
	lib.Close()
}

func test_const_array_result_values() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ConstArrayRequest(3)
	check(err == nil, "is_ok")
	checkEq(len(r.Values), kConstArrayLen, "size")
	expected := []int32{3, 6, 9, 12, 15, 18}
	for i, e := range expected {
		checkEq(r.Values[i], e, fmt.Sprintf("v[%d]", i))
	}
	lib.Close()
}

func test_const_array_result_zero_seed() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ConstArrayRequest(0)
	check(err == nil, "is_ok")
	for _, v := range r.Values {
		checkEq(v, int32(0), "v==0")
	}
	lib.Close()
}

func test_const_array_result_negative_seed() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ConstArrayRequest(-2)
	check(err == nil, "is_ok")
	expected := []int32{-2, -4, -6, -8, -10, -12}
	for i, e := range expected {
		checkEq(r.Values[i], e, fmt.Sprintf("v[%d]", i))
	}
	lib.Close()
}

func test_const_array_event_values() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnConstArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.ConstArrayRequest(2)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	snap := evts.at(0)
	checkEq(len(snap), kConstArrayLen, "size")
	expected := []int32{2, 4, 6, 8, 10, 12}
	for i, e := range expected {
		checkEq(snap[i], e, fmt.Sprintf("v[%d]", i))
	}

	lib.OffConstArrayEvent(h)
	lib.Close()
}

func test_const_array_event_length() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnConstArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.ConstArrayRequest(1)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(len(evts.at(0)), kConstArrayLen, "size")

	lib.OffConstArrayEvent(h)
	lib.Close()
}

func test_const_array_event_neg_seed() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnConstArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.ConstArrayRequest(-2)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	snap := evts.at(0)
	expected := []int32{-2, -4, -6, -8, -10, -12}
	checkEq(len(snap), len(expected), "size")
	for i, e := range expected {
		if i < len(snap) {
			checkEq(snap[i], e, fmt.Sprintf("v[%d]", i))
		}
	}

	lib.OffConstArrayEvent(h)
	lib.Close()
}

func test_distinct_jobid_max_minus_one() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.TypedScalarRequest(typemappingtestlib.Priority_pLow, math.MaxInt32-1)
	check(err == nil, "is_ok")
	checkEq(int32(r.JobId), int32(math.MaxInt32-1), "jobId")
	checkEq(int32(r.NextId), int32(math.MaxInt32), "nextId")
	lib.Close()
}

func test_const_array_event_zero_seed() {
	lib := newLib()
	lib.CreateContext()

	evts := &safeList[[]int32]{}
	h := lib.OnConstArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		evts.push(cp)
	})

	lib.ConstArrayRequest(0)
	waitFor(func() bool { return evts.size() >= 1 })

	checkEq(evts.size(), 1, "size")
	for _, v := range evts.at(0) {
		checkEq(v, int32(0), "v==0")
	}

	lib.OffConstArrayEvent(h)
	lib.Close()
}

// ============================================================================
// TestSeqObjectTypes
// ============================================================================

func test_obj_seq_param_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjSeqParamRequest([]typemappingtestlib.Tag{})
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(0), "count")
	checkEq(r.First, "", "first")
	lib.Close()
}

func makeTag(k, v string) typemappingtestlib.Tag {
	return typemappingtestlib.Tag{Key: k, Value: v}
}

func test_obj_seq_param_single() {
	lib := newLib()
	lib.CreateContext()
	tags := []typemappingtestlib.Tag{makeTag("mykey", "myval")}
	r, err := lib.ObjSeqParamRequest(tags)
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(1), "count")
	checkEq(r.First, "mykey", "first")
	lib.Close()
}

func test_obj_seq_param_multiple() {
	lib := newLib()
	lib.CreateContext()
	tags := []typemappingtestlib.Tag{
		makeTag("first", "1"),
		makeTag("second", "2"),
		makeTag("third", "3"),
	}
	r, err := lib.ObjSeqParamRequest(tags)
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(3), "count")
	checkEq(r.First, "first", "first")
	lib.Close()
}

func test_obj_seq_param_string_encoding() {
	lib := newLib()
	lib.CreateContext()
	tags := []typemappingtestlib.Tag{makeTag("key with spaces", "value/path")}
	r, err := lib.ObjSeqParamRequest(tags)
	check(err == nil, "is_ok")
	checkEq(r.Count, int32(1), "count")
	checkEq(r.First, "key with spaces", "first")
	lib.Close()
}

// test_obj_as_param: lives in extras.go.

// Native + CBOR Option[int32] probe (Phase E1).
func test_opt_scalar_present() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptScalarRequest(true)
	check(err == nil, "is_ok")
	check(r.Value != nil, "value present")
	if r.Value != nil {
		checkEq(*r.Value, int32(42), "value")
	}
	lib.Close()
}

func test_opt_scalar_absent() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptScalarRequest(false)
	check(err == nil, "is_ok")
	check(r.Value == nil, "value absent")
	lib.Close()
}

// Phase E2a — Option[string]. Native + CBOR.
func test_opt_string_present() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptStringRequest(true)
	check(err == nil, "is_ok")
	check(r.Value != nil, "value present")
	if r.Value != nil {
		checkEq(*r.Value, "hello", "value")
	}
	lib.Close()
}

func test_opt_string_absent() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptStringRequest(false)
	check(err == nil, "is_ok")
	check(r.Value == nil, "value absent")
	lib.Close()
}

// Phase E2b — Option[seq[byte]]. Native + CBOR.
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

// Phase E3 — Option[Tag] (Option of a registered object). Native + CBOR.
func test_opt_obj_present() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptObjRequest(true)
	check(err == nil, "is_ok")
	check(r.Value != nil, "value present")
	if r.Value != nil {
		checkEq(r.Value.Key, "ok", "key")
		checkEq(r.Value.Value, "yes", "value")
	}
	lib.Close()
}

func test_opt_obj_absent() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptObjRequest(false)
	check(err == nil, "is_ok")
	check(r.Value == nil, "value absent")
	lib.Close()
}

func test_obj_seq_result_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjSeqResultRequest(0)
	check(err == nil, "is_ok")
	check(len(r.Tags) == 0, "empty")
	lib.Close()
}

func test_obj_seq_result_length() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjSeqResultRequest(4)
	check(err == nil, "is_ok")
	checkEq(len(r.Tags), 4, "size")
	lib.Close()
}

func test_obj_seq_result_keys() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjSeqResultRequest(3)
	check(err == nil, "is_ok")
	checkEq(len(r.Tags), 3, "size")
	checkEq(r.Tags[0].Key, "key-0", "k0")
	checkEq(r.Tags[1].Key, "key-1", "k1")
	checkEq(r.Tags[2].Key, "key-2", "k2")
	lib.Close()
}

func test_obj_seq_result_values() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjSeqResultRequest(3)
	check(err == nil, "is_ok")
	checkEq(r.Tags[0].Value, "val-0", "v0")
	checkEq(r.Tags[1].Value, "val-1", "v1")
	checkEq(r.Tags[2].Value, "val-2", "v2")
	lib.Close()
}

func test_obj_seq_result_tag_fields() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ObjSeqResultRequest(2)
	check(err == nil, "is_ok")
	for _, tag := range r.Tags {
		check(len(tag.Key) > 0, "key non-empty")
		check(len(tag.Value) > 0, "value non-empty")
	}
	lib.Close()
}

func test_obj_seq_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	gen, err := lib.ObjSeqResultRequest(3)
	check(err == nil, "gen is_ok")
	r, err := lib.ObjSeqParamRequest(gen.Tags)
	check(err == nil, "rt is_ok")
	checkEq(r.Count, int32(3), "count")
	checkEq(r.First, "key-0", "first")
	lib.Close()
}

// ============================================================================
// TestMultipleEventListeners
// ============================================================================

func test_two_scalar_event_listeners() {
	lib := newLib()
	lib.CreateContext()

	evts1 := &safeList[int32]{}
	evts2 := &safeList[int32]{}
	h1 := lib.OnPrimScalarEvent(func(_ bool, i32 int32, _ int64, _ float64) {
		evts1.push(i32)
	})
	h2 := lib.OnPrimScalarEvent(func(_ bool, i32 int32, _ int64, _ float64) {
		evts2.push(i32)
	})

	lib.PrimScalarRequest(false, 99, 0, 0.0)
	waitFor(func() bool { return evts1.size() >= 1 })
	waitFor(func() bool { return evts2.size() >= 1 })

	checkEq(evts1.size(), 1, "evts1.size")
	checkEq(evts2.size(), 1, "evts2.size")
	checkEq(evts1.at(0), int32(99), "e1[0]")
	checkEq(evts2.at(0), int32(99), "e2[0]")

	lib.OffPrimScalarEvent(h1)
	lib.OffPrimScalarEvent(h2)
	lib.Close()
}

func test_remove_one_listener_keeps_other() {
	lib := newLib()
	lib.CreateContext()

	evts1 := &safeList[int32]{}
	evts2 := &safeList[int32]{}
	h1 := lib.OnPrimScalarEvent(func(_ bool, i32 int32, _ int64, _ float64) {
		evts1.push(i32)
	})
	h2 := lib.OnPrimScalarEvent(func(_ bool, i32 int32, _ int64, _ float64) {
		evts2.push(i32)
	})

	lib.PrimScalarRequest(false, 1, 0, 0.0)
	waitFor(func() bool { return evts1.size() >= 1 })
	waitFor(func() bool { return evts2.size() >= 1 })
	checkEq(evts1.size(), 1, "evts1.size")
	checkEq(evts2.size(), 1, "evts2.size")

	lib.OffPrimScalarEvent(h1)

	lib.PrimScalarRequest(false, 2, 0, 0.0)
	waitFor(func() bool { return evts2.size() >= 2 })
	sleepMs(100)

	checkEq(evts1.size(), 1, "evts1 unchanged")
	checkEq(evts2.size(), 2, "evts2.size")
	checkEq(evts2.at(1), int32(2), "evts2[1]")

	lib.OffPrimScalarEvent(h2)
	lib.Close()
}

func test_concurrent_event_types() {
	lib := newLib()
	lib.CreateContext()

	scalarEvts := &safeList[int32]{}
	arrayEvts := &safeList[[]int32]{}
	stringEvts := &safeList[[]string]{}

	hs := lib.OnPrimScalarEvent(func(_ bool, i32 int32, _ int64, _ float64) {
		scalarEvts.push(i32)
	})
	ha := lib.OnFixedArrayEvent(func(values []int32) {
		cp := make([]int32, len(values))
		copy(cp, values)
		arrayEvts.push(cp)
	})
	hst := lib.OnStringSeqEvent(func(items []string) {
		cp := make([]string, len(items))
		copy(cp, items)
		stringEvts.push(cp)
	})

	lib.PrimScalarRequest(false, 55, 0, 0.0)
	lib.FixedArrayRequest(4)
	lib.StringSeqRequest("z", 2)

	waitFor(func() bool { return scalarEvts.size() >= 1 })
	waitFor(func() bool { return arrayEvts.size() >= 1 })
	waitFor(func() bool { return stringEvts.size() >= 1 })

	checkEq(scalarEvts.size(), 1, "scalar size")
	checkEq(scalarEvts.at(0), int32(55), "scalar")

	checkEq(arrayEvts.size(), 1, "arr size")
	arr := arrayEvts.at(0)
	checkEq(len(arr), 4, "arr.size")
	checkEq(arr[0], int32(4), "arr[0]")
	checkEq(arr[3], int32(16), "arr[3]")

	checkEq(stringEvts.size(), 1, "str size")
	strs := stringEvts.at(0)
	checkEq(len(strs), 2, "strs.size")
	checkEq(strs[0], "z-0", "strs[0]")
	checkEq(strs[1], "z-1", "strs[1]")

	lib.OffPrimScalarEvent(hs)
	lib.OffFixedArrayEvent(ha)
	lib.OffStringSeqEvent(hst)
	lib.Close()
}

// ============================================================================
// TestForeignThreadGcSafety
// ============================================================================

// runForeign runs fn on N goroutines pinned to OS threads.
func runForeign(n int, fn func(t int)) {
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(t int) {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			defer wg.Done()
			fn(t)
		}(i)
	}
	wg.Wait()
}

func test_foreign_thread_concurrent_requests() {
	lib := newLib()
	lib.CreateContext()
	lib.InitializeRequest("gc-test")

	const kThreads = 8
	const kIters = 20

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			msg := fmt.Sprintf("thread-%d-msg-%d", t, i)
			r, err := lib.EchoRequest(msg)
			if err != nil {
				atomic.AddInt64(&failures, 1)
				return
			}
			if len(r.Reply) < 8 || r.Reply[:8] != "gc-test:" {
				atomic.AddInt64(&failures, 1)
				return
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

func test_foreign_thread_concurrent_seq_string_requests() {
	lib := newLib()
	lib.CreateContext()
	lib.InitializeRequest("seq-str")

	const kThreads = 6
	const kIters = 10

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			prefix := fmt.Sprintf("t%di%d", t, i)
			n := int32(5 + (t % 3))
			r, err := lib.StringSeqRequest(prefix, n)
			if err != nil {
				atomic.AddInt64(&failures, 1)
				return
			}
			if int32(len(r.Items)) != n {
				atomic.AddInt64(&failures, 1)
				return
			}
			for j := int32(0); j < n; j++ {
				expected := fmt.Sprintf("%s-%d", prefix, j)
				if r.Items[j] != expected {
					atomic.AddInt64(&failures, 1)
					return
				}
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

func test_foreign_thread_concurrent_seq_prim_requests() {
	lib := newLib()
	lib.CreateContext()

	const kThreads = 6
	const kIters = 15

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			n := int32(3 + (t % 4))
			r, err := lib.PrimSeqRequest(n)
			if err != nil {
				atomic.AddInt64(&failures, 1)
				return
			}
			if int32(len(r.Values)) != n {
				atomic.AddInt64(&failures, 1)
				return
			}
			for j, v := range r.Values {
				if v != int64(j)*10 {
					atomic.AddInt64(&failures, 1)
					return
				}
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

func test_foreign_thread_concurrent_seq_object_requests() {
	lib := newLib()
	lib.CreateContext()

	const kThreads = 4
	const kIters = 10

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			n := int32(3 + (t % 5))
			r, err := lib.ObjSeqResultRequest(n)
			if err != nil {
				atomic.AddInt64(&failures, 1)
				return
			}
			if int32(len(r.Tags)) != n {
				atomic.AddInt64(&failures, 1)
				return
			}
			for j := int32(0); j < n; j++ {
				ek := fmt.Sprintf("key-%d", j)
				ev := fmt.Sprintf("val-%d", j)
				if r.Tags[j].Key != ek || r.Tags[j].Value != ev {
					atomic.AddInt64(&failures, 1)
					return
				}
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

func test_foreign_thread_concurrent_seq_object_param_requests() {
	lib := newLib()
	lib.CreateContext()

	const kThreads = 4
	const kIters = 8

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			n := 2 + (t % 3)
			tags := make([]typemappingtestlib.Tag, n)
			for j := 0; j < n; j++ {
				tags[j] = makeTag(
					fmt.Sprintf("thread%d-key%d", t, j),
					fmt.Sprintf("thread%d-val%d", t, j),
				)
			}
			r, err := lib.ObjSeqParamRequest(tags)
			if err != nil {
				atomic.AddInt64(&failures, 1)
				return
			}
			if int(r.Count) != n {
				atomic.AddInt64(&failures, 1)
				return
			}
			expectedFirst := fmt.Sprintf("thread%d-key0", t)
			if r.First != expectedFirst {
				atomic.AddInt64(&failures, 1)
				return
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

func test_foreign_thread_concurrent_lifecycle() {
	const kThreads = 4
	var failures int64

	runForeign(kThreads, func(t int) {
		lib := newLib()
		if err := lib.CreateContext(); err != nil {
			atomic.AddInt64(&failures, 1)
			return
		}
		if _, err := lib.InitializeRequest(fmt.Sprintf("lifecycle-t%d", t)); err != nil {
			atomic.AddInt64(&failures, 1)
			lib.Close()
			return
		}
		r, err := lib.EchoRequest("test")
		if err != nil {
			atomic.AddInt64(&failures, 1)
			lib.Close()
			return
		}
		expected := fmt.Sprintf("lifecycle-t%d:test", t)
		if r.Reply != expected {
			atomic.AddInt64(&failures, 1)
		}
		lib.Close()
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
}

func test_foreign_thread_mixed_request_types() {
	lib := newLib()
	lib.CreateContext()
	lib.InitializeRequest("mixed")

	const kThreads = 6
	const kIters = 10

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			switch i % 5 {
			case 0:
				r, err := lib.EchoRequest(fmt.Sprintf("t%d", t))
				if err != nil || r.Reply == "" {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 1:
				r, err := lib.CounterRequest()
				if err != nil || r.Value <= 0 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 2:
				r, err := lib.PrimScalarRequest(true, 42, 1000, 3.14)
				if err != nil || !r.Flag || r.I32 != 42 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 3:
				r, err := lib.StringSeqRequest("x", 3)
				if err != nil || len(r.Items) != 3 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 4:
				r, err := lib.FixedArrayRequest(7)
				if err != nil || r.Values[0] != 7 {
					atomic.AddInt64(&failures, 1)
					return
				}
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

func test_foreign_thread_stress_all_types() {
	lib := newLib()
	lib.CreateContext()
	lib.InitializeRequest("stress")

	const kThreads = 8
	const kIters = 30

	var failures int64
	runForeign(kThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			switch i % 8 {
			case 0:
				if _, err := lib.EchoRequest(fmt.Sprintf("stress-%d", t)); err != nil {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 1:
				if _, err := lib.CounterRequest(); err != nil {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 2:
				if _, err := lib.PrimScalarRequest(false, -100, -999999, -1.5); err != nil {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 3:
				r, err := lib.StringSeqRequest("s", 10)
				if err != nil || len(r.Items) != 10 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 4:
				r, err := lib.PrimSeqRequest(20)
				if err != nil || len(r.Values) != 20 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 5:
				r, err := lib.ObjSeqResultRequest(5)
				if err != nil || len(r.Tags) != 5 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 6:
				tags := []typemappingtestlib.Tag{
					makeTag("k0", "v0"), makeTag("k1", "v1"), makeTag("k2", "v2"),
				}
				r, err := lib.ObjSeqParamRequest(tags)
				if err != nil || r.Count != 3 {
					atomic.AddInt64(&failures, 1)
					return
				}
			case 7:
				r, err := lib.SeqStringParamRequest([]string{"a", "b", "c"})
				if err != nil || r.Count != 3 {
					atomic.AddInt64(&failures, 1)
					return
				}
			}
		}
	})

	checkEq(atomic.LoadInt64(&failures), int64(0), "no failures")
	lib.Close()
}

// ============================================================================
// TestSeqObjectEventMemorySafety
// ============================================================================

func test_seq_object_event_callback_data_correctness() {
	lib := newLib()
	lib.CreateContext()

	type tagData struct{ key, value string }
	received := &safeList[[]tagData]{}

	h := lib.OnTagSeqEvent(func(tags []typemappingtestlib.Tag) {
		snap := make([]tagData, len(tags))
		for i, t := range tags {
			snap[i] = tagData{t.Key, t.Value}
		}
		received.push(snap)
	})
	checkNe(h, uint64(0), "handle")

	lib.ObjSeqResultRequest(3)
	lib.ObjSeqResultRequest(5)
	lib.ObjSeqResultRequest(0)

	waitFor(func() bool { return received.size() >= 3 })

	checkEq(received.size(), 3, "size")

	snap0 := received.at(0)
	checkEq(len(snap0), 3, "snap0.size")
	if len(snap0) >= 3 {
		checkEq(snap0[0].key, "key-0", "k0")
		checkEq(snap0[0].value, "val-0", "v0")
		checkEq(snap0[2].key, "key-2", "k2")
		checkEq(snap0[2].value, "val-2", "v2")
	}

	snap1 := received.at(1)
	checkEq(len(snap1), 5, "snap1.size")
	if len(snap1) >= 5 {
		checkEq(snap1[0].key, "key-0", "k0")
		checkEq(snap1[4].value, "val-4", "v4")
	}

	snap2 := received.at(2)
	check(len(snap2) == 0, "empty")

	lib.OffTagSeqEvent(h)
	lib.Close()
}

func test_seq_object_event_rapid_fire_no_leak() {
	lib := newLib()
	lib.CreateContext()

	var eventCount int64
	h := lib.OnTagSeqEvent(func(_ []typemappingtestlib.Tag) {
		atomic.AddInt64(&eventCount, 1)
	})

	const kIterations = 100
	for i := 0; i < kIterations; i++ {
		lib.ObjSeqResultRequest(10)
	}

	waitFor(func() bool { return atomic.LoadInt64(&eventCount) >= int64(kIterations) }, 10.0)
	checkEq(atomic.LoadInt64(&eventCount), int64(kIterations), "count")

	lib.OffTagSeqEvent(h)
	lib.Close()
}

func test_seq_object_event_concurrent_listeners_and_requesters() {
	lib := newLib()
	lib.CreateContext()

	var eventCount int64
	h := lib.OnTagSeqEvent(func(tags []typemappingtestlib.Tag) {
		for _, t := range tags {
			_ = len(t.Key)
			_ = len(t.Value)
		}
		atomic.AddInt64(&eventCount, 1)
	})

	const kRequesterThreads = 4
	const kIters = 20

	var requestFailures int64
	runForeign(kRequesterThreads, func(t int) {
		for i := 0; i < kIters; i++ {
			r, err := lib.ObjSeqResultRequest(int32(5 + (t % 3)))
			if err != nil {
				atomic.AddInt64(&requestFailures, 1)
				return
			}
			if len(r.Tags) < 5 {
				atomic.AddInt64(&requestFailures, 1)
				return
			}
		}
	})

	expectedEvents := int64(kRequesterThreads * kIters)
	checkEq(atomic.LoadInt64(&requestFailures), int64(0), "no failures")
	waitFor(func() bool { return atomic.LoadInt64(&eventCount) >= expectedEvents })
	checkEq(atomic.LoadInt64(&eventCount), expectedEvents, "events")

	lib.OffTagSeqEvent(h)
	lib.Close()
}

// ============================================================================
// TestPreviouslyRestrictedShapes — formerly ❌ in TYPESUPPORT.md.
// ============================================================================

func test_list_inners_result_empty() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ListInnersRequest(0)
	checkEq(err, error(nil), "no err")
	checkEq(len(r.Items), 0, "items empty")
	lib.Close()
}

func test_list_inners_result_count_and_fields() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ListInnersRequest(3)
	checkEq(err, error(nil), "no err")
	checkEq(len(r.Items), 3, "items len")
	if len(r.Items) == 3 {
		checkEq(r.Items[0].Id, int32(0), "items[0].id")
		checkEq(r.Items[0].Tag, "inner-0", "items[0].tag")
		checkEq(len(r.Items[0].Bytes), 1, "items[0].bytes len")
		checkEq(r.Items[0].Bytes[0], byte(0), "items[0].bytes[0]")
		checkEq(r.Items[2].Id, int32(2), "items[2].id")
		checkEq(r.Items[2].Tag, "inner-2", "items[2].tag")
		checkEq(len(r.Items[2].Bytes), 3, "items[2].bytes len")
		checkEq(r.Items[2].Bytes[0], byte(2), "items[2].bytes[0]")
		checkEq(r.Items[2].Bytes[2], byte(4), "items[2].bytes[2]")
	}
	lib.Close()
}

func test_bulk_inners_param_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	gen, err := lib.ListInnersRequest(5)
	checkEq(err, error(nil), "gen err")
	r, err2 := lib.BulkInnersRequest(gen.Items)
	checkEq(err2, error(nil), "bulk err")
	checkEq(r.IdSum, int64(10), "idSum")
	checkEq(r.ByteCount, int64(15), "byteCount")
	lib.Close()
}

func test_inners_updated_event() {
	lib := newLib()
	lib.CreateContext()
	evts := &safeList[[]typemappingtestlib.Inner]{}
	h := lib.OnInnersUpdatedEvent(func(items []typemappingtestlib.Inner) {
		cp := make([]typemappingtestlib.Inner, len(items))
		for i, it := range items {
			bs := make([]byte, len(it.Bytes))
			copy(bs, it.Bytes)
			cp[i] = typemappingtestlib.Inner{Id: it.Id, Tag: it.Tag, Bytes: bs}
		}
		evts.push(cp)
	})
	_, err := lib.TriggerInnersUpdatedRequest(4)
	checkEq(err, error(nil), "trigger err")
	waitFor(func() bool { return evts.size() >= 1 })
	checkEq(evts.size(), 1, "events")
	snap := evts.at(0)
	checkEq(len(snap), 4, "items len")
	if len(snap) == 4 {
		checkEq(snap[0].Id, int32(0), "snap[0].id")
		checkEq(snap[0].Tag, "evt-0", "snap[0].tag")
		checkEq(len(snap[0].Bytes), 1, "snap[0].bytes len")
		checkEq(snap[3].Id, int32(3), "snap[3].id")
		checkEq(len(snap[3].Bytes), 4, "snap[3].bytes len")
	}
	lib.OffInnersUpdatedEvent(h)
	lib.Close()
}

func test_fixed_str_array_result() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.FixedStrArrayRequest("tag")
	checkEq(err, error(nil), "no err")
	checkEq(len(r.Tags), 4, "tags len")
	if len(r.Tags) == 4 {
		checkEq(r.Tags[0], "tag-0", "tags[0]")
		checkEq(r.Tags[1], "tag-1", "tags[1]")
		checkEq(r.Tags[2], "tag-2", "tags[2]")
		checkEq(r.Tags[3], "tag-3", "tags[3]")
	}
	lib.Close()
}

func test_set_tags_array_param() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.SetTagsRequest([]string{"alpha", "beta", "", "delta"})
	checkEq(err, error(nil), "no err")
	checkEq(r.Joined, "alpha|beta||delta", "joined")
	lib.Close()
}

func test_sum_prim_array_param() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.SumPrimArrayRequest([]int32{10, 20, 30, 40})
	checkEq(err, error(nil), "no err")
	checkEq(r.Total, int64(100), "total")
	lib.Close()
}

func test_fixed_obj_array_event() {
	lib := newLib()
	lib.CreateContext()
	evts := &safeList[[]typemappingtestlib.Slot]{}
	h := lib.OnFixedObjArrayEvent(func(slots []typemappingtestlib.Slot) {
		cp := make([]typemappingtestlib.Slot, len(slots))
		copy(cp, slots)
		evts.push(cp)
	})
	_, err := lib.TriggerFixedObjArrayRequest(100)
	checkEq(err, error(nil), "trigger err")
	waitFor(func() bool { return evts.size() >= 1 })
	checkEq(evts.size(), 1, "events")
	snap := evts.at(0)
	checkEq(len(snap), 4, "slots len")
	if len(snap) == 4 {
		checkEq(snap[0].Idx, int32(100), "snap[0].idx")
		checkEq(snap[0].Name, "alpha", "snap[0].name")
		checkEq(snap[2].Name, "", "snap[2].name empty")
		checkEq(snap[3].Idx, int32(103), "snap[3].idx")
		checkEq(snap[3].Name, "delta with spaces", "snap[3].name")
	}
	lib.OffFixedObjArrayEvent(h)
	lib.Close()
}

// --- Last-three-❓ probes ---------------------------------------------------

func test_nested_obj_inline_field() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.NestedObjRequest("k", "v")
	checkEq(err, error(nil), "no err")
	checkEq(r.Label, "k=v", "label")
	checkEq(r.Nested.Key, "k", "nested.key")
	checkEq(r.Nested.Value, "v", "nested.value")
	lib.Close()
}

func test_set_slots_obj_array_param() {
	lib := newLib()
	lib.CreateContext()
	slots := []typemappingtestlib.Slot{
		{Idx: 1, Name: "alpha"},
		{Idx: 2, Name: "beta"},
		{Idx: 3, Name: ""},
		{Idx: 4, Name: "delta"},
	}
	r, err := lib.SetSlotsRequest(slots)
	checkEq(err, error(nil), "no err")
	checkEq(r.Summary, "alpha|beta||delta", "summary")
	lib.Close()
}

func test_str_array_event() {
	lib := newLib()
	lib.CreateContext()
	evts := &safeList[[]string]{}
	h := lib.OnStrArrayEvent(func(words []string) {
		cp := make([]string, len(words))
		copy(cp, words)
		evts.push(cp)
	})
	_, err := lib.TriggerStrArrayRequest("word")
	checkEq(err, error(nil), "trigger err")
	waitFor(func() bool { return evts.size() >= 1 })
	checkEq(evts.size(), 1, "events")
	snap := evts.at(0)
	checkEq(len(snap), 4, "words len")
	if len(snap) == 4 {
		checkEq(snap[0], "word-0", "[0]")
		checkEq(snap[1], "word-1", "[1]")
		checkEq(snap[2], "word-2", "[2]")
		checkEq(snap[3], "word-3", "[3]")
	}
	lib.OffStrArrayEvent(h)
	lib.Close()
}

// ============================================================================
// main — runs all tests in cpp order.
// ============================================================================

// Associative containers — Table[K, V], full key coverage.

func test_map_result_all_key_flavors() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.MapResultRequest(3)
	check(err == nil, "mapResultRequest is_ok")
	checkEq(len(r.StrKeyed), 3, "strKeyed len")
	checkEq(r.StrKeyed["key-0"], int32(0), "strKeyed key-0")
	checkEq(len(r.IntKeyed), 3, "intKeyed len")
	checkEq(r.IntKeyed[0], "val-0", "intKeyed 0")
	checkEq(r.IntKeyed[2], "val-2", "intKeyed 2")
	checkEq(r.CharKeyed["a"], int32(0), "charKeyed a")
	checkEq(r.CharKeyed["c"], int32(4), "charKeyed c")
	checkEq(len(r.EnumKeyed), 3, "enumKeyed len")
	checkEq(r.EnumKeyed[typemappingtestlib.Priority_pLow], int32(0), "enumKeyed pLow")
	checkEq(r.EnumKeyed[typemappingtestlib.Priority_pHigh], int32(2), "enumKeyed pHigh")
	checkEq(r.JobKeyed[1], int32(3), "jobKeyed 1")
	lib.Close()
}

func test_map_param_roundtrip() {
	lib := newLib()
	lib.CreateContext()
	scores := map[string]int32{"x": 10, "y": 20, "z": 30}
	r, err := lib.MapParamRequest(scores)
	check(err == nil, "mapParamRequest is_ok")
	checkEq(r.Total, int64(60), "total")
	checkEq(r.Joined, "x|y|z", "joined")
	lib.Close()
}

func test_map_event() {
	lib := newLib()
	lib.CreateContext()
	received := &safeList[map[string]int32]{}
	h := lib.OnMapEvent(func(counts map[string]int32) {
		received.push(counts)
	})
	checkNe(h, uint64(0), "handle != 0")
	lib.MapParamRequest(map[string]int32{"a": 1, "b": 2})
	waitFor(func() bool { return received.size() >= 1 })
	checkEq(received.size(), 1, "received.size")
	snap := received.snapshot()
	checkEq(snap[0]["a"], int32(1), "a")
	checkEq(snap[0]["b"], int32(2), "b")
	lib.OffMapEvent(h)
	lib.Close()
}

// ----- TestAliasAndByteGaps: pure-alias every direction + seq[byte]/
//       Option[seq[byte]] event + param cells -----

func test_alias_field_request() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.AliasFieldRequest("/waku/2/default", 3)
	checkEq(err, error(nil), "no err")
	checkEq(r.Topic, "/waku/2/default", "topic")
	checkEq(len(r.Topics), 3, "topics len")
	if len(r.Topics) == 3 {
		checkEq(r.Topics[0], "/waku/2/default/0", "topics[0]")
		checkEq(r.Topics[2], "/waku/2/default/2", "topics[2]")
	}
	lib.Close()
}

func test_alias_field_request_empty_seq() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.AliasFieldRequest("topic", 0)
	checkEq(err, error(nil), "no err")
	checkEq(r.Topic, "topic", "topic")
	checkEq(len(r.Topics), 0, "topics empty")
	lib.Close()
}

func test_alias_event() {
	lib := newLib()
	lib.CreateContext()
	type cap struct {
		topic  string
		topics []string
	}
	evts := &safeList[cap]{}
	h := lib.OnAliasEvent(func(topic string, topics []string) {
		cp := make([]string, len(topics))
		copy(cp, topics)
		evts.push(cap{topic: topic, topics: cp})
	})
	checkNe(h, uint64(0), "handle != 0")
	lib.TriggerAliasEventRequest("/t", 2)
	waitFor(func() bool { return evts.size() >= 1 })
	checkEq(evts.size(), 1, "events")
	snap := evts.at(0)
	checkEq(snap.topic, "/t", "topic")
	checkEq(len(snap.topics), 2, "topics len")
	if len(snap.topics) == 2 {
		checkEq(snap.topics[0], "/t/0", "topics[0]")
		checkEq(snap.topics[1], "/t/1", "topics[1]")
	}
	lib.OffAliasEvent(h)
	lib.Close()
}

func test_byte_seq_event() {
	lib := newLib()
	lib.CreateContext()
	evts := &safeList[[]byte]{}
	h := lib.OnByteSeqEvent(func(data []byte) {
		cp := make([]byte, len(data))
		copy(cp, data)
		evts.push(cp)
	})
	checkNe(h, uint64(0), "handle != 0")
	lib.TriggerByteEventsRequest(5, true)
	waitFor(func() bool { return evts.size() >= 1 })
	snap := evts.at(0)
	checkEq(len(snap), 5, "data len")
	if len(snap) == 5 {
		checkEq(snap[0], byte(0), "data[0]")
		checkEq(snap[4], byte(4), "data[4]")
	}
	lib.OffByteSeqEvent(h)
	lib.Close()
}

func test_opt_byte_seq_event_present() {
	lib := newLib()
	lib.CreateContext()
	evts := &safeList[*[]byte]{}
	h := lib.OnOptByteSeqEvent(func(value *[]byte) {
		evts.push(value)
	})
	checkNe(h, uint64(0), "handle != 0")
	lib.TriggerByteEventsRequest(0, true)
	waitFor(func() bool { return evts.size() >= 1 })
	v := evts.at(0)
	check(v != nil, "value present")
	if v != nil {
		checkEq(len(*v), 4, "len")
		checkEq((*v)[0], byte(1), "byte[0]")
		checkEq((*v)[3], byte(4), "byte[3]")
	}
	lib.OffOptByteSeqEvent(h)
	lib.Close()
}

func test_opt_byte_seq_event_absent() {
	lib := newLib()
	lib.CreateContext()
	evts := &safeList[*[]byte]{}
	h := lib.OnOptByteSeqEvent(func(value *[]byte) {
		evts.push(value)
	})
	checkNe(h, uint64(0), "handle != 0")
	lib.TriggerByteEventsRequest(0, false)
	waitFor(func() bool { return evts.size() >= 1 })
	check(evts.at(0) == nil, "value absent")
	lib.OffOptByteSeqEvent(h)
	lib.Close()
}

func test_opt_byte_param_present() {
	lib := newLib()
	lib.CreateContext()
	payload := []byte{9, 8, 7}
	r, err := lib.OptByteParamRequest(&payload)
	checkEq(err, error(nil), "no err")
	checkEq(r.Length, int32(3), "length")
	lib.Close()
}

func test_opt_byte_param_absent() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.OptByteParamRequest(nil)
	checkEq(err, error(nil), "no err")
	checkEq(r.Length, int32(-1), "length")
	lib.Close()
}

func test_proc_sugar_alias_payload() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.EchoTopic("/waku/2/x") // EchoTopic == string
	checkEq(err, error(nil), "no err")
	checkEq(string(r), "/waku/2/x/echo", "echo topic")
	lib.Close()
}

func test_proc_sugar_distinct_payload() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.NextJob(5) // NextJob == int32
	checkEq(err, error(nil), "no err")
	checkEq(int32(r), int32(6), "next job")
	lib.Close()
}

func test_proc_sugar_seq_payload() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.ListTopics("/t", 3) // ListTopics == []string
	checkEq(err, error(nil), "no err")
	checkEq(len(r), 3, "len")
	if len(r) == 3 {
		checkEq(r[0], "/t/0", "[0]")
		checkEq(r[2], "/t/2", "[2]")
	}
	lib.Close()
}

func test_store_like_present() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.StoreLikeRequest(true)
	checkEq(err, error(nil), "no err")
	check(r.StartTime != nil, "startTime present")
	if r.StartTime != nil {
		checkEq(*r.StartTime, int64(1700), "startTime")
	}
	checkEq(len(r.Hashes), 1, "hashes len")
	if len(r.Hashes) == 1 {
		checkEq(len(r.Hashes[0]), 32, "hash len")
		checkEq(r.Hashes[0][0], byte(0), "hash[0]")
		checkEq(r.Hashes[0][31], byte(31), "hash[31]")
	}
	check(r.Cursor != nil, "cursor present")
	if r.Cursor != nil {
		checkEq(len(*r.Cursor), 32, "cursor len")
		checkEq((*r.Cursor)[0], byte(255), "cursor[0]")
	}
	lib.Close()
}

func test_store_like_absent() {
	lib := newLib()
	lib.CreateContext()
	r, err := lib.StoreLikeRequest(false)
	checkEq(err, error(nil), "no err")
	check(r.StartTime == nil, "startTime absent")
	checkEq(len(r.Hashes), 0, "hashes empty")
	check(r.Cursor == nil, "cursor absent")
	lib.Close()
}

func main() {
	fmt.Println("test_typemappingtestlib — Go type mapping coverage")
	fmt.Println("library version:", typemappingtestlib.Version())
	fmt.Println()

	fmt.Println("--- TestLifecycle ---")
	runTest("test_lifecycle_create_and_shutdown", test_lifecycle_create_and_shutdown)
	runTest("test_lifecycle_raii_shutdown", test_lifecycle_raii_shutdown)
	runTest("test_lifecycle_double_shutdown_is_safe", test_lifecycle_double_shutdown_is_safe)
	runTest("test_lifecycle_double_create_returns_error", test_lifecycle_double_create_returns_error)
	runTest("test_lifecycle_request_without_context_fails", test_lifecycle_request_without_context_fails)

	fmt.Println("\n--- TestRequests ---")
	runTest("test_requests_initialize", test_requests_initialize)
	runTest("test_requests_echo", test_requests_echo)
	runTest("test_requests_counter_increments", test_requests_counter_increments)
	runTest("test_requests_multiple_echo", test_requests_multiple_echo)
	runTest("test_dual_sig_zero", test_dual_sig_zero)
	runTest("test_dual_sig_with_label", test_dual_sig_with_label)

	fmt.Println("\n--- TestEvents ---")
	runTest("test_events_counter_changed", test_events_counter_changed)
	runTest("test_events_off_stops_delivery", test_events_off_stops_delivery)

	runTest("test_primitive_int_result_request", test_primitive_int_result_request)
	runTest("test_primitive_simple_int_event", test_primitive_simple_int_event)
	runTest("test_void_action_request", test_void_action_request)
	runTest("test_void_ping_event", test_void_ping_event)

	fmt.Println("\n--- TestContextSeparation ---")
	runTest("test_context_independent_counters", test_context_independent_counters)
	runTest("test_context_independent_echo", test_context_independent_echo)
	runTest("test_context_independent_events", test_context_independent_events)
	runTest("test_context_shutdown_one_does_not_affect_other", test_context_shutdown_one_does_not_affect_other)

	fmt.Println("\n--- TestScalarTypes ---")
	runTest("test_scalar_bool_true", test_scalar_bool_true)
	runTest("test_scalar_bool_false", test_scalar_bool_false)
	runTest("test_scalar_int32_roundtrip", test_scalar_int32_roundtrip)
	runTest("test_scalar_int64_roundtrip", test_scalar_int64_roundtrip)
	runTest("test_scalar_float64_roundtrip", test_scalar_float64_roundtrip)
	runTest("test_scalar_all_fields_roundtrip", test_scalar_all_fields_roundtrip)
	runTest("test_scalar_prim_scalar_event", test_scalar_prim_scalar_event)
	runTest("test_scalar_prim_scalar_event_false_flag", test_scalar_prim_scalar_event_false_flag)

	fmt.Println("\n--- TestEnumDistinctTypes ---")
	runTest("test_enum_roundtrip_low", test_enum_roundtrip_low)
	runTest("test_enum_roundtrip_high", test_enum_roundtrip_high)
	runTest("test_enum_roundtrip_critical", test_enum_roundtrip_critical)
	runTest("test_distinct_jobid_echoed", test_distinct_jobid_echoed)
	runTest("test_distinct_jobid_next", test_distinct_jobid_next)
	runTest("test_distinct_jobid_zero", test_distinct_jobid_zero)
	runTest("test_distinct_jobid_max_minus_one", test_distinct_jobid_max_minus_one)
	runTest("test_all_priority_values", test_all_priority_values)
	runTest("test_typed_scalar_event_enum", test_typed_scalar_event_enum)
	runTest("test_typed_scalar_event_distinct_timestamp", test_typed_scalar_event_distinct_timestamp)
	runTest("test_fixedarray_result_contains_timestamp", test_fixedarray_result_contains_timestamp)

	fmt.Println("\n--- TestSeqByteResult ---")
	runTest("test_seq_byte_empty", test_seq_byte_empty)
	runTest("test_seq_byte_length", test_seq_byte_length)
	runTest("test_seq_byte_values", test_seq_byte_values)
	runTest("test_seq_byte_wrap_around", test_seq_byte_wrap_around)
	runTest("test_seq_byte_single_element", test_seq_byte_single_element)
	runTest("test_seq_byte_large", test_seq_byte_large)

	fmt.Println("\n--- TestSeqStringTypes ---")
	runTest("test_seq_string_result_empty", test_seq_string_result_empty)
	runTest("test_seq_string_result_count", test_seq_string_result_count)
	runTest("test_seq_string_result_values", test_seq_string_result_values)
	runTest("test_seq_string_result_special_chars", test_seq_string_result_special_chars)
	runTest("test_seq_string_param_empty", test_seq_string_param_empty)
	runTest("test_seq_string_param_single", test_seq_string_param_single)
	runTest("test_seq_string_param_multiple", test_seq_string_param_multiple)
	runTest("test_seq_string_param_unicode", test_seq_string_param_unicode)
	runTest("test_string_seq_event", test_string_seq_event)
	runTest("test_string_seq_event_empty", test_string_seq_event_empty)

	fmt.Println("\n--- TestSeqPrimTypes ---")
	runTest("test_prim_seq_result_empty", test_prim_seq_result_empty)
	runTest("test_prim_seq_result_length", test_prim_seq_result_length)
	runTest("test_prim_seq_result_values", test_prim_seq_result_values)
	runTest("test_prim_seq_result_large_int64", test_prim_seq_result_large_int64)
	runTest("test_prim_seq_param_empty", test_prim_seq_param_empty)
	runTest("test_prim_seq_param_single", test_prim_seq_param_single)
	runTest("test_prim_seq_param_sum", test_prim_seq_param_sum)
	runTest("test_prim_seq_param_large_values", test_prim_seq_param_large_values)
	runTest("test_prim_seq_event", test_prim_seq_event)
	runTest("test_prim_seq_event_empty", test_prim_seq_event_empty)

	fmt.Println("\n--- TestFixedArrayTypes ---")
	runTest("test_array_result_values", test_array_result_values)
	runTest("test_array_result_length", test_array_result_length)
	runTest("test_array_result_seed_zero", test_array_result_seed_zero)
	runTest("test_array_result_negative_seed", test_array_result_negative_seed)
	runTest("test_array_result_timestamp", test_array_result_timestamp)
	runTest("test_fixed_array_event", test_fixed_array_event)
	runTest("test_fixed_array_event_zero_seed", test_fixed_array_event_zero_seed)
	runTest("test_fixed_array_multiple_requests", test_fixed_array_multiple_requests)

	fmt.Println("\n--- TestConstArraySize ---")
	runTest("test_const_array_result_length", test_const_array_result_length)
	runTest("test_const_array_result_values", test_const_array_result_values)
	runTest("test_const_array_result_zero_seed", test_const_array_result_zero_seed)
	runTest("test_const_array_result_negative_seed", test_const_array_result_negative_seed)
	runTest("test_const_array_event_values", test_const_array_event_values)
	runTest("test_const_array_event_length", test_const_array_event_length)
	runTest("test_const_array_event_zero_seed", test_const_array_event_zero_seed)
	runTest("test_const_array_event_neg_seed", test_const_array_event_neg_seed)

	fmt.Println("\n--- TestSeqObjectTypes ---")
	runTest("test_opt_scalar_present", test_opt_scalar_present)
	runTest("test_opt_scalar_absent", test_opt_scalar_absent)
	runTest("test_opt_string_present", test_opt_string_present)
	runTest("test_opt_string_absent", test_opt_string_absent)
	runTest("test_opt_seq_present", test_opt_seq_present)
	runTest("test_opt_seq_absent", test_opt_seq_absent)
	runTest("test_opt_obj_present", test_opt_obj_present)
	runTest("test_opt_obj_absent", test_opt_obj_absent)
	runTest("test_obj_seq_param_empty", test_obj_seq_param_empty)
	runTest("test_obj_seq_param_single", test_obj_seq_param_single)
	runTest("test_obj_seq_param_multiple", test_obj_seq_param_multiple)
	runTest("test_obj_seq_param_string_encoding", test_obj_seq_param_string_encoding)
	runExtras() // test_obj_as_param + bytes_echo + scan_request
	runTest("test_obj_seq_result_empty", test_obj_seq_result_empty)
	runTest("test_obj_seq_result_length", test_obj_seq_result_length)
	runTest("test_obj_seq_result_keys", test_obj_seq_result_keys)
	runTest("test_obj_seq_result_values", test_obj_seq_result_values)
	runTest("test_obj_seq_result_tag_fields", test_obj_seq_result_tag_fields)
	runTest("test_obj_seq_roundtrip", test_obj_seq_roundtrip)

	fmt.Println("\n--- TestMultipleEventListeners ---")
	runTest("test_two_scalar_event_listeners", test_two_scalar_event_listeners)
	runTest("test_remove_one_listener_keeps_other", test_remove_one_listener_keeps_other)
	runTest("test_concurrent_event_types", test_concurrent_event_types)

	fmt.Println("\n--- TestForeignThreadGcSafety ---")
	runTest("test_foreign_thread_concurrent_requests", test_foreign_thread_concurrent_requests)
	runTest("test_foreign_thread_concurrent_seq_string_requests", test_foreign_thread_concurrent_seq_string_requests)
	runTest("test_foreign_thread_concurrent_seq_prim_requests", test_foreign_thread_concurrent_seq_prim_requests)
	runTest("test_foreign_thread_concurrent_seq_object_requests", test_foreign_thread_concurrent_seq_object_requests)
	runTest("test_foreign_thread_concurrent_seq_object_param_requests", test_foreign_thread_concurrent_seq_object_param_requests)
	runTest("test_foreign_thread_concurrent_lifecycle", test_foreign_thread_concurrent_lifecycle)
	runTest("test_foreign_thread_mixed_request_types", test_foreign_thread_mixed_request_types)
	runTest("test_foreign_thread_stress_all_types", test_foreign_thread_stress_all_types)

	fmt.Println("\n--- TestSeqObjectEventMemorySafety ---")
	runTest("test_seq_object_event_callback_data_correctness", test_seq_object_event_callback_data_correctness)
	runTest("test_seq_object_event_rapid_fire_no_leak", test_seq_object_event_rapid_fire_no_leak)
	runTest("test_seq_object_event_concurrent_listeners_and_requesters", test_seq_object_event_concurrent_listeners_and_requesters)

	fmt.Println("\n--- TestPreviouslyRestrictedShapes ---")
	runTest("test_list_inners_result_empty", test_list_inners_result_empty)
	runTest("test_list_inners_result_count_and_fields", test_list_inners_result_count_and_fields)
	runTest("test_bulk_inners_param_roundtrip", test_bulk_inners_param_roundtrip)
	runTest("test_inners_updated_event", test_inners_updated_event)
	runTest("test_fixed_str_array_result", test_fixed_str_array_result)
	runTest("test_set_tags_array_param", test_set_tags_array_param)
	runTest("test_sum_prim_array_param", test_sum_prim_array_param)
	runTest("test_fixed_obj_array_event", test_fixed_obj_array_event)
	runTest("test_nested_obj_inline_field", test_nested_obj_inline_field)
	runTest("test_set_slots_obj_array_param", test_set_slots_obj_array_param)
	runTest("test_str_array_event", test_str_array_event)

	runTest("test_map_result_all_key_flavors", test_map_result_all_key_flavors)
	runTest("test_map_param_roundtrip", test_map_param_roundtrip)
	runTest("test_map_event", test_map_event)

	fmt.Println("\n--- TestAliasAndByteGaps ---")
	runTest("test_alias_field_request", test_alias_field_request)
	runTest("test_alias_field_request_empty_seq", test_alias_field_request_empty_seq)
	runTest("test_alias_event", test_alias_event)
	runTest("test_byte_seq_event", test_byte_seq_event)
	runTest("test_opt_byte_seq_event_present", test_opt_byte_seq_event_present)
	runTest("test_opt_byte_seq_event_absent", test_opt_byte_seq_event_absent)
	runTest("test_opt_byte_param_present", test_opt_byte_param_present)
	runTest("test_opt_byte_param_absent", test_opt_byte_param_absent)
	runTest("test_proc_sugar_alias_payload", test_proc_sugar_alias_payload)
	runTest("test_proc_sugar_distinct_payload", test_proc_sugar_distinct_payload)
	runTest("test_proc_sugar_seq_payload", test_proc_sugar_seq_payload)
	runTest("test_store_like_present", test_store_like_present)
	runTest("test_store_like_absent", test_store_like_absent)

	fmt.Println("\n----------------------------------------------------------------------")
	fmt.Printf("Ran %d tests: %d ok, %d failed\n", gTotal, gTotal-gFailed, gFailed)

	if gFailed > 0 {
		os.Exit(1)
	}
}
