// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"encoding/json"
	"fmt"
	"math"
	"testing"
)

func TestTFRGeoJSON(t *testing.T) {
	content := []byte(`{"type":"FeatureCollection","features":[
		{"type":"Feature","id":"first","properties":{"GID":21,"NOTAM_KEY":"6/1234","TITLE":"First flight restriction","STATE":"CA","LEGAL":"SECURITY"},
		 "geometry":{"type":"Polygon","coordinates":[[[-122.5,37.8],[-122.4,37.8],[-122.4,37.9],[-122.5,37.8]]]}},
		{"type":"Feature","id":"second","properties":{},"geometry":{"type":"MultiPolygon","coordinates":[
			[[[-122.6,37.8],[-122.55,37.8],[-122.55,37.9],[-122.6,37.8]]],
			[[[-122.2,37.8],[-122.1,37.8],[-122.1,37.9],[-122.2,37.8]]]
		]}},
		{"type":"Feature","geometry":null,"properties":{}}
	]}`)
	zones, err := parseTFR(content)
	if err != nil {
		t.Fatal(err)
	}
	if len(zones) != 3 {
		t.Fatalf("got %d zones, want 3", len(zones))
	}
	z := zones[0]
	if z.ID != "21-6/1234-0" || z.NOTAM != "6/1234" || z.Legal != "SECURITY" || z.State != "CA" || z.Title != "First flight restriction" || len(z.Ring) != 3 {
		t.Errorf("unexpected zone properties: %+v", z)
	}
	if !z.contains(GeoPoint{Lat: 37.82, Lon: -122.44}) || z.contains(GeoPoint{Lat: 38, Lon: -122.44}) {
		t.Error("zone membership did not match polygon")
	}
}

func TestTFRFeedRejectsMissingFeatures(t *testing.T) {
	for _, input := range []string{`{"type":"FeatureCollection"}`, `{"type":"FeatureCollection","features":null}`, `{"type":"Error","features":[]}`} {
		if _, err := parseTFR([]byte(input)); err == nil {
			t.Errorf("accepted malformed feed %s", input)
		}
	}
	empty, err := parseTFR([]byte(`{"type":"FeatureCollection","features":[]}`))
	if err != nil || len(empty) != 0 {
		t.Fatalf("valid empty feed returned %v, %v", empty, err)
	}
	if commands := tfrCommands(empty, nil); len(commands) != 1 || commands[0].(map[string]any)["cmd"] != "tfr_clear" {
		t.Fatalf("empty feed commands: %v", commands)
	}
}

func TestTFREnclosureContainsSourceAfterFirmwareRounding(t *testing.T) {
	for _, center := range []GeoPoint{{Lat: 38, Lon: -122}, {Lat: 67.9, Lon: 179.9}} {
		ring := make([]GeoPoint, 0, 181)
		for i := 0; i < cap(ring)-1; i++ {
			angle := float64(i) * math.Pi / 90
			radius := 1 + 0.3*math.Cos(3*angle)
			ring = append(ring, GeoPoint{Lat: center.Lat + 0.06*radius*math.Sin(angle), Lon: center.Lon + 0.06*radius*math.Cos(angle)})
		}
		polygon := tfrEnclosure(ring)
		if len(polygon) < 3 || len(polygon) > 24 {
			t.Fatalf("enclosure length %d", len(polygon))
		}
		for i, point := range polygon {
			if math.Abs(point.Lat) > 90 || math.Abs(point.Lon) > 180 {
				t.Fatalf("invalid coordinate: %+v", point)
			}
			polygon[i] = GeoPoint{Lat: float64(float32(point.Lat)), Lon: float64(float32(point.Lon))}
		}
		for _, point := range ring {
			if !tfrContains(polygon, point) {
				t.Fatalf("enclosure lost point %+v", point)
			}
		}
	}
}

func TestTFRCommandsUseNearestSixteen(t *testing.T) {
	zone := func(index int, lon float64) tfrZone {
		return tfrZone{
			NOTAM:    fmt.Sprintf("6/%04d", index),
			Ring:     []GeoPoint{{Lat: 38, Lon: lon}, {Lat: 38, Lon: lon + 0.001}, {Lat: 38.001, Lon: lon}},
			centroid: GeoPoint{Lat: 38.0003, Lon: lon + 0.0003},
		}
	}
	zones := []tfrZone{zone(99, -100)}
	for i := 20; i >= 1; i-- {
		zones = append(zones, zone(i, -122+float64(i)/100))
	}
	if commands := tfrCommands(zones, nil); len(commands) != 0 {
		t.Errorf("non-empty feed without a reference should leave prior zones alone, got %v", commands)
	}
	commands := tfrCommands(zones, &GeoPoint{Lat: 38, Lon: -122})
	if len(commands) != 17 || commands[0].(map[string]any)["cmd"] != "tfr_clear" {
		t.Fatalf("expected clear followed by 16 nearby polygons, got %v", commands)
	}
	for i, cmd := range commands[1:] {
		want := fmt.Sprintf("6/%04d", i+1)
		if got := cmd.(map[string]any)["id"]; got != want {
			t.Fatalf("zone %d: got %v, want %q", i, got, want)
		}
		wire, err := json.Marshal(cmd)
		if err != nil || len(wire) >= 1600 {
			t.Fatalf("invalid firmware command: %q, %v", wire, err)
		}
	}
}
