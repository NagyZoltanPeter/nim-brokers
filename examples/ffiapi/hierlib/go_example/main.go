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

	// One-way signal (fire-and-forget, no response): nudge the value; poll
	// GetValue for the observable effect once the handler has run.
	if err := lib.NudgeSignal(10); err != nil {
		panic(fmt.Sprint("nudge_signal: ", err))
	}
	sigDeadline := time.Now().Add(2 * time.Second)
	for {
		v, err := lib.GetValue()
		if err == nil && int32(v) == 17 {
			break
		}
		if time.Now().After(sigDeadline) {
			panic(fmt.Sprint("signal delivery: ", v, " ", err))
		}
		time.Sleep(10 * time.Millisecond)
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

	// reduced-A: create a sub-interface instance, drive its own methods (routed
	// to the same processing thread via shared classCtx), then release it.
	widget, err := lib.MakeWidget(5)
	if err != nil {
		panic(fmt.Sprint("make_widget: ", err))
	}
	if widget.Ctx() == 0 {
		panic("widget ctx")
	}
	if a, err := widget.Area(); err != nil || int32(a) != 25 {
		panic(fmt.Sprint("widget.Area: ", a, " ", err))
	}
	if s, err := widget.Scale(3); err != nil || int32(s) != 15 {
		panic(fmt.Sprint("widget.Scale: ", s, " ", err))
	}
	if a, err := widget.Area(); err != nil || int32(a) != 225 {
		panic(fmt.Sprint("widget.Area after scale: ", a, " ", err))
	}

	// Sub-interface one-way signal: routes to THIS widget by its ctx
	// (size 15 -> 20 -> area 400). Poll Area for the async one-way delivery.
	if err := widget.ResizeSignal(5); err != nil {
		panic(fmt.Sprint("resize_signal: ", err))
	}
	wsd := time.Now().Add(2 * time.Second)
	for {
		a, err := widget.Area()
		if err == nil && int32(a) == 400 {
			break
		}
		if time.Now().After(wsd) {
			panic(fmt.Sprint("widget signal delivery: ", a, " ", err))
		}
		time.Sleep(10 * time.Millisecond)
	}

	// A second, independent widget (own instanceCtx, same library).
	w2, err := lib.MakeWidget(2)
	if err != nil {
		panic(fmt.Sprint("make_widget 2: ", err))
	}
	if a, err := w2.Area(); err != nil || int32(a) != 4 {
		panic(fmt.Sprint("w2.Area: ", a, " ", err))
	}
	w2.Close()

	widget.Close() // explicit release
	widget.Close() // idempotent
	if _, err := widget.Area(); err == nil {
		panic("post-release call must error")
	}

	fmt.Println("hierlib go example: OK")
}
