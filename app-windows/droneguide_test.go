// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

const droneguideEDFixture = `{
  "title": "Synthetic geozone fixture",
  "features": [
    {
      "identifier": "TEST001", "country": "BEL", "name": "Voorbeeldzone",
      "type": "COMMON", "restriction": "REQ_AUTHORISATION",
      "reason": ["AIR_TRAFFIC", "OTHER"], "otherReasonInfo": "Proefzone",
      "message": "Aanvraag vereist", "restrictionConditions": ["TEST"],
      "zoneAuthority": [{"name":"Voorbeeldbeheerder","purpose":"AUTHORIZATION","email":"uas@example.org"}],
      "applicability": [
        {
          "permanent": "NO", "startDateTime": "2026-10-01T08:00:00+02:00", "endDateTime": "2026-12-01T12:00:00Z",
          "schedule": [{"day":["SUN"],"startTime":"09:30:00Z","endTime":"12:30:00Z"}]
        }
      ],
      "geometry": [
        {
          "uomDimensions":"M", "lowerLimit":0, "upperLimit":100,
          "lowerVerticalReference":"AGL", "upperVerticalReference":"AGL",
          "horizontalProjection": {
            "type":"Polygon",
            "coordinates":[
              [[4.32,50.80],[4.36,50.80],[4.36,50.86],[4.32,50.86],[4.32,50.80]],
              [[4.33,50.82],[4.34,50.82],[4.34,50.83],[4.33,50.83],[4.33,50.82]]
            ]
          }
        },
        {
          "uomDimensions":"FT", "lowerLimit":300, "upperLimit":900,
          "lowerVerticalReference":"AGL", "upperVerticalReference":"AMSL",
          "horizontalProjection":{"type":"Circle","center":[4.345,50.82],"radius":3000}
        }
      ]
    }
  ]
}`

const droneguideGeoFixture = `{
  "type":"Feature",
  "id": 123,
  "properties": {
    "name":{"nl":"Belgische proefzone","fr":"Zone belge synthétique"},
    "restriction":"PROHIBITED","description":"Synthetisch",
    "lower_limit_altitude":0,"lower_limit_reference":"GND","lower_limit_unit":"F",
    "upper_limit_altitude":70,"upper_limit_reference":"STD","upper_limit_unit":"FL",
    "validFrom":"2026-10-01T08:00:00Z","validUntil":"2026-10-01T12:00:00Z"
  },
  "geometry": {
    "type": "MultiPolygon",
    "coordinates":[
      [[[4.32,50.80],[4.36,50.80],[4.36,50.86],[4.32,50.80]]],
      [[[4.58,50.72],[4.61,50.72],[4.61,50.76],[4.58,50.72]],
       [[4.60,50.73],[4.601,50.73],[4.601,50.731],[4.60,50.73]]]
    ]
  }
}`

func TestDroneguideEDMetadataAndVolumes(t *testing.T) {
	zones, err := parseDroneguide([]byte(droneguideEDFixture))
	if err != nil || len(zones) != 2 {
		t.Fatalf("ED-269 parse returned %d zones, %v", len(zones), err)
	}
	polygon, circle := zones[0], zones[1]
	if polygon.ID != "TEST001" || polygon.Restriction != "REQ_AUTHORISATION" || polygon.Reason != "AIR_TRAFFIC, OTHER · Proefzone" ||
		len(polygon.Authorities) != 1 || len(polygon.Applicability) != 1 || polygon.Applicability[0].Schedule[0].Day[0] != "SUN" ||
		polygon.ValidFrom != "2026-10-01T08:00:00+02:00" || polygon.ValidUntil != "2026-12-01T12:00:00Z" ||
		polygon.Schedule != "SUN 09:30:00Z – 12:30:00Z" || polygon.Unit != "M" {
		t.Fatalf("metadata changed: %+v", polygon)
	}
	if len(polygon.Polygons) != 1 || len(polygon.Polygons[0]) != 2 ||
		polygon.Polygons[0][0][0] != (GeoPoint{Lat: 50.80, Lon: 4.32}) {
		t.Fatalf("geometry/holes changed: %+v", polygon.Polygons)
	}
	if circle.ID != "TEST001#2" || circle.Unit != "FT" || circle.UpperReference != "AMSL" || circle.Lower == nil ||
		*circle.Lower != 300 || circle.Circle == nil || circle.Circle.RadiusM != 3000 ||
		circle.Circle.Center != (GeoPoint{Lat: 50.82, Lon: 4.345}) {
		t.Fatalf("wrong circle altitude or projection: %+v", circle)
	}
	ring := circle.Polygons[0][0]
	if len(ring) < 97 || ring[0] != ring[len(ring)-1] || ring[0].Lat < 50.846 || ring[0].Lat > 50.848 {
		t.Fatalf("bad circular radius approximation: first vertex %+v, length %d", ring[0], len(ring))
	}
	east := droneguideDestination(GeoPoint{}, math.Pi/2, 1000)
	if math.Abs(east.Lat) > 1e-10 || math.Abs(east.Lon-1000/6378137.0*180/math.Pi) > 1e-10 {
		t.Fatalf("wrong WGS 84 destination: %+v", east)
	}
}

func TestDroneguideSingleGeoJSONAndMixedUnits(t *testing.T) {
	for _, content := range []string{
		droneguideGeoFixture,
		`{"type":"FeatureCollection","features":[` + droneguideGeoFixture + `]}`,
	} {
		zones, err := parseDroneguide([]byte(content))
		if err != nil || len(zones) != 1 {
			t.Fatalf("GeoJSON parse returned %d zones, %v", len(zones), err)
		}
		z := zones[0]
		if z.ID != "123" || z.Name != "Belgische proefzone" || z.UpperUnit != "FL" || z.LowerUnit != "FT" || z.Unit != "" ||
			z.Lower == nil || *z.Lower != 0 || z.Upper == nil || *z.Upper != 70 || z.ValidUntil == "" ||
			len(z.Polygons) != 2 || len(z.Polygons[1]) != 2 {
			t.Fatalf("wrong normalized zone: %+v", z)
		}
	}
}

func TestDroneguideImportPersistsAndRejectsInvalidReplacement(t *testing.T) {
	dir := t.TempDir()
	app := http.NewServeMux()
	stop := registerDroneguide(app, dir)
	defer stop()
	get := func(target string) droneguideView {
		t.Helper()
		rec := httptest.NewRecorder()
		app.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, target, nil))
		var view droneguideView
		if err := json.Unmarshal(rec.Body.Bytes(), &view); err != nil {
			t.Fatal(err)
		}
		return view
	}
	upload := func(data string, wantCode int) {
		t.Helper()
		rec := httptest.NewRecorder()
		app.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/droneguide/import", bytes.NewBufferString(data)))
		if rec.Code != wantCode {
			t.Fatalf("import returned HTTP %d: %s", rec.Code, rec.Body.String())
		}
	}
	if view := get("/api/droneguide"); view.State != "empty" || view.Zones == nil || len(*view.Zones) != 0 {
		t.Fatalf("initial view: %+v", view)
	}
	upload(droneguideEDFixture, http.StatusOK)
	before := get("/api/droneguide?zones=0")
	if before.State != "ready" || before.Count != 2 || before.Revision != 1 || before.Zones != nil || before.UpdatedAt == nil {
		t.Fatalf("lightweight view: %+v", before)
	}
	upload(`{"type":"FeatureCollection","features":[]}`, http.StatusBadRequest)
	upload(`{"type":"Feature","id":"bad","properties":{"restriction":"PROHIBITED"},"geometry":{"type":"Polygon","coordinates":[[[null,50],[4,50],[4,51],[4,50]]]}}`, http.StatusBadRequest)
	if got := get("/api/droneguide"); got.State != "ready" || got.Count != 2 || got.Zones == nil || got.Revision != before.Revision {
		t.Fatalf("failed import replaced cache: %+v", got)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "droneguide-state.json"))
	var stored droneguideDiskState
	var wantRaw bytes.Buffer
	_ = json.Compact(&wantRaw, []byte(droneguideEDFixture))
	if err != nil || json.Unmarshal(raw, &stored) != nil || stored.Manual == nil ||
		!bytes.Equal(wantRaw.Bytes(), stored.Manual.Raw) || stored.LiveEnabled {
		t.Fatalf("local cache differs: %v", err)
	}
	app = http.NewServeMux()
	stop()
	defer registerDroneguide(app, dir)()
	reloaded := get("/api/droneguide")
	if reloaded.State != "ready" || reloaded.Count != 2 || reloaded.Zones == nil || !reloaded.UpdatedAt.Equal(*before.UpdatedAt) {
		t.Fatalf("cache reload changed view: %+v", reloaded)
	}
	upload(droneguideGeoFixture, http.StatusOK)
	if newView := get("/api/droneguide"); newView.Count != 1 || newView.Revision != 2 {
		t.Fatalf("valid replacement failed: %+v", newView)
	}
}
