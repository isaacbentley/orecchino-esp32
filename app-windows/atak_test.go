// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestATAKDestinationValidation(t *testing.T) {
	for _, host := range []string{"https://atak.local", "localhost:4242", "10.0.0.999", "224.0.0.1", "255.255.255.255", "::ffff:239.1.2.3", "ff02::1", "0.0.0.0", "::", "bad host", "-bad.example", "fe80::1%link\nname"} {
		config := atakSettings{Enabled: true, Host: host, Port: atakDefaultPort}
		if err := config.validate(); err == nil {
			t.Errorf("accepted invalid destination %q", host)
		}
	}
	for _, host := range []string{" localhost ", "Drone-Tak.example.", "192.168.1.42", "127.0.0.1", "[::1]", "fe80::1%7"} {
		config := atakSettings{Enabled: true, Host: host, Port: atakDefaultPort}
		if err := config.validate(); err != nil {
			t.Errorf("rejected direct destination %q: %v", host, err)
		}
	}
	for _, port := range []int{-1, 0, 65536} {
		config := atakSettings{Port: port}
		if err := config.validate(); err == nil {
			t.Errorf("accepted invalid UDP port %d", port)
		}
	}
}

func TestATAKUsesPositionObservationAndItsOwnHAE(t *testing.T) {
	at := time.Date(2026, 11, 19, 10, 30, 0, 123*int(time.Millisecond), time.FixedZone("BXL", 3600))
	track := Track{ID: "track-2", Title: "<operator name & address>", UasID: "SECRET-UAS", OperatorID: "SECRET-OP"}
	updateTrackLocation(&track, map[string]any{"lat": 50.85, "lon": 4.35, "alt_geo": 132.4}, at)
	updateTrackLocation(&track, map[string]any{"lat": 120.0, "lon": 140.0, "alt_geo": 444.5}, at.Add(time.Second))
	body, err := marshalATAKFix("0123456789abcdef0123456789abcdef", 2, track)
	if err != nil {
		t.Fatal(err)
	}
	var event atakEvent
	if err := xml.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	if event.UID != "orecchino-rid-0123456789abcdef0123456789abcdef-2" || event.Version != "2.0" ||
		event.Type != "a-u-A" || event.How != "m-r" || event.Access != "Undefined" || event.Contact.Callsign != "Orecchino UAS 2" {
		t.Fatalf("unusable event identity: %+v", event)
	}
	if event.Point != (atakPoint{Lat: "50.8500000", Lon: "4.3500000", HAE: "132.4", CE: atakUnknown, LE: atakUnknown}) {
		t.Fatalf("wrong CoT point: %+v", event.Point)
	}
	if event.Time != "2026-11-19T09:30:00.123Z" || event.Start != event.Time || event.Stale != "2026-11-19T09:31:00.123Z" {
		t.Fatalf("position validity changed: %+v", event)
	}
	for _, sensitive := range []string{"SECRET-UAS", "SECRET-OP", "operator name", "444.5"} {
		if strings.Contains(string(body), sensitive) {
			t.Fatalf("included unrelated data %q", sensitive)
		}
	}
	track.LastSeen = at.Add(atakFixLifetime)
	if !atakFixUsable(track, at.Add(atakFixLifetime-time.Nanosecond)) || atakFixUsable(track, track.LastSeen) {
		t.Fatal("late identity telemetry extended a position fix")
	}
	updateTrackLocation(&track, map[string]any{"lat": 50.85, "lon": 4.35, "height": 100.0, "alt_baro": 150.0}, at.Add(time.Minute))
	body, err = marshalATAKFix("0123456789abcdef0123456789abcdef", 2, track)
	if err != nil || xml.Unmarshal(body, &event) != nil || event.Point.HAE != atakUnknown {
		t.Fatalf("missing geodetic height was fabricated: %q (%v)", body, err)
	}

	r := NewReceiver()
	retained := Track{ID: "track-1"}
	updateTrackLocation(&track, map[string]any{"lat": 50.80, "lon": 4.31, "alt_geo": 54.5}, at.Add(2*time.Minute))
	r.mergeTrackLocked(&retained, &track)
	if retained.lastFix != track.lastFix || retained.lastFixHAE != track.lastFixHAE {
		t.Fatal("track merge disassociated the coordinate and altitude")
	}
}

func TestATAKLoopbackOnlySendsEnabledRealNewFixesAndPersists(t *testing.T) {
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.LocalAddr().(*net.UDPAddr).Port
	fix := time.Now().Add(-time.Second)
	real := Track{ID: "track-1", Title: "REAL-PRIVATE-REMOTE-ID", LastSeen: fix}
	sim := Track{ID: "track-2", Simulated: true, LastSeen: fix}
	old := Track{ID: "track-3", LastSeen: fix}
	unknown := Track{ID: "track-4", LastSeen: fix}
	updateTrackLocation(&real, map[string]any{"lat": 50.85, "lon": 4.35}, fix)
	updateTrackLocation(&sim, map[string]any{"lat": 50.9, "lon": 4.4}, fix)
	updateTrackLocation(&old, map[string]any{"lat": 50.8, "lon": 4.3}, fix.Add(-time.Minute))
	var mu sync.Mutex
	snapshot := func() ReceiverState {
		mu.Lock()
		defer mu.Unlock()
		return ReceiverState{Demo: true, Tracks: []Track{sim, old, unknown, real}}
	}
	dir := t.TempDir()
	mux := http.NewServeMux()
	stop := registerATAK(mux, dir, snapshot)
	defer func() { stop() }()
	action := func(method, body string, status int) atakView {
		t.Helper()
		r := httptest.NewRequest(method, "/api/atak", strings.NewReader(body))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s returned %d, expected %d: %s", method, r.URL, w.Code, status, w.Body)
		}
		var view atakView
		if status == http.StatusOK {
			if err := json.Unmarshal(w.Body.Bytes(), &view); err != nil {
				t.Fatal(err)
			}
		}
		return view
	}
	read := func(timeout time.Duration, wantEvent bool) atakEvent {
		t.Helper()
		if err := listener.SetReadDeadline(time.Now().Add(timeout)); err != nil {
			t.Fatal(err)
		}
		var data [2048]byte
		length, _, err := listener.ReadFromUDP(data[:])
		if !wantEvent {
			var netError net.Error
			if !errors.As(err, &netError) || !netError.Timeout() {
				t.Fatalf("unexpected datagram: %q (%v)", data[:length], err)
			}
			return atakEvent{}
		}
		if err != nil {
			t.Fatalf("did not receive UDP CoT: %v", err)
		}
		var event atakEvent
		if err := xml.Unmarshal(data[:length], &event); err != nil {
			t.Fatalf("malformed UDP datagram: %q: %v", data[:length], err)
		}
		return event
	}

	before := action(http.MethodGet, "", http.StatusOK)
	if before.Enabled || before.Host != "" || before.Port != atakDefaultPort || before.State != "off" {
		t.Fatalf("unexpected default settings: %+v", before)
	}
	off := fmt.Sprintf(`{"enabled":false,"host":"127.0.0.1","port":%d}`, port)
	on := fmt.Sprintf(`{"enabled":true,"host":"127.0.0.1","port":%d}`, port)
	action(http.MethodPost, off, http.StatusOK)
	read(350*time.Millisecond, false)
	action(http.MethodPost, `{"enabled":true,"host":"239.1.2.3","port":4242}`, http.StatusBadRequest)
	action(http.MethodPost, on, http.StatusOK)
	first := read(3*time.Second, true)
	if first.Contact.Callsign != "Orecchino UAS 1" || first.Time != fix.UTC().Format(atakTimestamp) {
		t.Fatalf("exported unexpected track or changed fix time: %+v", first)
	}
	after := action(http.MethodGet, "", http.StatusOK)
	if after.State != "ready" || after.Sent != 1 || after.LastSentAt == nil {
		t.Fatalf("wrong local delivery status: %+v", after)
	}
	read(350*time.Millisecond, false)

	mu.Lock()
	nextFix := time.Now()
	updateTrackLocation(&real, map[string]any{"lat": 50.86, "lon": 4.36}, nextFix)
	mu.Unlock()
	read(400*time.Millisecond, false)
	second := read(3*time.Second, true)
	if second.UID != first.UID || second.Time != nextFix.UTC().Format(atakTimestamp) || second.Point.Lat != "50.8600000" {
		t.Fatalf("new fix did not preserve the track identity: %+v", second)
	}

	action(http.MethodPost, off, http.StatusOK)
	stop()
	mux = http.NewServeMux()
	stop = registerATAK(mux, dir, snapshot)
	persisted := action(http.MethodGet, "", http.StatusOK)
	if persisted.Enabled || persisted.Host != "127.0.0.1" || persisted.Port != port || persisted.Sent != 0 {
		t.Fatalf("opt-out changed after restart: %+v", persisted)
	}
	mu.Lock()
	updateTrackLocation(&real, map[string]any{"lat": 50.87, "lon": 4.37}, time.Now())
	mu.Unlock()
	read(350*time.Millisecond, false)
}
