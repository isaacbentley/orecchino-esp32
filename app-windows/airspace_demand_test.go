// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later.
package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAirTrafficDemand(t *testing.T) {
	for _, test := range []struct {
		name                            string
		enabled, demo, area, mapVisible bool
		drones                          []airDrone
		want                            airTrafficDemand
	}{
		{name: "idle", enabled: true, area: true},
		{name: "visible map", enabled: true, area: true, mapVisible: true, want: airMapDemand},
		{name: "hidden map, drone has no coordinates", enabled: true, area: true,
			drones: []airDrone{{Live: true}}, want: airDroneDemand},
		{name: "visible map and live drone", enabled: true, area: true, mapVisible: true,
			drones: []airDrone{{Live: true}}, want: airDroneDemand},
		{name: "visible map and expired drone", enabled: true, area: true, mapVisible: true,
			drones: []airDrone{{Live: false}}, want: airMapDemand},
		{name: "hidden map and expired drone", enabled: true, area: true,
			drones: []airDrone{{Live: false}}},
		{name: "no area", enabled: true, mapVisible: true, drones: []airDrone{{Live: true}}},
		{name: "off", area: true, mapVisible: true, drones: []airDrone{{Live: true}}},
		{name: "demo", enabled: true, demo: true, area: true, mapVisible: true, drones: []airDrone{{Live: true}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := airDemandFor(test.enabled, test.demo, test.area, test.mapVisible, test.drones); got != test.want {
				t.Fatalf("demand = %d, want %d", got, test.want)
			}
		})
	}
}

func TestAirTrafficCadenceTransitions(t *testing.T) {
	at := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	run := airTrafficRun{LastAttempt: at}
	run.updateDemand(airNoDemand, false)
	if run.due(at.Add(time.Hour)) {
		t.Fatal("idle state must not poll")
	}
	run.updateDemand(airMapDemand, false)
	if run.due(at.Add(29*time.Second)) || !run.due(at.Add(30*time.Second)) {
		t.Fatalf("map-only cadence should be 30 seconds, next %v", run.nextFetch())
	}
	run.updateDemand(airDroneDemand, true)
	if !run.due(at.Add(5 * time.Second)) {
		t.Fatal("first live drone did not expedite the map-only request")
	}

	at = at.Add(5 * time.Second)
	run.LastAttempt = at
	run.updateDemand(airDroneDemand, false)
	if run.due(at.Add(9*time.Second)) || !run.due(at.Add(10*time.Second)) {
		t.Fatalf("drone cadence should be 10 seconds, next %v", run.nextFetch())
	}
	run.updateDemand(airMapDemand, false)
	if run.due(at.Add(10*time.Second)) || !run.due(at.Add(30*time.Second)) {
		t.Fatalf("losing the only live drone while map visible should switch to 30 seconds, next %v", run.nextFetch())
	}

	run.LastAttempt = at
	run.updateDemand(airDroneDemand, true)
	run.LastAttempt = at
	// If the new RID crosses the 60-second gap between scheduler ticks, the
	// receiver's epoch still tells a run with the same old demand to expedite.
	run.updateDemand(airDroneDemand, true)
	if !run.due(at.Add(time.Second)) {
		t.Fatal("missed the new first live drone while demand still read drone")
	}
}

func TestAirTrafficKeepsRetryAfterAcrossIdleAndSameSourceChanges(t *testing.T) {
	at := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	const source = "adsb"
	states := airTrafficRun{LastAttempt: at, Inflight: true, FetchID: 1, Demand: airMapDemand}
	states.CancelFetch = func() { t.Error("going idle canceled the in-flight request") }
	states.updateDemand(airNoDemand, false)
	if !states.Inflight {
		t.Fatal("idle transition lost the in-flight slot")
	}
	states.CancelFetch = func() {}
	deadline := at.Add(90 * time.Second)
	states.accept(airFetchResult{Source: source, Generation: 1,
		Err: airFetchHTTPError{Status: http.StatusTooManyRequests, RetryAt: deadline}},
		at.Add(time.Second), airNoDemand, source)
	if states.Inflight || states.RetryAt != deadline {
		t.Fatalf("idle request completion lost the retry deadline: %+v", states)
	}
	states.updateDemand(airMapDemand, false)
	if states.due(at.Add(89*time.Second)) || !states.due(deadline) {
		t.Fatalf("reopened map bypassed Retry-After: next %v", states.nextFetch())
	}
	states.reset(true)
	states.updateDemand(airDroneDemand, true)
	if states.due(at.Add(89*time.Second)) || !states.due(deadline) {
		t.Fatalf("same-source reset or first drone bypassed Retry-After: next %v", states.nextFetch())
	}
	states.reset(false)
	states.updateDemand(airMapDemand, false)
	if !states.due(at.Add(time.Second)) {
		t.Fatal("new source inherited the old source's rate limit")
	}
}

func TestAirTrafficDoesNotPublishIdleResponse(t *testing.T) {
	at := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	area := airArea{Center: GeoPoint{Lat: 50, Lon: 4}, RadiusM: 10000}
	oldData := at.Add(-5 * time.Second)
	run := airTrafficRun{Received: oldData, LastAttempt: at, Inflight: true, FetchID: 1}
	run.accept(airFetchResult{
		Aircraft: []airAircraft{{ID: "a1b2c3", Point: area.Center, Seen: at}},
		Area:     area, Generation: 1,
	}, at, airNoDemand, "")
	if run.Inflight || run.Received != oldData || len(run.Aircraft) != 0 {
		t.Fatalf("idle response changed cached traffic: %+v", run)
	}
}

type demandRoundTripper func(*http.Request) (*http.Response, error)

func (f demandRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestAirTrafficCancellationRetainsSingleFlightUntilExit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan struct{})
	canceled := make(chan struct{})
	release := make(chan struct{}, 1)
	defer func() {
		select {
		case release <- struct{}{}:
		default:
		}
	}()
	client := &http.Client{Transport: demandRoundTripper(func(request *http.Request) (*http.Response, error) {
		close(started)
		<-request.Context().Done()
		close(canceled)
		<-release
		return nil, request.Context().Err()
	})}
	run := airTrafficRun{}
	run.updateDemand(airMapDemand, false)
	results := make(chan airFetchResult, 1)
	at := time.Now()
	run.fetch(ctx, client, results, defaultTrafficSource, airArea{RadiusM: 10000}, at)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	run.reset(true)
	run.updateDemand(airDroneDemand, false)
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("reset did not cancel the old request")
	}
	if run.due(at.Add(time.Minute)) {
		t.Fatal("another request can start while the canceled request is still exiting")
	}

	// Let the canceled worker exit, then verify it cannot populate the new
	// run or back off from the deliberate cancellation.
	release <- struct{}{}
	select {
	case got := <-results:
		run.accept(got, at.Add(time.Minute), airDroneDemand, defaultTrafficSource)
	case <-time.After(time.Second):
		t.Fatal("canceled request did not release the in-flight slot")
	}
	if run.Failures != 0 || !run.Received.IsZero() || !run.due(at.Add(time.Minute)) {
		t.Fatalf("canceled request changed the new run: %+v", run)
	}
}

func TestAirFetchRespectsRetryAfter(t *testing.T) {
	at := time.Date(2026, 11, 21, 23, 58, 0, 0, time.UTC)
	wantDate := at.Add(10 * time.Second)
	if got := airRetryAfter(" 20 ", at, true); got != at.Add(20*time.Second) {
		t.Errorf("delta retry = %v", got)
	}
	if got := airRetryAfter(wantDate.Format(http.TimeFormat), at, true); !got.Equal(wantDate) {
		t.Errorf("HTTP date retry = %v", got)
	}
	for _, invalid := range []string{"", "bad", "99999999999999999999999999", at.Add(-time.Second).Format(http.TimeFormat)} {
		if got := airRetryAfter(invalid, at, true); got != at.Add(2*time.Minute) {
			t.Errorf("daily retry for %q = %v", invalid, got)
		}
		if got := airRetryAfter(invalid, at, false); !got.IsZero() {
			t.Errorf("custom source retry for %q = %v", invalid, got)
		}
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "91")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()
	start := time.Now()
	_, err := airFetch(context.Background(), server.Client(), server.URL+"/{lat}/{lon}/{radius}",
		airArea{Center: GeoPoint{Lat: 50, Lon: 4}, RadiusM: 10000})
	var status airFetchHTTPError
	if !errors.As(err, &status) || status.Status != http.StatusTooManyRequests ||
		status.RetryAt.Before(start.Add(91*time.Second)) ||
		status.RetryAt.After(time.Now().Add(91*time.Second)) {
		t.Fatalf("HTTP request did not propagate Retry-After: %+v %v", status, err)
	}
}

func TestAirMapVisibilityIsLeased(t *testing.T) {
	service := &airspaceService{wakeTraffic: make(chan struct{}, 1)}
	post := func(body string) int {
		request := httptest.NewRequest(http.MethodPost, "/api/airspace/map-visibility", strings.NewReader(body))
		response := httptest.NewRecorder()
		service.setMapVisibility(response, request)
		return response.Code
	}
	at := time.Now()
	if post(`{"visible":true}`) != http.StatusNoContent ||
		service.mapVisibleUntil.Before(at.Add(airMapVisibilityLease)) ||
		service.mapVisibleUntil.After(time.Now().Add(airMapVisibilityLease)) {
		t.Fatalf("did not set the visibility lease: %v", service.mapVisibleUntil)
	}
	if len(service.wakeTraffic) != 1 {
		t.Fatal("opening the map did not wake the scheduler")
	}
	<-service.wakeTraffic
	if post(`{"visible":true}`) != http.StatusNoContent || len(service.wakeTraffic) != 0 {
		t.Fatal("a heartbeat should renew visibility without an extra scheduler wake")
	}
	if post(`{"visible":false}`) != http.StatusNoContent ||
		!service.mapVisibleUntil.IsZero() || len(service.wakeTraffic) != 1 {
		t.Fatal("closing the map did not revoke visibility and wake the scheduler")
	}
	if post(`{}`) != http.StatusBadRequest {
		t.Fatal("missing visibility accepted")
	}
}

func TestAirTrafficWakeTracksAcceptedLiveContactsWithoutCoordinates(t *testing.T) {
	receiver := NewReceiver()
	now := time.Now()
	message := map[string]any{"mac": "AA:BB:CC:DD:EE:FF"}
	receiver.ingestTrackLocked(message, now, true)
	receiver.ingestTrackLocked(map[string]any{}, now, false)
	if len(receiver.trafficWake) != 0 || receiver.Snapshot().liveRIDEpoch != 0 {
		t.Fatal("simulated or rejected packet woke ADS-B")
	}
	receiver.ingestTrackLocked(message, now, false)
	snapshot := receiver.Snapshot()
	if len(receiver.trafficWake) != 1 || snapshot.liveRIDEpoch != 1 ||
		airDemandFor(true, false, true, false, airDrones(snapshot.Tracks, false)) != airDroneDemand {
		t.Fatalf("accepted positionless observation did not wake ADS-B: %+v", snapshot)
	}
	<-receiver.trafficWake
	receiver.ingestTrackLocked(message, now.Add(time.Second), false)
	if len(receiver.trafficWake) != 0 {
		t.Fatal("continuously live RID packet should not expedite repeated requests")
	}
	receiver.ingestTrackLocked(message, now.Add(62*time.Second), false)
	if len(receiver.trafficWake) != 1 || receiver.Snapshot().liveRIDEpoch != 2 {
		t.Fatal("first live RID after a 60-second gap did not wake ADS-B")
	}
}
