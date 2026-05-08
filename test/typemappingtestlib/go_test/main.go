// Go parity matrix for typemappingtestlib.
//
// Mirrors test_typemappingtestlib.{cpp,py} and the Rust parity test:
// walks the type surface the codegen claims to support and asserts the
// wrapper returns the values the Nim providers compute. Both build
// modes share the same matrix (since the codegen produces the same
// public surface); CBOR-only tests are guarded with `//go:build cbor`.
//
//     go run .                # native FFI build  (build/)
//     go run -tags cbor .     # CBOR FFI build    (build_cbor/)

package main

import (
	"fmt"
	"os"
	"reflect"
	"sync"
	"sync/atomic"
	"time"

	"typemappingtestlib"
)

var failures int64

func check(cond bool, msg string) {
	if !cond {
		fmt.Fprintln(os.Stderr, "FAIL:", msg)
		atomic.AddInt64(&failures, 1)
	} else {
		fmt.Println("ok:", msg)
	}
}

func settle() {
	time.Sleep(150 * time.Millisecond)
}

func main() {
	fmt.Println("=== typemappingtestlib Go parity matrix ===")
	fmt.Println("library version:", typemappingtestlib.Version())

	t := typemappingtestlib.New()
	if err := t.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "CreateContext failed:", err)
		os.Exit(1)
	}

	matrix(t)
	cborOnlyMatrix(t)

	t.Close()

	if n := atomic.LoadInt64(&failures); n > 0 {
		fmt.Fprintf(os.Stderr, "=== %d failure(s) ===\n", n)
		os.Exit(1)
	}
	fmt.Println("=== all checks passed ===")
}

func matrix(t *typemappingtestlib.Typemappingtestlib) {
	init, err := t.InitializeRequest("hello")
	check(err == nil, "InitializeRequest is_ok")
	if err == nil {
		check(init.Label == "hello", "InitializeRequest.label == \"hello\"")
	}

	_, err = t.EchoRequest("ping")
	check(err == nil, "EchoRequest is_ok")

	prim, err := t.PrimScalarRequest(true, 42, 9_000_000_000, 3.14)
	check(err == nil, "PrimScalarRequest is_ok")
	if err == nil {
		check(prim.Flag, "PrimScalarRequest.flag == true")
		check(prim.I32 == 42, "PrimScalarRequest.i32 == 42")
	}

	typed, err := t.TypedScalarRequest(typemappingtestlib.Priority_pHigh, 41)
	check(err == nil, "TypedScalarRequest is_ok")
	if err == nil {
		check(typed.Priority == typemappingtestlib.Priority_pHigh,
			"TypedScalarRequest.priority == pHigh")
		check(int32(typed.NextId) == 42, "TypedScalarRequest.nextId == 42")
	}

	bs, err := t.ByteSeqRequest(5)
	check(err == nil, "ByteSeqRequest is_ok")
	if err == nil {
		check(reflect.DeepEqual(bs.Data, []byte{0, 1, 2, 3, 4}),
			"ByteSeqRequest.data == [0..5)")
	}

	ss, err := t.StringSeqRequest("p", 3)
	check(err == nil, "StringSeqRequest is_ok")
	if err == nil {
		check(len(ss.Items) == 3, "StringSeqRequest.items.len == 3")
		if len(ss.Items) >= 1 {
			check(ss.Items[0] == "p-0", "StringSeqRequest.items[0] == p-0")
		}
	}

	ps, err := t.PrimSeqRequest(4)
	check(err == nil, "PrimSeqRequest is_ok")
	if err == nil {
		check(reflect.DeepEqual(ps.Values, []int64{0, 10, 20, 30}),
			"PrimSeqRequest.values")
	}

	fa, err := t.FixedArrayRequest(2)
	check(err == nil, "FixedArrayRequest is_ok")
	if err == nil {
		check(reflect.DeepEqual(fa.Values, []int32{2, 4, 6, 8}),
			"FixedArrayRequest.values == [2,4,6,8]")
		check(int64(fa.Ts) == 2, "FixedArrayRequest.ts == 2")
	}

	osr, err := t.ObjSeqResultRequest(2)
	check(err == nil, "ObjSeqResultRequest is_ok")
	if err == nil {
		check(len(osr.Tags) == 2, "ObjSeqResultRequest.tags.len == 2")
		if len(osr.Tags) >= 1 {
			check(osr.Tags[0].Key == "key-0",
				"ObjSeqResultRequest.tags[0].key == key-0")
		}
	}

	osp, err := t.ObjSeqParamRequest([]typemappingtestlib.Tag{
		{Key: "k1", Value: "v1"},
		{Key: "k2", Value: "v2"},
	})
	check(err == nil, "ObjSeqParamRequest is_ok")
	if err == nil {
		check(osp.Count == 2, "ObjSeqParamRequest.count == 2")
		check(osp.First == "k1", "ObjSeqParamRequest.first == k1")
	}

	ssp, err := t.SeqStringParamRequest([]string{"a", "b"})
	check(err == nil, "SeqStringParamRequest is_ok")
	if err == nil {
		check(ssp.Joined == "a,b", "SeqStringParamRequest.joined == a,b")
	}

	psp, err := t.PrimSeqParamRequest([]int64{1, 2, 3, 4})
	check(err == nil, "PrimSeqParamRequest is_ok")
	if err == nil {
		check(psp.Total == 10, "PrimSeqParamRequest.total == 10")
	}

	eventMatrix(t)
}

func eventMatrix(t *typemappingtestlib.Typemappingtestlib) {
	// Each request below also emits an event with the same payload values.
	// Subscribe first, fire the request, briefly wait for the delivery
	// thread to dispatch, then assert the captured payload.

	var (
		muCounter sync.Mutex
		counter   []int32
	)
	t.OnCounterChanged(func(value int32) {
		muCounter.Lock()
		counter = append(counter, value)
		muCounter.Unlock()
	})
	_, _ = t.CounterRequest()
	_, _ = t.CounterRequest()
	settle()
	muCounter.Lock()
	check(len(counter) >= 2, "CounterChanged fired ≥2 times")
	hasPositive := false
	for _, v := range counter {
		if v >= 1 {
			hasPositive = true
			break
		}
	}
	check(hasPositive, "CounterChanged carried a positive value")
	muCounter.Unlock()

	type typedT struct {
		p    typemappingtestlib.Priority
		j    int32
		ts   int64
	}
	var (
		muTyped sync.Mutex
		typed   []typedT
	)
	t.OnTypedScalarEvent(func(p typemappingtestlib.Priority, j int32, ts int64) {
		muTyped.Lock()
		typed = append(typed, typedT{p, j, ts})
		muTyped.Unlock()
	})
	_, _ = t.TypedScalarRequest(typemappingtestlib.Priority_pHigh, 99)
	settle()
	muTyped.Lock()
	check(len(typed) >= 1, "TypedScalarEvent fired")
	if len(typed) >= 1 {
		check(typed[0].p == typemappingtestlib.Priority_pHigh,
			"TypedScalarEvent.priority == pHigh")
		check(typed[0].j == 99, "TypedScalarEvent.jobId == 99")
	}
	muTyped.Unlock()

	var (
		muStrs sync.Mutex
		strs   [][]string
	)
	t.OnStringSeqEvent(func(items []string) {
		muStrs.Lock()
		strs = append(strs, items)
		muStrs.Unlock()
	})
	_, _ = t.StringSeqRequest("evt", 2)
	settle()
	muStrs.Lock()
	check(len(strs) >= 1, "StringSeqEvent fired")
	if len(strs) >= 1 {
		check(len(strs[0]) == 2, "StringSeqEvent items.len == 2")
		if len(strs[0]) >= 1 {
			check(strs[0][0] == "evt-0", "StringSeqEvent items[0] == evt-0")
		}
	}
	muStrs.Unlock()

	var (
		muPrims sync.Mutex
		prims   [][]int64
	)
	t.OnPrimSeqEvent(func(values []int64) {
		muPrims.Lock()
		prims = append(prims, values)
		muPrims.Unlock()
	})
	_, _ = t.PrimSeqRequest(3)
	settle()
	muPrims.Lock()
	check(len(prims) >= 1, "PrimSeqEvent fired")
	if len(prims) >= 1 {
		check(reflect.DeepEqual(prims[0], []int64{0, 10, 20}),
			"PrimSeqEvent.values [0,10,20]")
	}
	muPrims.Unlock()

	var (
		muArr sync.Mutex
		arr   [][]int32
	)
	t.OnFixedArrayEvent(func(values []int32) {
		muArr.Lock()
		arr = append(arr, values)
		muArr.Unlock()
	})
	_, _ = t.FixedArrayRequest(3)
	settle()
	muArr.Lock()
	check(len(arr) >= 1, "FixedArrayEvent fired")
	if len(arr) >= 1 {
		check(reflect.DeepEqual(arr[0], []int32{3, 6, 9, 12}),
			"FixedArrayEvent.values [3,6,9,12]")
	}
	muArr.Unlock()

	var (
		muTags sync.Mutex
		tags   [][]typemappingtestlib.Tag
	)
	t.OnTagSeqEvent(func(items []typemappingtestlib.Tag) {
		muTags.Lock()
		tags = append(tags, items)
		muTags.Unlock()
	})
	_, _ = t.TagSeqRequest(2)
	settle()
	muTags.Lock()
	check(len(tags) >= 1, "TagSeqEvent fired")
	if len(tags) >= 1 {
		check(len(tags[0]) == 2, "TagSeqEvent tags.len == 2")
		if len(tags[0]) >= 1 {
			check(tags[0][0].Key == "tag-key-0",
				"TagSeqEvent tags[0].key == tag-key-0")
		}
	}
	muTags.Unlock()
}
