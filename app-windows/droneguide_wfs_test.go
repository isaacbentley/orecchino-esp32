// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func droneguideWFSFixture(id string, active int) string {
	return fmt.Sprintf(`{
		"type":"Feature","id":"uaszone.%s","properties":{
			"unique_identifier":%q,"name":"{\"en\":\"Example\",\"nl\":\"Proef\"}","restriction":"PROHIBITED",
			"type_code":"TEMPORARY-NO-FLY-ZONE","active_at_window_start":%d
		},"geometry":{"type":"Polygon","coordinates":[[[4.30,50.80],[4.40,50.80],[4.35,50.86],[4.30,50.80]]]}
	}`, id, id, active)
}

func TestDroneguideWFSFetchCompletesPagesAndBindsActivity(t *testing.T) {
	var requests atomic.Int32
	start := time.Date(2026, 10, 1, 13, 45, 16, 220*int(time.Millisecond), time.UTC)
	wfs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		page := int(requests.Add(1)) - 1
		query := r.URL.Query()
		if query.Get("typeNames") != "uaszone" || query.Get("startIndex") != strconv.Itoa(page) ||
			query.Get("sortBy") != "unique_identifier A" || query.Get("cql_filter") != "type_code <> 'TIME_ZONE'" ||
			query.Get("viewParams") != `window_start:2026-10-01T13\:45\:16.220Z;window_end:2026-10-02T13\:45\:16.220Z;show_planned:true` {
			t.Errorf("unexpected WFS query %v", query)
		}
		fmt.Fprintf(w, `{"type":"FeatureCollection","numberMatched":2,"numberReturned":1,"totalFeatures":2,"features":[%s]}`,
			droneguideWFSFixture(strconv.Itoa(page), page))
	}))
	defer wfs.Close()
	raw, zones, _, err := fetchDroneguideWFS(t.Context(), wfs.Client(), wfs.URL, start)
	if err != nil || len(zones) != 2 || requests.Load() != 2 {
		t.Fatalf("fetch returned %d zones from %d requests, %v", len(zones), requests.Load(), err)
	}
	if zones[0].ActiveAtSnapshot == nil || !*zones[0].ActiveAtSnapshot ||
		zones[1].ActiveAtSnapshot == nil || *zones[1].ActiveAtSnapshot || zones[0].Name != "Proef" {
		t.Fatalf("bad activity metadata: %+v", zones)
	}
	manual, err := parseDroneguide(raw)
	if err != nil || manual[0].ActiveAtSnapshot != nil || manual[1].ActiveAtSnapshot != nil {
		t.Fatalf("import treated WFS flags as live: %+v, %v", manual, err)
	}
}

func TestDroneguideWFSRejectsUnknownAndChangingTotals(t *testing.T) {
	for _, meta := range []string{`"numberMatched":"unknown","numberReturned":1`, `"numberMatched":2,"numberReturned":1`} {
		t.Run(meta, func(t *testing.T) {
			wfs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				m := meta
				if r.URL.Query().Get("startIndex") == "1" {
					m = `"numberMatched":3,"numberReturned":1`
				}
				fmt.Fprintf(w, `{"type":"FeatureCollection",%s,"features":[%s]}`, m, droneguideWFSFixture("example", 0))
			}))
			defer wfs.Close()
			if _, _, _, err := fetchDroneguideWFS(t.Context(), wfs.Client(), wfs.URL, time.Now()); err == nil {
				t.Fatal("accepted unconfirmed complete coverage")
			}
		})
	}
}

func TestDroneguideLiveOptInRefreshCacheAndImport(t *testing.T) {
	var remoteMode atomic.Int32
	var requests atomic.Int32
	inFlight := make(chan struct{}, 1)
	cancelled := make(chan struct{}, 1)
	unblock := make(chan struct{})
	wfs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		switch remoteMode.Load() {
		case 1:
			w.WriteHeader(http.StatusServiceUnavailable)
		case 2:
			inFlight <- struct{}{}
			select {
			case <-r.Context().Done():
				cancelled <- struct{}{}
			case <-unblock:
			}
		default:
			fmt.Fprintf(w, `{"type":"FeatureCollection","numberMatched":1,"numberReturned":1,"features":[%s]}`,
				droneguideWFSFixture("example", 0))
		}
	}))
	defer wfs.Close()
	defer close(unblock)
	dir := t.TempDir()
	app := http.NewServeMux()
	stop := registerDroneguideSource(app, dir, wfs.Client(), wfs.URL)
	defer func() { stop() }()
	do := func(method, path, body string, status int) droneguideView {
		t.Helper()
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(body)))
		if w.Code != status {
			t.Fatalf("%s %s returned HTTP %d, want %d: %s", method, path, w.Code, status, w.Body)
		}
		var view droneguideView
		if status < 400 && json.Unmarshal(w.Body.Bytes(), &view) != nil {
			t.Fatalf("invalid JSON: %s", w.Body)
		}
		return view
	}
	wait := func(state string) droneguideView {
		t.Helper()
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		defer cancel()
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			view := do(http.MethodGet, "/api/droneguide", "", http.StatusOK)
			if view.State == state {
				return view
			}
			select {
			case <-ctx.Done():
				t.Fatalf("view never reached %s: %+v", state, view)
			case <-ticker.C:
			}
		}
	}
	manual := do(http.MethodPost, "/api/droneguide/import", droneguideGeoFixture, http.StatusOK)
	if manual.LiveEnabled || manual.SourceType != "import" || manual.Count != 1 || requests.Load() != 0 {
		t.Fatalf("unexpected initial manual state: %+v, %d requests", manual, requests.Load())
	}
	do(http.MethodPost, "/api/droneguide/refresh", "", http.StatusConflict)
	if requests.Load() != 0 {
		t.Fatal("requested live data without opt-in")
	}
	loading := do(http.MethodPost, "/api/droneguide/live", `{"enabled":true}`, http.StatusAccepted)
	if loading.State != "loading" || !loading.LiveEnabled || loading.SourceType != "import" {
		t.Fatalf("refresh failed to retain previous import: %+v", loading)
	}
	live := wait("ready")
	if live.SourceType != "live" || live.Zones == nil || len(*live.Zones) != 1 || live.SnapshotAt == nil || live.UpdatedAt == nil ||
		live.Stale || (*live.Zones)[0].ActiveAtSnapshot == nil || !*(*live.Zones)[0].ActiveAtSnapshot {
		t.Fatalf("unexpected live state: %+v", live)
	}

	remoteMode.Store(1)
	do(http.MethodPost, "/api/droneguide/refresh", "", http.StatusAccepted)
	failed := wait("error")
	if !failed.Stale || failed.Count != 1 || failed.Revision != live.Revision || failed.Error == "" ||
		!failed.UpdatedAt.Equal(*live.UpdatedAt) || !failed.SnapshotAt.Equal(*live.SnapshotAt) {
		t.Fatalf("failed refresh lost visible data: %+v", failed)
	}

	remoteMode.Store(2)
	stop()
	app = http.NewServeMux()
	stop = registerDroneguideSource(app, dir, wfs.Client(), wfs.URL)
	select {
	case <-inFlight:
	case <-time.After(3 * time.Second):
		t.Fatal("persisted live mode did not restart the refresh")
	}
	restartedLive := wait("loading")
	if !restartedLive.LiveEnabled || restartedLive.SourceType != "live" || restartedLive.Count != live.Count ||
		restartedLive.UpdatedAt == nil || !restartedLive.UpdatedAt.Equal(*live.UpdatedAt) {
		t.Fatalf("live restart replaced last good data: %+v", restartedLive)
	}
	manual = do(http.MethodPost, "/api/droneguide/import", droneguideGeoFixture, http.StatusOK)
	if manual.LiveEnabled || manual.SourceType != "import" || manual.Stale || manual.Count != 1 {
		t.Fatalf("valid import did not switch off live mode: %+v", manual)
	}
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("manual import did not cancel live request")
	}
	stop()
	app = http.NewServeMux()
	before := requests.Load()
	stop = registerDroneguideSource(app, dir, wfs.Client(), wfs.URL)
	restarted := wait("ready")
	if restarted.LiveEnabled || restarted.SourceType != "import" || restarted.SnapshotAt != nil ||
		restarted.Zones == nil || len(*restarted.Zones) != 1 || !restarted.UpdatedAt.Equal(*manual.UpdatedAt) || requests.Load() != before {
		t.Fatalf("manual restart requested live or lost import: %+v", restarted)
	}
}

func TestDroneguideWFSRetainsAreaAlongsideCollapsedGeometry(t *testing.T) {
	data := []byte(`{
		"type":"FeatureCollection",
		"features":[
			{
				"type":"Feature","id":"mixed","properties":{"restriction":"CONDITIONAL"},
				"geometry":{"type":"MultiPolygon","coordinates":[
					[[[4.31,50.81],[4.31,50.81],[4.31,50.81],[4.31,50.81]]],
					[
						[[4.30,50.80],[4.40,50.80],[4.35,50.86],[4.30,50.80]],
						[[4.33,50.81],[4.33,50.81],[4.33,50.81],[4.33,50.81]],
						[[4.34,50.81],[4.35,50.81],[4.35,50.82],[4.34,50.81]]
					]
				]}
			},
			{
				"type":"Feature","id":"empty","properties":{"restriction":"PROHIBITED"},
				"geometry":{"type":"Polygon","coordinates":[[[4.32,50.82],[4.32,50.82],[4.32,50.82],[4.32,50.82]]]}
			}
		]
	}`)
	zones, omitted, err := parseDroneguideSnapshot(data, true)
	if err != nil || omitted != 1 || len(zones) != 1 || len(zones[0].Polygons) != 1 ||
		len(zones[0].Polygons[0]) != 2 || zones[0].ID != "mixed" {
		t.Fatalf("lost valid geometry or omitted count: %+v, omitted %d, %v", zones, omitted, err)
	}
	if _, err := parseDroneguide(data); err == nil {
		t.Fatal("manual import accepted the collapsed geometry")
	}
	bad := []byte(strings.Replace(string(data), "[4.32,50.82]", "[220,50.82]", 1))
	if _, _, err := parseDroneguideSnapshot(bad, true); err == nil {
		t.Fatal("live parser accepted invalid coordinates")
	}
}
