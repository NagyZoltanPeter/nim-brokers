// Go consumer for the hierlib interface-model FFI example.
// Parity with cpp_example/main.cpp: lifecycle + requests + the Tick event.
package main

import (
	"fmt"
	"sync/atomic"
	"time"

	"hierlib"
)

func main() {
	fmt.Println("hierlib version:", hierlib.Version())

	lib := hierlib.New()
	if err := lib.CreateContext(); err != nil {
		panic(fmt.Sprint("create_context: ", err))
	}
	defer lib.Close()

	if _, err := lib.InitializeRequest("cfg"); err != nil {
		panic(fmt.Sprint("initialize_request: ", err))
	}
	if v, err := lib.GetValue(); err != nil || int32(v) != 7 {
		panic(fmt.Sprint("get_value: ", v, " ", err))
	}
	if el, err := lib.EchoLen("abcd"); err != nil || int32(el) != 4 {
		panic(fmt.Sprint("echo_len: ", el, " ", err))
	}

	var received int32 = -1
	h := lib.OnTick(func(n int32) { atomic.StoreInt32(&received, n) })
	if h == 0 {
		panic("on_tick handle")
	}
	if ft, err := lib.FireTick(99); err != nil || int32(ft) != 99 {
		panic(fmt.Sprint("fire_tick: ", ft, " ", err))
	}

	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadInt32(&received) < 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if atomic.LoadInt32(&received) != 99 {
		panic(fmt.Sprint("event delivery: ", received))
	}

	lib.OffTick(h)
	fmt.Println("hierlib go example: OK")
}
