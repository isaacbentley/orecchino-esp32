// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/csv"
	"fmt"
	"hash/crc32"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type mockDevice struct {
	inbox  chan map[string]any
	onSend func(map[string]any) error
}

func (d *mockDevice) Snapshot() ReceiverState {
	return ReceiverState{Port: "COM5", Status: "receiving", Session: 1}
}

func (d *mockDevice) SendFor(session uint64, command any) error {
	if session != 1 {
		return fmt.Errorf("unexpected session %d", session)
	}
	return d.onSend(command.(map[string]any))
}

func (d *mockDevice) Subscribe() (<-chan map[string]any, func()) {
	d.inbox = make(chan map[string]any, 20)
	return d.inbox, func() { close(d.inbox) }
}

func (d *mockDevice) queue(lines ...map[string]any) {
	for _, line := range lines {
		d.inbox <- line
	}
}

func TestDeviceLogTracksClearAndRereadsFromOldest(t *testing.T) {
	mock := &mockDevice{}
	dir := t.TempDir()
	d := newDeviceAPI(mock, dir)
	commands := make([]map[string]any, 0, 4)
	mock.onSend = func(command map[string]any) error {
		commands = append(commands, command)
		switch len(commands) {
		case 1:
			mock.queue(
				map[string]any{"type": "log", "active": false, "mac": "first", "seq": float64(4), "last": float64(1790001234)},
				map[string]any{"type": "log", "active": true, "mac": "live"},
				map[string]any{"type": "log_done", "log_id": float64(10), "next": float64(5), "oldest": float64(4), "clock": true},
			)
		case 2:
			mock.queue(map[string]any{"type": "log_done", "log_id": float64(11), "next": float64(15), "oldest": float64(14), "clock": false})
		case 3:
			mock.queue(
				map[string]any{"type": "log", "active": false, "mac": "new", "seq": float64(14)},
				map[string]any{"type": "log_done", "log_id": float64(11), "next": float64(15), "oldest": float64(14), "clock": false},
			)
		case 4:
			mock.queue(map[string]any{"type": "log_cleared", "log_id": float64(12)})
		default:
			return fmt.Errorf("unexpected command %v", command)
		}
		return nil
	}
	request := httptest.NewRequest(http.MethodPost, "/api/device/log/read", nil)
	first := httptest.NewRecorder()
	d.readLog(first, request)
	if first.Code != http.StatusOK || len(d.logSnapshot().Entries) != 2 || deviceString(d.logSnapshot().Entries[0], "mac") != "live" {
		t.Fatalf("first read failed: %d %s", first.Code, first.Body)
	}

	// Reloading the app retains the cursor. A different log_id forces a full
	// refresh from oldest even if that receiver's total passed the old cursor.
	d = newDeviceAPI(mock, dir)
	second := httptest.NewRecorder()
	d.readLog(second, request)
	if second.Code != http.StatusOK || commands[1]["since"] != int64(5) || commands[2]["since"] != int64(14) {
		t.Fatalf("incremental restart failed: %d %s, %v", second.Code, second.Body, commands)
	}
	log := d.logSnapshot()
	if log.ClockSet || log.Missed != 14 || len(log.Entries) != 1 || deviceString(log.Entries[0], "mac") != "new" {
		t.Fatalf("unexpected restarted log: %+v", log)
	}

	cleared := httptest.NewRecorder()
	d.clearLog(cleared, httptest.NewRequest(http.MethodPost, "/api/device/log/clear", nil))
	log = newDeviceAPI(mock, dir).logSnapshot()
	if cleared.Code != http.StatusOK || !log.ClearedSinceRead || log.Total != 0 || len(log.Entries) != 1 || intValue(log.Cursor, -1) != 0 {
		t.Fatalf("clear lost the local cache or cursor: %d %s %+v", cleared.Code, cleared.Body, log)
	}
}

func TestDeviceCSVProtectsFormulaCells(t *testing.T) {
	var buf bytes.Buffer
	entries := []map[string]any{{
		"active": true, "uas": "  =SAMPLE()", "mac": "aa:bb", "srcs": float64(5),
		"first": float64(1790000000), "lat": float64(37.8039),
		"class_type": float64(1), "cat_eu": float64(2), "class_eu": float64(3),
	}}
	if err := writeMatchLogCSV(&buf, entries); err != nil {
		t.Fatal(err)
	}
	rows, err := csv.NewReader(&buf).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[1][1] != "'  =SAMPLE()" || rows[1][3] != "Wi-Fi + BLE" || rows[1][4] != "2026-09-21T14:13:20Z" || rows[1][7] != "37.80390" || rows[1][15] != "EU · Specific · C2" {
		t.Fatalf("unexpected CSV rows: %+v", rows)
	}
}

func TestDeviceTileTransferUsesNumberedChunksAndCRC(t *testing.T) {
	mock := &mockDevice{}
	path := "/tiles/12/100/200.jpg"
	data := bytes.Repeat([]byte{1, 2, 3, 4}, 500)
	var uploaded bytes.Buffer
	sequence := 0
	mock.onSend = func(command map[string]any) error {
		switch command["cmd"] {
		case "fs_begin":
			if command["p"] != path || command["size"] != len(data) {
				return fmt.Errorf("wrong fs_begin: %v", command)
			}
			mock.queue(map[string]any{"type": "ack", "q": float64(0)})
		case "fs_data":
			sequence++
			raw, err := base64.StdEncoding.DecodeString(command["b64"].(string))
			if err != nil || len(raw) > tileChunkSize || command["q"] != sequence {
				return fmt.Errorf("invalid fs_data sequence or size: %d", sequence)
			}
			uploaded.Write(raw)
			mock.queue(
				map[string]any{"type": "ack", "q": float64(sequence - 1)},
				map[string]any{"type": "ack", "q": float64(sequence)},
			)
		case "fs_end":
			if command["crc"] != crc32.ChecksumIEEE(data) {
				return fmt.Errorf("incorrect checksum: %v", command)
			}
			mock.queue(
				map[string]any{"type": "fs_ok", "p": "/tiles/12/999/999.jpg"},
				map[string]any{"type": "fs_ok", "p": path},
			)
		default:
			return fmt.Errorf("unexpected command %v", command)
		}
		return nil
	}
	d := newDeviceAPI(mock, t.TempDir())
	link, err := d.openLink()
	if err != nil {
		t.Fatal(err)
	}
	defer link.close()
	if err := uploadTile(context.Background(), link, path, data); err != nil {
		t.Fatal(err)
	}
	if sequence != 3 || !bytes.Equal(uploaded.Bytes(), data) {
		t.Fatalf("expected 3 chunks for original data, received %d of %d bytes", sequence, uploaded.Len())
	}
}

func TestDeviceRejectsIncompleteTileInventory(t *testing.T) {
	mock := &mockDevice{}
	mock.onSend = func(command map[string]any) error {
		switch command["cmd"] {
		case "fs_stat":
			mock.queue(map[string]any{"type": "fs_stat", "total": float64(8 * 1024 * 1024), "used": float64(1024)})
		case "fs_ls":
			mock.queue(map[string]any{"type": "fs_ls_done", "n": float64(1)})
		default:
			return fmt.Errorf("unexpected command %v", command)
		}
		return nil
	}
	d := newDeviceAPI(mock, t.TempDir())
	input := strings.NewReader(`{"lat":50.85,"lon":4.35,"radiusKm":3}`)
	result := httptest.NewRecorder()
	d.planTilesHTTP(result, httptest.NewRequest(http.MethodPost, "/api/device/tiles/plan", input))
	if result.Code != http.StatusBadGateway || !strings.Contains(result.Body.String(), "onvolledig") {
		t.Fatalf("expected incomplete inventory to fail, got %d %s", result.Code, result.Body)
	}
}
