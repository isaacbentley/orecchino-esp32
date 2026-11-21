// Orecchino Windows adaptation of the receiver match log in DeviceLog.swift.
// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	errDeviceBusy         = errors.New("de ontvanger voert al een bewerking uit")
	errDeviceDisconnected = errors.New("verbinding met de ontvanger verbroken")
	errDeviceTimeout      = errors.New("de ontvanger reageert niet")
)

type deviceReceiver interface {
	Snapshot() ReceiverState
	SendFor(session uint64, command any) error
	Subscribe() (<-chan map[string]any, func())
}

type deviceAPI struct {
	receiver deviceReceiver
	dataDir  string

	operation sync.Mutex
	logMu     sync.RWMutex
	matchLog  matchLogState
	lastClear *int64

	tilesMu sync.RWMutex
	tiles   tileState
}

func registerDevice(mux *http.ServeMux, receiver *Receiver, dataDir string) {
	device := newDeviceAPI(receiver, dataDir)
	lines, _ := receiver.Subscribe()
	go func() {
		for message := range lines {
			if deviceString(message, "type") == "log_cleared" {
				snapshot := receiver.Snapshot()
				device.recordClear(snapshot.Port, deviceInt(message, "log_id"))
			}
		}
	}()
	mux.HandleFunc("GET /api/device/log", device.cachedLog)
	mux.HandleFunc("POST /api/device/log/read", device.readLog)
	mux.HandleFunc("POST /api/device/log/clear", device.clearLog)
	mux.HandleFunc("GET /api/device/log.csv", device.exportLog)
	mux.HandleFunc("POST /api/device/tiles/plan", device.planTilesHTTP)
	mux.HandleFunc("POST /api/device/tiles/send", device.sendTilesHTTP)
	mux.HandleFunc("GET /api/device/tiles/status", device.tileStatusHTTP)
}

func newDeviceAPI(receiver deviceReceiver, dataDir string) *deviceAPI {
	device := &deviceAPI{receiver: receiver, dataDir: dataDir, tiles: tileState{Phase: "idle"}}
	device.matchLog = matchLogState{Entries: []map[string]any{}, ClockSet: true}
	if data, err := os.ReadFile(device.logPath()); err == nil {
		var loaded matchLogState
		if json.Unmarshal(data, &loaded) == nil && loaded.Entries != nil {
			device.matchLog = loaded
			if loaded.ClearedSinceRead {
				device.lastClear = loaded.LogID
			}
		}
	}
	return device
}

func deviceJSON(w http.ResponseWriter, status int, response any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(response)
}

func deviceError(w http.ResponseWriter, err error) {
	code := http.StatusBadGateway
	switch {
	case errors.Is(err, errDeviceBusy), errors.Is(err, errDeviceDisconnected):
		code = http.StatusConflict
	case errors.Is(err, errDeviceTimeout):
		code = http.StatusGatewayTimeout
	}
	deviceJSON(w, code, map[string]string{"error": err.Error()})
}

func deviceString(m map[string]any, key string) string {
	value, _ := m[key].(string)
	return value
}

func deviceBool(m map[string]any, key string) bool {
	value, _ := m[key].(bool)
	return value
}

func deviceNumber(m map[string]any, key string) (float64, bool) {
	value, ok := m[key].(float64)
	return value, ok
}

func deviceInt(m map[string]any, key string) *int64 {
	value, ok := deviceNumber(m, key)
	if !ok || value < -9_007_199_254_740_991 || value > 9_007_199_254_740_991 || value != float64(int64(value)) {
		return nil
	}
	n := int64(value)
	return &n
}

func intValue(value *int64, fallback int64) int64 {
	if value == nil {
		return fallback
	}
	return *value
}

// deviceLink keeps commands and responses bound to a single confirmed USB connection.
type deviceLink struct {
	receiver deviceReceiver
	state    ReceiverState
	lines    <-chan map[string]any
	stop     func()
	// A periodic check lets a disconnect interrupt a slow receiver operation.
	ticker *time.Ticker
}

func (d *deviceAPI) openLink() (*deviceLink, error) {
	state := d.receiver.Snapshot()
	if state.Status != "receiving" || state.Port == "" {
		return nil, errDeviceDisconnected
	}
	lines, stop := d.receiver.Subscribe()
	return &deviceLink{d.receiver, state, lines, stop, time.NewTicker(250 * time.Millisecond)}, nil
}

func (l *deviceLink) close() {
	l.ticker.Stop()
	l.stop()
}

func (l *deviceLink) send(command map[string]any) error {
	return l.receiver.SendFor(l.state.Session, command)
}

func (l *deviceLink) valid() bool {
	return l.receiver.Snapshot().Session == l.state.Session
}

func (l *deviceLink) receive(ctx context.Context, timeout time.Duration, accept func(map[string]any) bool) (map[string]any, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
			return nil, errDeviceTimeout
		case <-l.ticker.C:
			if !l.valid() {
				return nil, errDeviceDisconnected
			}
		case message, ok := <-l.lines:
			if !ok || !l.valid() {
				return nil, errDeviceDisconnected
			}
			if accept(message) {
				return message, nil
			}
		}
	}
}

type matchLogState struct {
	Entries          []map[string]any `json:"entries"`
	Total            int64            `json:"total"`
	Missed           int64            `json:"missed"`
	ClockSet         bool             `json:"clockSet"`
	ClearedSinceRead bool             `json:"clearedSinceRead"`
	Port             string           `json:"port,omitempty"`
	Cursor           *int64           `json:"cursor,omitempty"`
	LogID            *int64           `json:"logId,omitempty"`
}

func (d *deviceAPI) logPath() string {
	return filepath.Join(d.dataDir, "receiver-log.json")
}

func (d *deviceAPI) logSnapshot() matchLogState {
	d.logMu.RLock()
	defer d.logMu.RUnlock()
	return d.matchLog
}

func (d *deviceAPI) cachedLog(w http.ResponseWriter, _ *http.Request) {
	deviceJSON(w, http.StatusOK, d.logSnapshot())
}

func (d *deviceAPI) persistLog(state matchLogState) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return writeDeviceFile(d.logPath(), data)
}

func writeDeviceFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, ".orecchino-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

func (d *deviceAPI) recordClear(port string, logID *int64) {
	d.logMu.Lock()
	defer d.logMu.Unlock()
	if port == "" || d.matchLog.Port != port {
		return
	}
	// The direct command and the permanent monitor can see the same clear.
	if logID != nil && d.lastClear != nil && *logID == *d.lastClear {
		return
	}
	d.lastClear = logID
	zero := int64(0)
	d.matchLog.Cursor = &zero
	d.matchLog.LogID = logID
	d.matchLog.Missed = 0
	d.matchLog.Total = 0
	d.matchLog.ClearedSinceRead = len(d.matchLog.Entries) > 0
	_ = d.persistLog(d.matchLog)
}

func (d *deviceAPI) readLog(w http.ResponseWriter, _ *http.Request) {
	if !d.operation.TryLock() {
		deviceError(w, errDeviceBusy)
		return
	}
	defer d.operation.Unlock()
	link, err := d.openLink()
	if err != nil {
		deviceError(w, err)
		return
	}
	defer link.close()
	before := d.logSnapshot()
	if before.Port != link.state.Port {
		before = matchLogState{ClockSet: true, Port: link.state.Port}
	}
	next, err := fetchReceiverLog(link, before)
	if err != nil {
		deviceError(w, err)
		return
	}
	d.logMu.Lock()
	if !link.valid() {
		d.logMu.Unlock()
		deviceError(w, errDeviceDisconnected)
		return
	}
	// A board-side clear immediately after log_done wins over this read.
	if d.matchLog.Port == link.state.Port && d.matchLog.ClearedSinceRead &&
		d.matchLog.LogID != nil && next.LogID != nil &&
		*d.matchLog.LogID != *next.LogID &&
		(before.LogID == nil || *before.LogID != *d.matchLog.LogID) {
		d.logMu.Unlock()
		deviceError(w, errors.New("het logboek is tijdens het lezen gewist. Lees het opnieuw"))
		return
	}
	d.matchLog = next
	err = d.persistLog(next)
	d.logMu.Unlock()
	if err != nil {
		deviceError(w, fmt.Errorf("lokaal logboek opslaan: %w", err))
		return
	}
	deviceJSON(w, http.StatusOK, next)
}

func fetchReceiverLog(link *deviceLink, before matchLogState) (matchLogState, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	since := before.Cursor
	for attempt := 0; attempt < 2; attempt++ {
		command := map[string]any{"cmd": "log_get"}
		if since != nil {
			command["since"] = *since
		}
		if err := link.send(command); err != nil {
			return matchLogState{}, err
		}
		var pending []map[string]any
		for {
			line, err := link.receive(ctx, 5*time.Second, func(message map[string]any) bool {
				switch deviceString(message, "type") {
				case "log", "log_done", "log_cleared":
					return true
				}
				return false
			})
			if err != nil {
				return matchLogState{}, err
			}
			switch deviceString(line, "type") {
			case "log_cleared":
				return matchLogState{}, errors.New("het logboek is tijdens het lezen gewist. Lees het opnieuw")
			case "log":
				pending = append(pending, line)
				continue
			}

			if reported := deviceString(line, "err"); reported != "" {
				return matchLogState{}, fmt.Errorf("de ontvanger gaf een onvolledig logboek (%s). Lees het opnieuw", reported)
			}
			logID := deviceInt(line, "log_id")
			cursor := deviceInt(line, "next")
			total := deviceInt(line, "total")
			if cursor == nil {
				cursor = total
			}
			if total == nil {
				total = cursor
			}
			oldest := intValue(deviceInt(line, "oldest"), 0)
			if since != nil && (logID != nil && before.LogID != nil && *logID != *before.LogID ||
				total != nil && *since > *total) {
				if attempt == 1 {
					return matchLogState{}, errors.New("het logboek is tijdens het lezen veranderd. Lees het opnieuw")
				}
				before = matchLogState{Port: before.Port, LogID: logID, Missed: oldest, ClockSet: true}
				since = &oldest
				break
			}
			return mergeMatchLog(before, since, cursor, total, logID, oldest, pending, line), nil
		}
	}
	return matchLogState{}, errors.New("het logboek kon niet worden gelezen")
}

func logSequence(row map[string]any) *int64 {
	if seq := deviceInt(row, "seq"); seq != nil && *seq >= 0 {
		return seq
	}
	if seq := deviceInt(row, "i"); seq != nil && *seq >= 0 {
		return seq
	}
	return nil
}

func mergeMatchLog(before matchLogState, since, cursor, total, logID *int64, oldest int64, pending []map[string]any, done map[string]any) matchLogState {
	rows := make([]map[string]any, 0, len(pending))
	ended := make(map[int64]map[string]any)
	missed := oldest
	if since != nil {
		missed = before.Missed + max(0, oldest-*since)
		if !before.ClearedSinceRead {
			for _, row := range before.Entries {
				if seq := logSequence(row); !deviceBool(row, "active") && seq != nil {
					ended[*seq] = row
				}
			}
		}
	}
	for _, row := range pending {
		if deviceString(row, "mac") == "" {
			continue
		}
		if deviceBool(row, "active") {
			rows = append(rows, row)
		} else if seq := logSequence(row); seq != nil {
			ended[*seq] = row
		} else {
			rows = append(rows, row)
		}
	}
	sequences := make([]int64, 0, len(ended))
	for seq := range ended {
		sequences = append(sequences, seq)
	}
	sort.Slice(sequences, func(i, j int) bool { return sequences[i] > sequences[j] })
	for _, seq := range sequences {
		rows = append(rows, ended[seq])
	}
	clockSet, ok := done["clock"].(bool)
	return matchLogState{
		Entries: rows, Total: intValue(total, int64(len(rows))), Missed: missed, ClockSet: !ok || clockSet,
		Port: before.Port, Cursor: cursor, LogID: logID,
	}
}

func (d *deviceAPI) clearLog(w http.ResponseWriter, _ *http.Request) {
	if !d.operation.TryLock() {
		deviceError(w, errDeviceBusy)
		return
	}
	defer d.operation.Unlock()
	link, err := d.openLink()
	if err != nil {
		deviceError(w, err)
		return
	}
	defer link.close()
	if err := link.send(map[string]any{"cmd": "log_clear"}); err != nil {
		deviceError(w, err)
		return
	}
	line, err := link.receive(context.Background(), 5*time.Second, func(message map[string]any) bool {
		return deviceString(message, "type") == "log_cleared"
	})
	if err != nil {
		deviceError(w, err)
		return
	}
	d.recordClear(link.state.Port, deviceInt(line, "log_id"))
	deviceJSON(w, http.StatusOK, d.logSnapshot())
}

func (d *deviceAPI) exportLog(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Disposition", `attachment; filename="orecchino-match-log.csv"`)
	_ = writeMatchLogCSV(w, d.logSnapshot().Entries)
}

func writeMatchLogCSV(w io.Writer, entries []map[string]any) error {
	writer := csv.NewWriter(w)
	writer.UseCRLF = true
	if err := writer.Write(strings.Split("status,uas_id,mac,sources,first_utc,last_utc,duration_s,lat,lon,max_height_m,peak_rssi,auth,tfr,in_tfr,tfr_id,class,emergency,messages", ",")); err != nil {
		return err
	}
	for _, row := range entries {
		status := "ended"
		if deviceBool(row, "active") {
			status = "live"
		}
		record := []string{
			status, csvSafe(deviceString(row, "uas")), csvSafe(deviceString(row, "mac")), deviceLogSources(row),
			logTimestamp(row, "first"), logTimestamp(row, "last"), logNumber(row, "dur", 0),
			logNumber(row, "lat", 5), logNumber(row, "lon", 5), logNumber(row, "max_h", 0),
			logNumber(row, "peak_rssi", 0), csvSafe(deviceString(row, "auth_state")),
			logYesNo(row, "tfr"), logYesNo(row, "in_tfr"), csvSafe(deviceString(row, "tfr_id")),
			deviceLogClassification(row), logYesNo(row, "emerg"), logNumber(row, "msgs", 0),
		}
		if err := writer.Write(record); err != nil {
			return err
		}
	}
	writer.Flush()
	return writer.Error()
}

func csvSafe(value string) string {
	if value == "" {
		return value
	}
	trimmed := strings.TrimLeft(value, " \r\n\t")
	if strings.ContainsRune("\t\r\n", rune(value[0])) || trimmed != "" && strings.ContainsRune("=+-@", rune(trimmed[0])) {
		return "'" + value
	}
	return value
}

func deviceLogSources(row map[string]any) string {
	bits := intValue(deviceInt(row, "srcs"), 0)
	var sources []string
	for i, source := range []string{"Wi-Fi", "NAN", "BLE"} {
		if bits&(1<<i) != 0 {
			sources = append(sources, source)
		}
	}
	return strings.Join(sources, " + ")
}

func logTimestamp(row map[string]any, key string) string {
	seconds := intValue(deviceInt(row, key), 0)
	if seconds <= 0 {
		return ""
	}
	return time.Unix(seconds, 0).UTC().Format(time.RFC3339)
}

func logNumber(row map[string]any, key string, decimals int) string {
	value, ok := deviceNumber(row, key)
	if !ok {
		return ""
	}
	return strconv.FormatFloat(value, 'f', decimals, 64)
}

func logYesNo(row map[string]any, key string) string {
	if deviceBool(row, key) {
		return "yes"
	}
	return "no"
}

func deviceLogClassification(row map[string]any) string {
	classType := deviceInt(row, "class_type")
	if classType == nil {
		return ""
	}
	if *classType != 1 {
		return fmt.Sprintf("type %d", *classType)
	}
	parts := []string{"EU"}
	if category := deviceInt(row, "cat_eu"); category != nil {
		names := []string{"undeclared", "Open", "Specific", "Certified"}
		if *category >= 0 && *category < int64(len(names)) {
			parts = append(parts, names[*category])
		} else {
			parts = append(parts, fmt.Sprintf("category %d", *category))
		}
	}
	if class := deviceInt(row, "class_eu"); class != nil {
		if *class >= 1 && *class <= 7 {
			parts = append(parts, fmt.Sprintf("C%d", *class-1))
		} else {
			parts = append(parts, fmt.Sprintf("class %d", *class))
		}
	}
	return strings.Join(parts, " · ")
}
