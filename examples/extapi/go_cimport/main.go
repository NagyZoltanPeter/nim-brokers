// EXTAPI example — scenario 4: a plain C-ABI library written in Go
// (-buildmode=c-shared). It knows nothing about brokers; the Nim host imports
// its functions with RequestBroker(EXTAPI[codec], importc = ..., dynlib = ...).
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"time"
	"unsafe"
)

//export codec_crc
func codec_crc(seed C.uint32_t, buf *C.uint8_t, n C.uint32_t) C.uint32_t {
	h := uint32(seed)
	if n > 0 {
		for _, b := range unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(n)) {
			h = h*31 + uint32(b)
		}
	}
	return C.uint32_t(h)
}

// codec_slow_sum is blocking on purpose: sleeps ms, then sums the bytes. 0 = ok.
//
//export codec_slow_sum
func codec_slow_sum(src *C.uint8_t, n C.uint32_t, ms C.uint32_t, out *C.uint64_t) C.int32_t {
	if out == nil {
		return -1
	}
	time.Sleep(time.Duration(ms) * time.Millisecond)
	var t uint64
	if n > 0 {
		for _, b := range unsafe.Slice((*byte)(unsafe.Pointer(src)), int(n)) {
			t += uint64(b)
		}
	}
	*out = C.uint64_t(t)
	return 0
}

func main() {}
