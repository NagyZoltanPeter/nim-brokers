//go:build cbor

package main

import (
	"fmt"
	"os"
	"time"

	"torpedolib"
)

func runExample() {
	fmt.Println("=== torpedolib Go example (cbor) ===")
	fmt.Println("library version:", torpedolib.Version())

	red := torpedolib.New()
	if err := red.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "red.CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("red ctx: %d\n", red.Ctx())

	blue := torpedolib.New()
	if err := blue.CreateContext(); err != nil {
		fmt.Fprintln(os.Stderr, "blue.CreateContext failed:", err)
		os.Exit(1)
	}
	fmt.Printf("blue ctx: %d\n", blue.Ctx())

	if _, err := red.InitializeCaptainRequest("Red", 8, "balanced", 101, 10); err != nil {
		fmt.Fprintln(os.Stderr, "red InitializeCaptainRequest:", err)
	}
	if _, err := blue.InitializeCaptainRequest("Blue", 8, "aggressive", 202, 10); err != nil {
		fmt.Fprintln(os.Stderr, "blue InitializeCaptainRequest:", err)
	}

	place, err := red.AutoPlaceFleetRequest()
	if err != nil {
		fmt.Fprintln(os.Stderr, "red AutoPlaceFleetRequest:", err)
	} else {
		fmt.Printf("red AutoPlaceFleetRequest OK: shipCount=%d, ownCells=%d, fleet=%d\n",
			place.ShipCount, len(place.OwnCells), len(place.Fleet))
	}
	if _, err := blue.AutoPlaceFleetRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "blue AutoPlaceFleetRequest:", err)
	}

	if _, err := red.LinkOpponentRequest(blue.Ctx()); err != nil {
		fmt.Fprintln(os.Stderr, "red LinkOpponentRequest:", err)
	}
	if _, err := red.StartGameRequest(); err != nil {
		fmt.Fprintln(os.Stderr, "red StartGameRequest:", err)
	}

	time.Sleep(100 * time.Millisecond)

	board, err := red.GetPublicBoardRequest()
	if err != nil {
		fmt.Fprintln(os.Stderr, "red GetPublicBoardRequest:", err)
	} else {
		fmt.Printf("red board snapshot: started=%v, fleetPlaced=%v, totalShotsFired=%d\n",
			board.Started, board.FleetPlaced, board.TotalShotsFired)
	}

	blue.Close()
	red.Close()
	fmt.Println("OK")
}
