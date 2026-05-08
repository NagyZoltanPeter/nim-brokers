// Torpedo Duel — Go wrapper example.
//
// Counterpart to the C++/Python/Rust torpedo examples: bootstraps two
// captain contexts, links them, starts the duel, prints a status
// snapshot. The same source compiles for both build modes — the
// generated wrapper module exposes an identical Go API in either mode.
//
//     go run .                # native FFI build (nimlib/build/)
//     go run -tags cbor .     # CBOR FFI build   (nimlib/build_cbor/)

package main

import (
	"fmt"
	"os"
	"sync"
	"time"

	"torpedolib"
)

type counters struct {
	mu        sync.Mutex
	remarks   int
	volleys   int
	shots     int
	matchEnds []string
}

func main() {
	fmt.Println("=== torpedolib Go example ===")
	fmt.Println("library version:", torpedolib.Version())

	red := torpedolib.New()
	if err := red.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "red.CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("red ctx:  %d\n", red.Ctx())

	blue := torpedolib.New()
	if err := blue.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "blue.CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("blue ctx: %d\n\n", blue.Ctx())

	c := &counters{}

	// Subscribe to every event broker on both captains.
	for _, lib := range []*torpedolib.Torpedolib{red, blue} {
		lib := lib
		hRemark := lib.OnCaptainRemark(func(captainName string, phase string, _ string, _ int32) {
			c.mu.Lock()
			c.remarks++
			_ = captainName
			_ = phase
			c.mu.Unlock()
		})
		hVolley := lib.OnVolleyEvent(func(_ string, _ int32, _ string, _ int32, _ int32, _ string, _ bool, _ bool, _ string, _ bool, _ string) {
			c.mu.Lock()
			c.volleys++
			c.mu.Unlock()
		})
		hShot := lib.OnShotResolved(func(_ string, _ int32, _ int32, _ int32, _ bool, _ bool, _ bool, _ string, _ bool) {
			c.mu.Lock()
			c.shots++
			c.mu.Unlock()
		})
		hMatch := lib.OnMatchEnded(func(captainName string, outcome string, message string, _ int32) {
			c.mu.Lock()
			c.matchEnds = append(c.matchEnds, fmt.Sprintf("%s %s: %s", captainName, outcome, message))
			c.mu.Unlock()
		})
		_, _, _, _ = hRemark, hVolley, hShot, hMatch
	}

	// --- Initialize captains -----------------------------------------------
	if r, err := red.InitializeCaptainRequest("Red", 8, "balanced", 101, 10); err != nil {
		fmt.Fprintln(os.Stderr, "red InitializeCaptainRequest:", err)
	} else {
		fmt.Printf("red initialize:  initialized=%v\n", r.Initialized)
	}
	if r, err := blue.InitializeCaptainRequest("Blue", 8, "aggressive", 202, 10); err != nil {
		fmt.Fprintln(os.Stderr, "blue InitializeCaptainRequest:", err)
	} else {
		fmt.Printf("blue initialize: initialized=%v\n\n", r.Initialized)
	}

	// --- Auto-place fleets (exercises seq[Object] result) -----------------
	if p, err := red.AutoPlaceFleetRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "red AutoPlaceFleetRequest:", err)
	} else {
		fmt.Printf("red autoPlace:  shipCount=%d ownCells=%d fleet=%d\n",
			p.ShipCount, len(p.OwnCells), len(p.Fleet))
	}
	if p, err := blue.AutoPlaceFleetRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "blue AutoPlaceFleetRequest:", err)
	} else {
		fmt.Printf("blue autoPlace: shipCount=%d ownCells=%d fleet=%d\n\n",
			p.ShipCount, len(p.OwnCells), len(p.Fleet))
	}

	// --- Link the captains so they share the same duel --------------------
	if l, err := red.LinkOpponentRequest(blue.Ctx()); err != nil {
		fmt.Fprintln(os.Stderr, "red LinkOpponentRequest:", err)
	} else {
		fmt.Printf("red linkOpponent: accepted=%v opponentCtx=%d\n", l.Accepted, l.OpponentCtx)
	}

	// --- Start the duel ---------------------------------------------------
	if s, err := red.StartGameRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "red StartGameRequest:", err)
	} else {
		fmt.Printf("red startGame:    accepted=%v started=%v\n\n", s.Accepted, s.Started)
	}

	// --- Let a few exchanges settle, then snapshot the public board ------
	time.Sleep(300 * time.Millisecond)
	if b, err := red.GetPublicBoardRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "red GetPublicBoardRequest:", err)
	} else {
		fmt.Printf("red board snapshot: started=%v fleetPlaced=%v totalShotsFired=%d\n",
			b.Started, b.FleetPlaced, b.TotalShotsFired)
	}
	if b, err := blue.GetPublicBoardRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "blue GetPublicBoardRequest:", err)
	} else {
		fmt.Printf("blue board snapshot: started=%v fleetPlaced=%v totalShotsFired=%d\n\n",
			b.Started, b.FleetPlaced, b.TotalShotsFired)
	}

	// --- Event totals -----------------------------------------------------
	c.mu.Lock()
	fmt.Println("--- Event totals ---")
	fmt.Printf("  CaptainRemark: %d\n", c.remarks)
	fmt.Printf("  VolleyEvent:   %d\n", c.volleys)
	fmt.Printf("  ShotResolved:  %d\n", c.shots)
	fmt.Printf("  MatchEnded:    %d\n", len(c.matchEnds))
	for _, m := range c.matchEnds {
		fmt.Printf("    %s\n", m)
	}
	c.mu.Unlock()

	blue.Close()
	red.Close()
	fmt.Println("OK")
}
