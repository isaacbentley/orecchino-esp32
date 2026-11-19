// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDroneguideImportedActivityExplicitBounds(t *testing.T) {
	now := time.Date(2026, 11, 17, 22, 30, 0, 0, time.UTC)
	from, until := now.Format(time.RFC3339), now.Add(time.Hour).Format(time.RFC3339)
	view := droneguideView{}
	tests := []struct {
		name string
		zone droneguideZone
		at   time.Time
		want droneguideActivity
	}{
		{"unknown without validity", droneguideZone{}, now, droneguideActivityUnknown},
		{"starts inclusively", droneguideZone{ValidFrom: from, ValidUntil: until}, now, droneguideActivityActive},
		{"ends exclusively", droneguideZone{ValidFrom: from, ValidUntil: until}, now.Add(time.Hour), droneguideActivityInactive},
		{"single bound can rule out", droneguideZone{ValidFrom: from}, now.Add(-time.Second), droneguideActivityInactive},
		{"single bound cannot confirm activity", droneguideZone{ValidFrom: from}, now, droneguideActivityUnknown},
		{"free-text schedule limits certainty", droneguideZone{ValidFrom: from, ValidUntil: until, Schedule: "By arrangement"}, now, droneguideActivityUnknown},
		{"no implicit timezone", droneguideZone{ValidFrom: "2026-11-17T22:00:00", ValidUntil: until}, now, droneguideActivityUnknown},
		{"explicit permanence", droneguideZone{Applicability: []droneguidePeriod{{Permanent: "YES"}}}, now, droneguideActivityActive},
		{"temporary without dates", droneguideZone{Applicability: []droneguidePeriod{{Permanent: "NO"}}}, now, droneguideActivityUnknown},
		{"union includes known active against unknown", droneguideZone{Applicability: []droneguidePeriod{{Permanent: "NO"}, {Permanent: "YES"}}}, now, droneguideActivityActive},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := droneguideZoneActivity(tc.zone, view, tc.at); got != tc.want {
				t.Errorf("activity %s, want %s", got.label(), tc.want.label())
			}
		})
	}
}

func TestDroneguideDailyActivityUsesWeekdayInExplicitOffset(t *testing.T) {
	overnight := droneguideDailyPeriod{Day: []string{"TUE"}, StartTime: "23:00:00+02:00", EndTime: "01:00:00+02:00"}
	zone := droneguideZone{Applicability: []droneguidePeriod{{Permanent: "YES", Schedule: []droneguideDailyPeriod{overnight}}}}
	// Tuesday 22:30 UTC is Wednesday 00:30 at the schedule's UTC+02:00.
	now := time.Date(2026, 11, 17, 22, 30, 0, 0, time.UTC)
	if got := droneguideZoneActivity(zone, droneguideView{}, now); got != droneguideActivityActive {
		t.Fatalf("overnight schedule activity %s", got.label())
	}
	if got := droneguideZoneActivity(zone, droneguideView{}, now.Add(30*time.Minute)); got != droneguideActivityInactive {
		t.Fatalf("ended daily period activity %s", got.label())
	}
	notTimed := overnight
	notTimed.StartTime = "23:00:00"
	if got := droneguideDailyActivity(notTimed, now); got != droneguideActivityUnknown {
		t.Fatalf("schedule without timezone activity %s", got.label())
	}
	notTimed.StartTime = "23:00:00+01:00"
	if got := droneguideDailyActivity(notTimed, now); got != droneguideActivityUnknown {
		t.Fatalf("schedule with different offsets activity %s", got.label())
	}
}

func TestDroneguideSnapshotActivityRevisionTracksTimeAndStaleness(t *testing.T) {
	now := time.Date(2026, 11, 17, 22, 30, 0, 0, time.UTC)
	active, inactive := true, false
	service := droneguideService{config: droneguideDiskState{LiveEnabled: true}, state: "ready", revision: 1}
	service.shown = &droneguideSnapshot{SnapshotAt: &now, Zones: []droneguideZone{
		{ID: "active", ActiveAtSnapshot: &active}, {ID: "inactive", ActiveAtSnapshot: &inactive}, {ID: "unknown"},
	}}
	fresh := service.snapshot(true, now)
	stale := service.snapshot(true, now.Add(30*time.Minute))
	if fresh.Stale || fresh.ActiveCount != 1 || fresh.UnknownActivityCount != 1 ||
		(*fresh.Zones)[0].Activity != "active" || (*fresh.Zones)[1].Activity != "inactive" {
		t.Fatalf("fresh online activity: %+v", fresh)
	}
	if !stale.Stale || stale.ActiveCount != 0 || stale.UnknownActivityCount != 3 ||
		(*stale.Zones)[0].Activity != "unknown" || stale.Revision != fresh.Revision || stale.ActivityRevision <= fresh.ActivityRevision {
		t.Fatalf("stale online activity: %+v", stale)
	}
	service.state = "error"
	failed := service.snapshot(true, now.Add(time.Minute))
	if !failed.Stale || failed.ActiveCount != 0 || failed.UnknownActivityCount != 3 {
		t.Fatalf("failed refresh retained active status: %+v", failed)
	}
	service.state = "ready"
	service.shown = &droneguideSnapshot{Zones: []droneguideZone{
		{ID: "first", ValidFrom: now.Format(time.RFC3339), ValidUntil: now.Add(time.Minute).Format(time.RFC3339)},
		{ID: "second", ValidFrom: now.Add(time.Minute).Format(time.RFC3339), ValidUntil: now.Add(2 * time.Minute).Format(time.RFC3339)},
	}}
	first := service.snapshot(true, now)
	second := service.snapshot(true, now.Add(time.Minute))
	if first.ActiveCount != 1 || second.ActiveCount != 1 || second.ActivityRevision <= first.ActivityRevision ||
		second.Revision != first.Revision || (*second.Zones)[0].Activity != "inactive" || (*second.Zones)[1].Activity != "active" {
		t.Fatalf("wall-clock transition failed to update same-count state: before %+v, after %+v", first, second)
	}
}

func TestDroneguideActiveOnlyPreferenceIsIndependentAndPersistent(t *testing.T) {
	dir := t.TempDir()
	mux := http.NewServeMux()
	stop := registerDroneguide(mux, dir)
	action := func(method, path, data string, want int) droneguideView {
		t.Helper()
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(data)))
		if w.Code != want {
			t.Fatalf("%s %s status %d wanted %d; %s", method, path, w.Code, want, w.Body)
		}
		var view droneguideView
		if w.Code == http.StatusOK {
			if err := json.Unmarshal(w.Body.Bytes(), &view); err != nil {
				t.Fatal(err)
			}
		}
		return view
	}
	initial := action(http.MethodGet, "/api/droneguide?zones=0", "", http.StatusOK)
	if initial.ActiveOnly || initial.LiveEnabled {
		t.Fatalf("unexpected defaults %+v", initial)
	}
	action(http.MethodPost, "/api/droneguide/filter", `{}`, http.StatusBadRequest)
	action(http.MethodPost, "/api/droneguide/filter", `{"activeOnly":true}`, http.StatusOK)
	got := action(http.MethodPost, "/api/droneguide/import", droneguideEDFixture, http.StatusOK)
	if !got.ActiveOnly || got.LiveEnabled || got.Count != 2 {
		t.Fatalf("import changed filter or altitude scope %+v", got)
	}
	stop()
	mux = http.NewServeMux()
	defer registerDroneguide(mux, dir)()
	got = action(http.MethodGet, "/api/droneguide", "", http.StatusOK)
	if !got.ActiveOnly || got.LiveEnabled || got.Zones == nil || len(*got.Zones) != 2 {
		t.Fatalf("settings restart lost data %+v", got)
	}
	got = action(http.MethodPost, "/api/droneguide/filter", `{"activeOnly":false}`, http.StatusOK)
	if got.ActiveOnly || got.Count != 2 {
		t.Fatalf("all-zone mode removed source geometry %+v", got)
	}
}
