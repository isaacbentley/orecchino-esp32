// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"slices"
	"strings"
	"testing"
)

func TestTilePlanMatchesFirmwareExamples(t *testing.T) {
	// Reference counts and radii from tests/tile_plan_test.cpp on the same coordinates.
	input := tileInput{Lat: 37.8, Lon: -122.4, RadiusKm: 3}
	plan := makeTilePlan(input, 0xCF0000, 64*1024, nil)
	if plan.TileCount != 66 || len(plan.paths) != 66 || plan.PlanBytes != 66*12288 || plan.Shrunk {
		t.Fatalf("unexpected T5 plan %+v", plan)
	}
	input.RadiusKm = 10
	plan = makeTilePlan(input, 0x5E0000, 200*1024, nil)
	if plan.RadiiKm != [tileZooms]float64{10, 10, 10, 8} || !plan.Shrunk || plan.PlanBytes > plan.CapacityBytes {
		t.Fatalf("unexpected SenseCAP plan %+v", plan)
	}
}

func TestTilePlanWrapAndProtectsBothFormats(t *testing.T) {
	input := tileInput{Lat: 37.8, Lon: 179.99, RadiusKm: 3}
	near := tileAt(37.8, -179.99, 15).jpegPath()
	nearPNG := strings.TrimSuffix(near, ".jpg") + ".png"
	farHigh := tileAt(40.5, 179.99, 15).jpegPath()
	farLessHigh := tileAt(50, 179.99, 14).jpegPath()
	nearerHigh := tileAt(39, 179.99, 15).jpegPath()
	files := map[string]int64{near: 5000, nearPNG: 6000, farHigh: 10000, farLessHigh: 10000, nearerHigh: 7000, "/tiles/.src": 100}
	plan := makeTilePlan(input, 0xCF0000, 50000, files)
	if plan.TileCount != 69 || plan.Present != 1 || plan.Missing != 68 || !slices.Contains(plan.paths, near) {
		t.Fatalf("unexpected wrapped plan %+v", plan)
	}
	if !slices.Equal(plan.victims, []string{farHigh, nearerHigh, farLessHigh}) {
		t.Fatalf("unexpected eviction order %v", plan.victims)
	}
	if plan.PlanBytes != 68*12288+11000 {
		t.Fatalf("both formats must count toward bytes while sharing one tile, got %d", plan.PlanBytes)
	}
}

func TestTilePlanReservesFlash(t *testing.T) {
	input := tileInput{Lat: 37.8, Lon: -122.4, RadiusKm: 3}
	plan := makeTilePlan(input, tileReserve, 4096, nil)
	if plan.TileCount != 0 || plan.CapacityBytes != 0 || !plan.Shrunk || len(plan.paths) != 0 || plan.RadiiKm != [tileZooms]float64{-1, -1, -1, -1} {
		t.Fatalf("plan must drop all levels when only the reserve is left, got %+v", plan)
	}
}
