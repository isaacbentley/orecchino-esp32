// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDroneguideAltitudeBandIntersectsInclusiveEndpoints(t *testing.T) {
	m := func(value float64) *float64 { return &value }
	tests := []struct {
		name         string
		lower, upper *float64
		want         droneguideBandMatch
	}{
		{"extends through the complete band", m(-1), m(510), droneguideBandInside},
		{"floor touches 500 ft", m(152.4), m(1000), droneguideBandInside},
		{"floor just above 500 ft", m(math.Nextafter(152.4, math.Inf(1))), m(1000), droneguideBandOutside},
		{"ceiling touches ground", m(-10), m(0), droneguideBandInside},
		{"below ground", m(-100), m(-1), droneguideBandOutside},
		{"known ground floor and unknown ceiling", m(0), nil, droneguideBandInside},
		{"unknown floor and 500 ft ceiling", nil, m(152.4), droneguideBandInside},
		{"unknown floor and high ceiling", nil, m(400), droneguideBandUnknown},
		{"below-ground floor and unknown ceiling", m(-5), nil, droneguideBandUnknown},
		{"both bounds unknown", nil, nil, droneguideBandUnknown},
		{"published conversions conflict", m(45720), m(5943.6), droneguideBandUnknown},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := droneguideIntersectBand(test.lower, test.upper); got != test.want {
				t.Fatalf("altitude classification %v, wanted %v", got, test.want)
			}
		})
	}
}

func TestDroneguideEDAltitudeSelectionIsPerVolume(t *testing.T) {
	const polygon = `{"type":"Polygon","coordinates":[[[4.30,50.80],[4.40,50.80],[4.35,50.86],[4.30,50.80]]]}`
	const input = `{
		"identifier":"BEDEMO",
		"name":"Multiple altitude bands",
		"country":"BEL",
		"restriction":"CONDITIONAL",
		"geometry":[
			{"lowerLimit":500,"upperLimit":550,"uomDimensions":"FT","lowerVerticalReference":"AGL","upperVerticalReference":"AGL","horizontalProjection":` + polygon + `},
			{"lowerLimit":200,"upperLimit":350,"uomDimensions":"M","lowerVerticalReference":"AGL","upperVerticalReference":"AGL","horizontalProjection":` + polygon + `},
			{"lowerLimit":50,"upperLimit":300,"uomDimensions":"M","lowerVerticalReference":"AMSL","upperVerticalReference":"AMSL","horizontalProjection":` + polygon + `}
		]
	}`
	zones, err := parseDroneguide([]byte(input))
	if err != nil || len(zones) != 3 {
		t.Fatalf("source volumes not preserved: %d, %v", len(zones), err)
	}
	var snapshot droneguideSnapshot
	snapshot.selectAltitudeBand(zones, 0)
	if len(snapshot.Zones) != 1 || snapshot.Zones[0].ID != "BEDEMO" ||
		*snapshot.Zones[0].Lower != 500 || *snapshot.Zones[0].Upper != 550 || snapshot.UnknownAltitudeCount != 1 {
		t.Fatalf("wrong altitude-filtered data: %+v", snapshot)
	}
}

func TestDroneguideWFSPrefersRelativesAndUsesPublishedConversion(t *testing.T) {
	const geometry = `"geometry":{"type":"Polygon","coordinates":[[[4.3,50.8],[4.4,50.8],[4.35,50.86],[4.3,50.8]]]}`
	const input = `{"type":"FeatureCollection","features":[
		{"type":"Feature","id":"min","properties":{"restriction":"PROHIBITED",
		"lower_limit_altitude":500,"lower_limit_reference":"GND","lower_limit_unit":"F","lower_limit_altitude_meter_agl":999,
		"upper_limit_altitude_meter_agl":350},` + geometry + `},
		{"type":"Feature","id":"converted","properties":{"restriction":"PROHIBITED",
		"lower_limit_altitude":650,"lower_limit_reference":"MSL","lower_limit_unit":"F","lower_limit_altitude_meter_agl":152.4,
		"upper_limit_altitude_meter_agl":400},` + geometry + `},
		{"type":"Feature","id":"bad","properties":{"restriction":"PROHIBITED",
		"lower_limit_altitude_meter_agl":1500,"upper_limit_altitude_meter_agl":500},` + geometry + `},
		{"type":"Feature","id":"local","properties":{"restriction":"PROHIBITED",
		"upper_limit_altitude":500,"upper_limit_reference":"GND","upper_limit_unit":"F","upper_limit_altitude_meter_agl":152.4},` + geometry + `}
	]}`
	zones, omitted, err := parseDroneguideSnapshot([]byte(input), true)
	if err != nil {
		t.Fatal(err)
	}
	var snapshot droneguideSnapshot
	snapshot.selectAltitudeBand(zones, omitted)
	if len(snapshot.Zones) != 3 || snapshot.UnknownAltitudeCount != 1 || snapshot.Zones[0].ID != "min" ||
		snapshot.Zones[1].ID != "converted" || snapshot.Zones[2].ID != "local" {
		t.Fatalf("wrong WFS band results: %+v", snapshot)
	}
}

func TestDroneguideAltitudeStatusSurvivesImportAndRestart(t *testing.T) {
	// Remove the published ground reference so neither imported bound
	// can be converted to AGL. A valid import can select zero volumes.
	input := strings.Replace(droneguideGeoFixture, `"lower_limit_reference":"GND"`,
		`"lower_limit_reference":"MSL"`, 1)
	dir := t.TempDir()
	mux := http.NewServeMux()
	stop := registerDroneguide(mux, dir)
	post := httptest.NewRecorder()
	mux.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/api/droneguide/import", strings.NewReader(input)))
	stop()
	if post.Code != http.StatusOK {
		t.Fatalf("valid altitude-unknown import failed: %s", post.Body)
	}
	mux = http.NewServeMux()
	defer registerDroneguide(mux, dir)()
	get := httptest.NewRecorder()
	mux.ServeHTTP(get, httptest.NewRequest(http.MethodGet, "/api/droneguide", nil))
	var view droneguideView
	if err := json.Unmarshal(get.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if view.State != "ready" || view.Count != 0 || view.UnknownAltitudeCount != 1 ||
		view.OmittedCount != 0 || view.Zones == nil || len(*view.Zones) != 0 {
		t.Fatalf("filter classification or dataset was lost after restart: %+v", view)
	}
}
