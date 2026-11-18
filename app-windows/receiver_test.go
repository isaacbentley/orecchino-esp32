// SPDX-License-Identifier: GPL-3.0-only
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func receiverMessage(t *testing.T, line string) map[string]any {
	t.Helper()
	var message map[string]any
	if err := json.Unmarshal([]byte(line), &message); err != nil {
		t.Fatal(err)
	}
	return message
}

func TestReceiverRequiresProtocolBeforeConfirmation(t *testing.T) {
	r := NewReceiver()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	current := &receiverConnection{ctx: ctx, cancel: cancel}
	r.connection = current
	r.resetPortLocked("COM6")
	first := r.Snapshot()
	if first.Status != "waiting" {
		t.Fatalf("status before firmware: %s", first.Status)
	}
	if recognized, clock := r.ingestSerial(current, receiverMessage(t, `{"type":"boot","fw":"unrelated"}`), time.Now()); recognized || clock {
		t.Fatal("unrelated firmware promoted to Orecchino receiver")
	}
	if err := r.Send(map[string]any{"cmd": "log_clear"}); !errors.Is(err, errNoReceiver) {
		t.Fatalf("unrecognized receiver accepted a command: %v", err)
	}
	if recognized, clock := r.ingestSerial(current, receiverMessage(t, `{"type":"hb","up":100,"caps":["log","tiles"]}`), time.Now()); !recognized || !clock {
		t.Fatal("valid heartbeat did not request initial clock sync")
	}
	confirmed := r.Snapshot()
	if confirmed.Status != "receiving" || len(confirmed.Capabilities) != 2 || confirmed.Session != first.Session {
		t.Fatalf("bad confirmed snapshot: %+v", confirmed)
	}
	replies, unsubscribe := r.Subscribe()
	defer unsubscribe()
	if _, clock := r.ingestSerial(current, receiverMessage(t, `{"type":"hb","up":200,"rid":5}`), time.Now()); clock {
		t.Fatal("a routine heartbeat requested another clock sync")
	}
	r.ingestSerial(current, receiverMessage(t, `{"type":"fs_stat","free":2048}`), time.Now())
	select {
	case got := <-replies:
		if got["type"] != "fs_stat" || got["free"] != 2048.0 {
			t.Fatalf("bad device reply: %v", got)
		}
	default:
		t.Fatal("device reply was not forwarded")
	}
	if _, clock := r.ingestSerial(current, receiverMessage(t, `{"type":"boot","fw":"orecchino","ver":"0.7.0","board":"lilygo-t5"}`), time.Now()); !clock {
		t.Fatal("receiver reboot did not request clock sync")
	}
	restarted := r.Snapshot()
	if restarted.Session == confirmed.Session || restarted.Board != "lilygo-t5" || len(restarted.Capabilities) != 0 {
		t.Fatalf("bad restart snapshot: %+v", restarted)
	}
	if err := r.SendFor(confirmed.Session, map[string]any{"cmd": "log_get"}); !errors.Is(err, errSessionChanged) {
		t.Fatalf("old session accepted: %v", err)
	}
}

func TestTrackFusionAndNoFix(t *testing.T) {
	r := NewReceiver()
	now := time.Now().Add(-time.Second)
	r.ingestTrackLocked(receiverMessage(t, `{"type":"rid","mac":"aa:bb:cc:dd:ee:01","src":"ble","loc":{"lat":50.5,"lon":4.2,"status":2,"height":61,"height_ref":1}}`), now, false)
	id := r.Snapshot().Tracks[0].ID
	r.ingestTrackLocked(receiverMessage(t, `{"type":"rid","mac":"AA:BB:CC:DD:EE:01","src":"ble","basic_id":[{"uas_id":"1581F6Z9EXAMPLE","id_type":1,"ua_type":2}]}`), now.Add(100*time.Millisecond), false)
	r.ingestTrackLocked(receiverMessage(t, `{"type":"rid","mac":"AA:BB:CC:DD:EE:02","src":"wifi","basic_id":[{"uas_id":"1581F6Z9EXAMPLE","id_type":1,"ua_type":2}],"loc":{"lat":0.3,"lon":0.3,"status":3,"height":-1000},"auth":{"state":"test_key"}}`), now.Add(200*time.Millisecond), false)

	tracks := r.Snapshot().Tracks
	if len(tracks) != 1 {
		t.Fatalf("expected one fused track, got %d", len(tracks))
	}
	track := tracks[0]
	if track.ID != id || track.Model != "DJI Mini 4 Pro" || track.AuthState != "test_key" || track.Evidence != "BL···" || len(track.MACs) != 2 || len(track.Sources) != 2 {
		t.Fatalf("bad fused track: %+v", track)
	}
	if track.Lat == nil || *track.Lat != 50.5 || track.Height != nil || track.Status == nil || *track.Status != 3 {
		t.Fatalf("invalid RID fix or missing height rendered as location: %+v", track)
	}

	r.ingestTrackLocked(receiverMessage(t, `{"type":"rid","mac":"AA:BB:CC:DD:EE:02","src":"wifi","loc":{"lat":37.8,"lon":-122.4}}`), now.Add(300*time.Millisecond), false)
	track = r.Snapshot().Tracks[0]
	if len(track.Trail) != 1 || track.Trail[0].Lat != 37.8 {
		t.Fatalf("large jump should restart the trail: %+v", track.Trail)
	}
}

func TestDemoTracksRemainSeparateFromReceiver(t *testing.T) {
	r := NewReceiver()
	r.SetDemo(true)
	defer r.SetDemo(false)
	r.mu.Lock()
	r.ingestTrackLocked(receiverMessage(t, `{"mac":"DE:A0:00:00:00:01","basic_id":[{"uas_id":"1581F-DEMO-ALPHA","id_type":1,"ua_type":2}]}`), time.Now(), false)
	r.mu.Unlock()
	tracks := r.Snapshot().Tracks
	if len(tracks) != 3 {
		t.Fatalf("same ID and MAC merged real and simulated tracks: got %d", len(tracks))
	}
	r.SetDemo(false)
	tracks = r.Snapshot().Tracks
	if len(tracks) != 1 || tracks[0].Simulated {
		t.Fatalf("live track did not remain after disabling demo: %+v", tracks)
	}
}

func TestSerialLineBufferKeepsBoundaries(t *testing.T) {
	buffer := serialLineBuffer{}
	var lines []string
	appendLine := func(data []byte) { lines = append(lines, string(data)) }
	buffer.feed([]byte("first"), appendLine)
	buffer.feed([]byte(" line\nsecond\n"), appendLine)
	buffer.feed(bytes.Repeat([]byte{'x'}, receiverLineLimit+1), appendLine)
	buffer.feed([]byte("ignored suffix\nlast line\n"), appendLine)
	if len(lines) != 3 || lines[0] != "first line" || lines[1] != "second" || lines[2] != "last line" {
		t.Fatalf("bad serial framing: %q", lines)
	}
}
