// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type airVectorObserver struct {
	Lat  *float64 `json:"lat"`
	Lon  *float64 `json:"lon"`
	Elev *float64 `json:"elev_m"`
}

func (o *airVectorObserver) observer() airObserver {
	if o == nil {
		return airObserver{}
	}
	var point *GeoPoint
	if o.Lat != nil && o.Lon != nil {
		point = &GeoPoint{Lat: *o.Lat, Lon: *o.Lon}
	}
	return airObserver{Point: point, Elev: o.Elev}
}

type airVectorAlert struct {
	Level         string   `json:"level"`
	Kind          string   `json:"kind"`
	DroneID       string   `json:"drone"`
	Hex           string   `json:"hex"`
	Summary       string   `json:"text"`
	Held          bool     `json:"held"`
	HeightUnknown bool     `json:"height_unknown"`
	Ground        bool     `json:"on_ground"`
	Approx        bool     `json:"approx"`
	FromObserver  bool     `json:"from_observer"`
	Relation      string   `json:"vert_rel"`
	Action        string   `json:"action"`
	Resolution    string   `json:"resolution"`
	Horizontal    float64  `json:"horiz_m"`
	Vertical      *float64 `json:"vert_m"`
	Bearing       float64  `json:"bearing_deg"`
	CPA           *float64 `json:"cpa_s"`
	Age           float64  `json:"age_s"`
}

func TestAirTrafficUpstreamVectors(t *testing.T) {
	files, err := filepath.Glob("testdata/traffic/*.json")
	if err != nil || len(files) < 15 {
		t.Fatalf("could not load upstream vectors: %d files (%v)", len(files), err)
	}
	steps, checked := 0, 0
	for _, path := range files {
		t.Run(filepath.Base(path), func(t *testing.T) {
			var fixture struct {
				Observer *airVectorObserver `json:"observer"`
				Drones   []airDrone         `json:"drones"`
				Steps    []struct {
					Seconds  float64            `json:"t_s"`
					DataAge  *float64           `json:"data_age_s"`
					Observer *airVectorObserver `json:"observer"`
					Drones   []airDrone         `json:"drones"`
					Aircraft []map[string]any   `json:"aircraft"`
					Expect   struct {
						Summary string           `json:"summary"`
						Alerts  []airVectorAlert `json:"alerts"`
					} `json:"expect"`
				} `json:"steps"`
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(data, &fixture); err != nil {
				t.Fatal(err)
			}
			var state airRuleState
			for _, step := range fixture.Steps {
				t.Run(fmt.Sprintf("at_%gs", step.Seconds), func(t *testing.T) {
					steps++
					now := time.UnixMilli(1_000_000 + int64(math.Round(step.Seconds*1000)))
					drones, observer := step.Drones, step.Observer
					if drones == nil {
						drones = fixture.Drones
					}
					if observer == nil {
						observer = fixture.Observer
					}
					var aircraft []airAircraft
					for _, raw := range step.Aircraft {
						parsed, ok := airParseWire(raw, now)
						if !ok {
							t.Fatalf("invalid vector aircraft %v", raw["hex"])
						}
						aircraft = append(aircraft, parsed)
					}
					var received time.Time
					if step.DataAge != nil {
						received = now.Add(-time.Duration(math.Round(*step.DataAge*1000)) * time.Millisecond)
					}
					alerts := state.evaluate(drones, aircraft, observer.observer(), received, now)
					if summary := airTrafficSummary(alerts, received, now); summary != step.Expect.Summary {
						t.Errorf("summary = %q, want %q", summary, step.Expect.Summary)
					}
					if len(alerts) != len(step.Expect.Alerts) {
						t.Fatalf("%d alerts, want %d", len(alerts), len(step.Expect.Alerts))
					}
					for i, got := range alerts {
						want := step.Expect.Alerts[i]
						actual := airVectorAlert{
							Level: got.Level, Kind: got.Kind, DroneID: got.DroneID, Hex: got.Hex, Summary: got.Summary,
							Held: got.Held, HeightUnknown: got.VerticalM == nil, Ground: got.Ground,
							Approx: got.Approx, FromObserver: got.FromObserver, Relation: got.VerticalRelation,
							Action: got.Action, Resolution: got.Action + "; " + got.Detail,
							Horizontal: want.Horizontal, Vertical: want.Vertical, Bearing: want.Bearing, CPA: want.CPA, Age: want.Age,
						}
						if actual != want {
							t.Errorf("alert %d got %+v; want %+v", i, actual, want)
						}
						assertAirNumeric(t, "horizontal", airNumber(got.HorizontalM), airNumber(want.Horizontal))
						assertAirNumeric(t, "vertical", got.VerticalM, want.Vertical)
						assertAirNumeric(t, "bearing", airNumber(got.BearingDeg), airNumber(want.Bearing))
						assertAirNumeric(t, "closest approach", got.CPAS, want.CPA)
						assertAirNumeric(t, "age", airNumber(got.Age), airNumber(want.Age))
						checked++
					}
				})
			}
		})
	}
	if steps < 60 || checked < 180 {
		t.Fatalf("only checked %d steps and %d alerts", steps, checked)
	}
	t.Logf("verified %d steps and %d expected alerts across %d upstream fixtures", steps, checked, len(files))
}

func assertAirNumeric(t *testing.T, name string, got, want *float64) {
	t.Helper()
	if got == nil || want == nil {
		if (got == nil) != (want == nil) {
			t.Errorf("%s: nil mismatch", name)
		}
		return
	}
	if math.Abs(*got-*want) > 1e-6 {
		t.Errorf("%s = %f, want %f", name, *got, *want)
	}
}

func TestAirADSBRecordedFeedAndTransfer(t *testing.T) {
	data, err := os.ReadFile("testdata/adsb_lol_point_sfo.json")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_790_000_000, 0)
	aircraft, err := airParseADSB(data, now)
	if err != nil || len(aircraft) == 0 {
		t.Fatalf("no aircraft parsed (%v)", err)
	}
	for _, command := range airHostCommands(aircraft, now, now) {
		encoded, err := json.Marshal(command)
		if err != nil || len(encoded) >= 1600 {
			t.Fatalf("unusable receiver command %s (%v)", encoded, err)
		}
	}
}
