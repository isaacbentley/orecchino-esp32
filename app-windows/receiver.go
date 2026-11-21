// SPDX-License-Identifier: GPL-3.0-only
// Windows receiver and Remote ID tracking port of Orecchino, by Isaac Bentley.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.bug.st/serial"
	"go.bug.st/serial/enumerator"
)

const (
	receiverCommandLimit   = 1600
	receiverLineLimit      = 8192
	receiverProbeTime      = 7 * time.Second
	receiverSilenceTime    = 15 * time.Second
	receiverPollTime       = 35 * time.Millisecond
	receiverWriteTime      = 3 * time.Second
	receiverTrackFreshness = 60 * time.Second
)

var (
	errNoReceiver     = errors.New("geen Orecchino-ontvanger verbonden")
	errSessionChanged = errors.New("de verbinding met de ontvanger is gewijzigd")
	windowsCOM        = regexp.MustCompile(`^COM[1-9][0-9]*$`)
	unixSerial        = regexp.MustCompile(`^/dev/(?:tty[A-Z][A-Za-z0-9._-]*|cu\.[A-Za-z0-9._-]+|pts/[0-9]+)$`)
)

type ReceiverStats struct {
	UptimeMS    int64  `json:"uptimeMs"`
	WiFiFrames  int64  `json:"wifiFrames"`
	BLEAdvs     int64  `json:"bleAdvs"`
	RIDCount    int64  `json:"ridCount"`
	Dropped     int64  `json:"dropped"`
	Channel     int64  `json:"channel"`
	WiFi        *bool  `json:"wifi,omitempty"`
	BLE         *bool  `json:"ble,omitempty"`
	BLEExtended *bool  `json:"bleExtended,omitempty"`
	BLEDrop     *int64 `json:"bleDrop,omitempty"`
	BLERxDrop   *int64 `json:"bleRxDrop,omitempty"`
	USBDrop     *int64 `json:"usbDrop,omitempty"`
	RXStack     *int64 `json:"rxStack,omitempty"`
}

type ReceiverState struct {
	Status        string        `json:"status"`
	Port          string        `json:"port"`
	PreferredPort string        `json:"preferredPort"`
	Error         string        `json:"error,omitempty"`
	Board         string        `json:"board,omitempty"`
	Firmware      string        `json:"firmware,omitempty"`
	Capabilities  []string      `json:"capabilities"`
	Demo          bool          `json:"demo"`
	Stats         ReceiverStats `json:"stats"`
	Tracks        []Track       `json:"tracks"`
	Session       uint64        `json:"session"`
	liveRIDEpoch  uint64
}

type receiverWrite struct {
	session  uint64
	data     []byte
	deadline time.Time
	done     chan error
}

type receiverConnection struct {
	ctx    context.Context
	cancel context.CancelFunc
	writes chan receiverWrite
	done   chan struct{}
}

type Receiver struct {
	mu            sync.Mutex
	connection    *receiverConnection
	preferred     string
	port          string
	portError     string
	session       uint64
	lastHeartbeat time.Time
	verified      bool
	firmware      string
	board         string
	caps          []string
	stats         ReceiverStats
	tracks        map[string]*Track
	uasIndex      map[string]string
	macIndex      map[string]string
	nextTrack     uint64
	lastLiveRID   time.Time
	liveRIDEpoch  uint64
	trafficWake   chan struct{}
	demo          bool
	demoStop      chan struct{}
	subscribers   map[chan map[string]any]struct{}
}

func NewReceiver() *Receiver {
	return &Receiver{
		preferred: "auto", tracks: make(map[string]*Track), uasIndex: make(map[string]string),
		macIndex: make(map[string]string), subscribers: make(map[chan map[string]any]struct{}),
		trafficWake: make(chan struct{}, 1),
	}
}

func (r *Receiver) wakeTraffic() {
	select {
	case r.trafficWake <- struct{}{}:
	default:
	}
}

func (r *Receiver) Ports() ([]string, error) {
	ports, err := serial.GetPortsList()
	if err != nil {
		return nil, err
	}
	if ports == nil {
		ports = []string{}
	}
	sort.Slice(ports, func(i, j int) bool {
		if strings.HasPrefix(ports[i], "COM") && strings.HasPrefix(ports[j], "COM") {
			a, firstError := strconv.Atoi(ports[i][3:])
			b, secondError := strconv.Atoi(ports[j][3:])
			if firstError == nil && secondError == nil {
				return a < b
			}
		}
		return ports[i] < ports[j]
	})
	return ports, nil
}

func (r *Receiver) Connect(port string) error {
	port = strings.TrimSpace(port)
	if port == "" || strings.EqualFold(port, "auto") {
		port = "auto"
	} else if runtime.GOOS == "windows" {
		port = strings.ToUpper(port)
		if !windowsCOM.MatchString(port) {
			return errors.New("kies automatisch zoeken of een Windows-COM-poort")
		}
	} else if !unixSerial.MatchString(port) {
		return errors.New("kies automatisch zoeken of een seriële poort onder /dev")
	}
	ctx, cancel := context.WithCancel(context.Background())
	connection := &receiverConnection{
		ctx: ctx, cancel: cancel, writes: make(chan receiverWrite, 32), done: make(chan struct{}),
	}
	r.mu.Lock()
	previous := r.connection
	r.connection = connection
	r.preferred = port
	r.resetPortLocked("")
	if previous != nil {
		previous.cancel()
	}
	r.mu.Unlock()

	go func() {
		defer close(connection.done)
		if previous != nil {
			<-previous.done
		}
		r.runConnection(connection, port)
	}()
	return nil
}

func (r *Receiver) Disconnect() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.connection != nil && r.connection.ctx.Err() == nil {
		r.connection.cancel()
		r.resetPortLocked("")
	}
}

func (r *Receiver) resetPortLocked(port string) {
	r.port, r.portError = port, ""
	r.session++
	r.lastHeartbeat = time.Time{}
	r.verified = false
	r.firmware, r.board, r.caps = "", "", nil
	r.stats = ReceiverStats{}
}

func (r *Receiver) Snapshot() ReceiverState {
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	state := ReceiverState{
		Status: "disconnected", Port: r.port, PreferredPort: r.preferred, Error: r.portError,
		Board: r.board, Firmware: r.firmware, Capabilities: append([]string{}, r.caps...),
		Demo: r.demo, Stats: r.stats, Tracks: make([]Track, 0, len(r.tracks)), Session: r.session,
		liveRIDEpoch: r.liveRIDEpoch,
	}
	switch {
	case r.connection == nil || r.connection.ctx.Err() != nil:
	case r.port == "":
		state.Status = "searching"
	case r.lastHeartbeat.IsZero():
		state.Status = "waiting"
	case now.Sub(r.lastHeartbeat) < 6*time.Second:
		state.Status = "receiving"
	default:
		state.Status = "stalled"
	}
	for _, track := range r.tracks {
		age := max(0, now.Sub(track.LastSeen).Seconds())
		if !track.Simulated && age > 600 {
			r.forgetTrackLocked(track)
			continue
		}
		copy := *track
		copy.AgeSeconds = age
		copy.Stale = now.Sub(track.LastSeen) > receiverTrackFreshness
		copy.MACs = append([]string{}, track.MACs...)
		copy.Sources = append([]string{}, track.Sources...)
		copy.Trail = append([]GeoPoint{}, track.Trail...)
		state.Tracks = append(state.Tracks, copy)
	}
	sort.Slice(state.Tracks, func(i, j int) bool {
		a, b := state.Tracks[i], state.Tracks[j]
		if a.Stale != b.Stale {
			return !a.Stale
		}
		if !a.LastSeen.Equal(b.LastSeen) {
			return a.LastSeen.After(b.LastSeen)
		}
		return a.ID < b.ID
	})
	return state
}

func (r *Receiver) Subscribe() (<-chan map[string]any, func()) {
	ch := make(chan map[string]any, 4096)
	r.mu.Lock()
	r.subscribers[ch] = struct{}{}
	r.mu.Unlock()
	return ch, func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if _, ok := r.subscribers[ch]; ok {
			delete(r.subscribers, ch)
			close(ch)
		}
	}
}

func (r *Receiver) Send(command any) error {
	return r.SendFor(0, command)
}

func (r *Receiver) SendFor(session uint64, command any) error {
	data, err := json.Marshal(command)
	if err != nil {
		return fmt.Errorf("opdracht voor ontvanger coderen: %w", err)
	}
	if len(data) >= receiverCommandLimit || len(data) < 2 || data[0] != '{' {
		return errors.New("de opdracht moet een JSON-object van minder dan 1600 bytes zijn")
	}
	r.mu.Lock()
	connection := r.connection
	currentSession := r.session
	canWrite := connection != nil && connection.ctx.Err() == nil && r.verified
	r.mu.Unlock()
	if session != 0 && session != currentSession {
		return errSessionChanged
	}
	if !canWrite {
		return errNoReceiver
	}
	timer := time.NewTimer(2 * receiverWriteTime)
	defer timer.Stop()
	request := receiverWrite{
		session: currentSession, data: append(data, '\n'),
		deadline: time.Now().Add(receiverWriteTime), done: make(chan error, 1),
	}
	select {
	case connection.writes <- request:
	case <-connection.ctx.Done():
		return errSessionChanged
	case <-timer.C:
		return errors.New("de wachtrij van de ontvanger reageert niet")
	}
	select {
	case err := <-request.done:
		return err
	case <-connection.ctx.Done():
		return errSessionChanged
	case <-timer.C:
		return errors.New("de opdracht kon niet op tijd naar de ontvanger worden gestuurd")
	}
}

type serialCandidate struct {
	name string
	baud int
	dtr  bool
}

func (r *Receiver) serialCandidates(preferred string) ([]serialCandidate, error) {
	ports, err := r.Ports()
	if preferred == "auto" && err != nil {
		return nil, err
	}
	if preferred != "auto" {
		ports = []string{preferred}
	}
	details, _ := enumerator.GetDetailedPortsList()
	byName := make(map[string]*enumerator.PortDetails, len(details))
	for _, detail := range details {
		if detail != nil {
			byName[detail.Name] = detail
		}
	}
	// Known USB receivers come first. A driver may report an ESP dongle as
	// generic USB serial, so keep those ports as candidates too.
	priority := func(name string) int {
		if d := byName[name]; d != nil && d.IsUSB {
			switch strings.ToUpper(d.VID) {
			case "303A", "1A86", "10C4", "2886", "2E8A":
				return 0
			}
			return 1
		}
		return 2
	}
	sort.SliceStable(ports, func(i, j int) bool { return priority(ports[i]) < priority(ports[j]) })
	candidates := make([]serialCandidate, 0, 2*len(ports))
	fallback := make([]serialCandidate, 0, len(ports))
	for _, port := range ports {
		ch340 := false
		if d := byName[port]; d != nil {
			ch340 = strings.EqualFold(d.VID, "1A86")
		}
		first, second := 115200, 460800
		if ch340 {
			first, second = second, first
		}
		candidates = append(candidates, serialCandidate{port, first, !ch340})
		fallback = append(fallback, serialCandidate{port, second, !ch340})
	}
	return append(candidates, fallback...), nil
}

func (r *Receiver) runConnection(connection *receiverConnection, preferred string) {
	var previousMatch *serialCandidate
	for connection.ctx.Err() == nil {
		candidates, err := r.serialCandidates(preferred)
		if err != nil {
			r.updatePortError(connection, err)
		}
		if previousMatch != nil {
			for i, candidate := range candidates {
				if candidate == *previousMatch {
					copy(candidates[1:i+1], candidates[:i])
					candidates[0] = candidate
					break
				}
			}
		}
		for _, candidate := range candidates {
			if connection.ctx.Err() != nil {
				return
			}
			matched, err := r.runPort(connection, candidate)
			if err != nil && preferred != "auto" {
				r.updatePortError(connection, fmt.Errorf("%s: %w", candidate.name, err))
			}
			if matched {
				previousMatch = &candidate
				break
			}
		}
		if !sleepWithContext(connection.ctx, 1200*time.Millisecond) {
			return
		}
	}
}

func (r *Receiver) updatePortError(connection *receiverConnection, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.connection == connection && connection.ctx.Err() == nil {
		r.portError = err.Error()
	}
}

func sleepWithContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func (r *Receiver) runPort(connection *receiverConnection, candidate serialCandidate) (matched bool, err error) {
	mode := serial.Mode{
		BaudRate: candidate.baud, DataBits: 8, Parity: serial.NoParity, StopBits: serial.OneStopBit,
		InitialStatusBits: &serial.ModemOutputBits{DTR: candidate.dtr, RTS: false},
	}
	if runtime.GOOS != "windows" && strings.HasPrefix(candidate.name, "/dev/pts/") {
		// The development test feed is a pseudo-terminal with no modem pins.
		mode.InitialStatusBits = nil
	}
	port, err := serial.Open(candidate.name, &mode)
	if err != nil {
		return false, err
	}
	defer port.Close()
	if err := port.SetReadTimeout(receiverPollTime); err != nil {
		return false, err
	}
	r.mu.Lock()
	if r.connection != connection || connection.ctx.Err() != nil {
		r.mu.Unlock()
		return false, nil
	}
	r.resetPortLocked(candidate.name)
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.connection == connection && connection.ctx.Err() == nil {
			r.resetPortLocked("")
		}
	}()

	opened := time.Now()
	lastValid := opened
	chunk := make([]byte, 4096)
	lines := serialLineBuffer{data: make([]byte, 0, 2048)}
	for connection.ctx.Err() == nil {
		for written := 0; written < 16; written++ {
			select {
			case request := <-connection.writes:
				r.mu.Lock()
				valid := r.connection == connection && connection.ctx.Err() == nil &&
					r.verified && r.session == request.session
				r.mu.Unlock()
				if !valid {
					request.done <- errSessionChanged
					continue
				}
				if time.Now().After(request.deadline) {
					request.done <- errors.New("de opdracht voor de ontvanger is verlopen")
					continue
				}
				err := writeSerial(port, request.data)
				request.done <- err
				if err != nil {
					return matched, err
				}
				continue
			default:
			}
			break
		}
		n, err := port.Read(chunk)
		if err != nil {
			return matched, err
		}
		if n > 0 {
			var syncClock bool
			lines.feed(chunk[:n], func(line []byte) {
				var message map[string]any
				if json.Unmarshal(bytes.TrimSpace(line), &message) != nil {
					return
				}
				var recognized, clock bool
				recognized, clock = r.ingestSerial(connection, message, time.Now())
				if recognized {
					lastValid = time.Now()
					matched = true
					syncClock = syncClock || clock
				}
			})
			if syncClock && connection.ctx.Err() == nil {
				line := fmt.Appendf(nil, "{\"cmd\":\"set_time\",\"utc\":%d}\n", time.Now().Unix())
				if err := writeSerial(port, line); err != nil {
					return matched, err
				}
			}
		}
		switch {
		case !matched && time.Since(opened) > receiverProbeTime:
			return false, errors.New("geen Remote ID-gegevens of hartslag ontvangen")
		case matched && time.Since(lastValid) > receiverSilenceTime:
			return true, errors.New("de ontvanger stuurt geen gegevens meer")
		}
	}
	return matched, nil
}

func writeSerial(port serial.Port, data []byte) error {
	// A USB CDC driver can otherwise block indefinitely when the board has
	// stopped draining its input. Closing the handle also releases that write.
	closed := make(chan struct{})
	watchdog := time.AfterFunc(receiverWriteTime, func() {
		_ = port.Close()
		close(closed)
	})
	var err error
	for len(data) > 0 {
		var n int
		n, err = port.Write(data)
		if err != nil {
			break
		}
		if n == 0 {
			err = io.ErrShortWrite
			break
		}
		data = data[n:]
	}
	if !watchdog.Stop() {
		<-closed
		return errors.New("de seriële poort heeft de opdracht niet op tijd verwerkt")
	}
	return err
}

type serialLineBuffer struct {
	data    []byte
	discard bool
}

func (buffer *serialLineBuffer) feed(chunk []byte, line func([]byte)) {
	for len(chunk) > 0 {
		newline := bytes.IndexByte(chunk, '\n')
		end := len(chunk)
		if newline >= 0 {
			end = newline
		}
		if !buffer.discard && len(buffer.data)+end <= receiverLineLimit {
			buffer.data = append(buffer.data, chunk[:end]...)
		} else {
			buffer.discard = true
		}
		if newline < 0 {
			return
		}
		if !buffer.discard && len(buffer.data) > 0 {
			line(buffer.data)
		}
		buffer.data = buffer.data[:0]
		buffer.discard = false
		chunk = chunk[newline+1:]
	}
}

func (r *Receiver) ingestSerial(connection *receiverConnection, message map[string]any, now time.Time) (recognized, syncClock bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.connection != connection || connection.ctx.Err() != nil {
		return false, false
	}
	kind := textField(message, "type")
	if kind == "boot" && !strings.EqualFold(textField(message, "fw"), "orecchino") {
		return false, false
	}
	if !r.verified {
		// A COM port is only promoted to a receiver when it speaks the
		// documented protocol. Probing arbitrary devices sends nothing.
		switch kind {
		case "boot":
		case "hb":
			if numberField(message, "up") == nil || (r.preferred == "auto" &&
				numberField(message, "rid") == nil && numberField(message, "ble_advs") == nil &&
				numberField(message, "wifi_frames") == nil && message["caps"] == nil) {
				return false, false
			}
		case "rid":
			if textField(message, "mac") == "" {
				return false, false
			}
		default:
			return false, false
		}
		r.verified = true
		r.lastHeartbeat = now
		syncClock = true
	} else if kind == "boot" {
		// A board has rebooted without losing COM; invalidate in-flight
		// storage reads/writes and let services repopulate device context.
		r.resetPortLocked(r.port)
		r.verified = true
		r.lastHeartbeat = now
		syncClock = true
	}
	switch kind {
	case "boot":
		r.firmware = strings.TrimSpace(textField(message, "fw") + " " + textField(message, "ver"))
		r.board = textField(message, "board")
		r.stats.WiFi = boolField(message, "wifi")
		r.stats.BLE = boolField(message, "ble")
		r.stats.BLEExtended = boolField(message, "ble_ext")
		r.updateCapabilitiesLocked(message)
	case "hb":
		r.lastHeartbeat = now
		r.updateHeartbeatLocked(message)
	case "rid":
		r.ingestTrackLocked(message, now, false)
	case "":
		return false, syncClock
	case "dji_wifi":
		// A nearby access point without Remote ID is not an aircraft track.
	default:
		for channel := range r.subscribers {
			select {
			case channel <- message:
			default:
				// An inactive consumer may not block live reception.
				delete(r.subscribers, channel)
				close(channel)
			}
		}
	}
	return true, syncClock
}

func (r *Receiver) updateCapabilitiesLocked(message map[string]any) {
	values, ok := message["caps"].([]any)
	if !ok {
		return
	}
	r.caps = make([]string, 0, len(values))
	for _, value := range values {
		if name, ok := value.(string); ok && name != "" {
			r.caps = append(r.caps, name)
		}
	}
}

func (r *Receiver) updateHeartbeatLocked(message map[string]any) {
	r.updateCapabilitiesLocked(message)
	for key, counter := range map[string]*int64{
		"up": &r.stats.UptimeMS, "wifi_frames": &r.stats.WiFiFrames,
		"ble_advs": &r.stats.BLEAdvs, "rid": &r.stats.RIDCount, "dropped": &r.stats.Dropped, "ch": &r.stats.Channel,
	} {
		if n := counterField(message, key); n != nil {
			*counter = *n
		}
	}
	if ble := boolField(message, "ble"); ble != nil {
		r.stats.BLE = ble
	}
	if extended := boolField(message, "ble_ext"); extended != nil {
		r.stats.BLEExtended = extended
	}
	r.stats.BLEDrop = counterField(message, "ble_drop")
	r.stats.BLERxDrop = counterField(message, "ble_rx_drop")
	r.stats.USBDrop = counterField(message, "usb_drop")
	if stack := counterField(message, "rx_stack"); stack != nil {
		r.stats.RXStack = stack
	}
}
