// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	atakDefaultPort   = 4242
	atakFixLifetime   = 60 * time.Second
	atakTrackInterval = 2 * time.Second
	atakTick          = 250 * time.Millisecond
	atakBatchLimit    = 4
	atakWriteTimeout  = 150 * time.Millisecond
	atakUnknown       = "9999999.0"
	atakTimestamp     = "2006-01-02T15:04:05.000Z"
)

type atakSettings struct {
	Enabled bool   `json:"enabled"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
}

type atakView struct {
	atakSettings
	State      string     `json:"state"`
	Sent       uint64     `json:"sent"`
	LastSentAt *time.Time `json:"lastSentAt,omitempty"`
	Error      string     `json:"error,omitempty"`
}

type atakService struct {
	mu         sync.Mutex
	ctx        context.Context
	path       string
	instance   string
	snapshot   func() ReceiverState
	view       atakView
	generation uint64
	cancelRun  context.CancelFunc
}

func registerATAK(mux *http.ServeMux, dataDir string, snapshot func() ReceiverState) func() {
	ctx, cancel := context.WithCancel(context.Background())
	var nonce [16]byte
	_, _ = rand.Read(nonce[:])
	settings := atakSettings{Port: atakDefaultPort}
	service := &atakService{
		ctx: ctx, path: filepath.Join(dataDir, "atak.json"), instance: hex.EncodeToString(nonce[:]),
		snapshot: snapshot, view: atakView{atakSettings: settings, State: "off"},
	}
	if data, err := os.ReadFile(service.path); err == nil {
		if json.Unmarshal(data, &settings) == nil && settings.validate() == nil {
			service.configure(settings)
		} else {
			service.view.Error = "Ongeldige opgeslagen ATAK-instellingen"
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		service.view.Error = "ATAK-instellingen konden niet worden geladen"
	}
	mux.HandleFunc("GET /api/atak", service.get)
	mux.HandleFunc("POST /api/atak", service.set)
	return func() {
		service.mu.Lock()
		defer service.mu.Unlock()
		cancel()
	}
}

func (settings *atakSettings) validate() error {
	settings.Host = strings.TrimSpace(settings.Host)
	if settings.Port < 1 || settings.Port > 65535 {
		return errors.New("geef een UDP-poort van 1 tot en met 65535 op")
	}
	if settings.Host == "" {
		if settings.Enabled {
			return errors.New("geef het IP-adres of de hostnaam van je ATAK-apparaat op")
		}
		return nil
	}
	if len(settings.Host) > 254 || strings.IndexFunc(settings.Host, unicode.IsControl) >= 0 {
		return errors.New("geef een geldige hostnaam of IP-adres zonder poort op")
	}
	if unbracketed, ok := strings.CutPrefix(settings.Host, "["); ok {
		if value, ok := strings.CutSuffix(unbracketed, "]"); ok {
			settings.Host = value
		}
	}
	if ip, err := netip.ParseAddr(settings.Host); err == nil {
		if !atakUnicast(ip) {
			return errors.New("geef een unicastadres van het ATAK-apparaat op")
		}
		settings.Host = ip.String()
		return nil
	}
	host := strings.TrimSuffix(settings.Host, ".")
	if !atakHostname(host) {
		return errors.New("geef een geldige hostnaam of IP-adres zonder poort op")
	}
	settings.Host = strings.ToLower(settings.Host)
	return nil
}

func atakHostname(host string) bool {
	if len(host) == 0 || len(host) > 253 {
		return false
	}
	hasLetterOrHyphen := false
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, char := range label {
			switch {
			case char >= 'a' && char <= 'z', char >= 'A' && char <= 'Z', char == '-':
				hasLetterOrHyphen = true
			case char >= '0' && char <= '9':
			default:
				return false
			}
		}
	}
	return hasLetterOrHyphen
}

func atakUnicast(address netip.Addr) bool {
	address = address.Unmap()
	return address.IsValid() && !address.IsUnspecified() && !address.IsMulticast() &&
		address != netip.AddrFrom4([4]byte{255, 255, 255, 255})
}

func (service *atakService) get(w http.ResponseWriter, _ *http.Request) {
	service.mu.Lock()
	view := service.view
	service.mu.Unlock()
	replyJSON(w, http.StatusOK, view)
}

func (service *atakService) set(w http.ResponseWriter, r *http.Request) {
	var query struct {
		Enabled *bool  `json:"enabled"`
		Host    string `json:"host"`
		Port    int    `json:"port"`
	}
	if !readRequest(w, r, &query) {
		return
	}
	if query.Enabled == nil {
		replyError(w, http.StatusBadRequest, errors.New("geef aan of ATAK-deling aan of uit staat"))
		return
	}
	settings := atakSettings{Enabled: *query.Enabled, Host: query.Host, Port: query.Port}
	if err := settings.validate(); err != nil {
		replyError(w, http.StatusBadRequest, err)
		return
	}
	service.mu.Lock()
	if settings != service.view.atakSettings || !settings.Enabled && service.view.Error != "" {
		data, err := json.Marshal(settings)
		if err == nil {
			err = writeDeviceFile(service.path, data)
		}
		if err != nil {
			service.mu.Unlock()
			replyError(w, http.StatusInternalServerError, errors.New("ATAK-instellingen opslaan mislukt"))
			return
		}
		service.configure(settings)
	}
	view := service.view
	service.mu.Unlock()
	replyJSON(w, http.StatusOK, view)
}

// Configure is called before registration or under mu by the settings handler.
func (service *atakService) configure(settings atakSettings) {
	if service.cancelRun != nil {
		service.cancelRun()
		service.cancelRun = nil
	}
	service.generation++
	service.view = atakView{atakSettings: settings, State: "off"}
	if settings.Enabled {
		service.view.State = "waiting"
		ctx, cancel := context.WithCancel(service.ctx)
		service.cancelRun = cancel
		go service.run(ctx, settings, service.generation)
	}
}

type atakEvent struct {
	XMLName xml.Name    `xml:"event"`
	Version string      `xml:"version,attr"`
	UID     string      `xml:"uid,attr"`
	Type    string      `xml:"type,attr"`
	How     string      `xml:"how,attr"`
	Access  string      `xml:"access,attr"`
	Time    string      `xml:"time,attr"`
	Start   string      `xml:"start,attr"`
	Stale   string      `xml:"stale,attr"`
	Point   atakPoint   `xml:"point"`
	Contact atakContact `xml:"detail>contact"`
}

type atakPoint struct {
	Lat string `xml:"lat,attr"`
	Lon string `xml:"lon,attr"`
	HAE string `xml:"hae,attr"`
	CE  string `xml:"ce,attr"`
	LE  string `xml:"le,attr"`
}

type atakContact struct {
	Callsign string `xml:"callsign,attr"`
}

func atakFixUsable(track Track, now time.Time) bool {
	return !track.Simulated && !track.lastFix.IsZero() && !now.Before(track.lastFix) &&
		now.Sub(track.lastFix) < atakFixLifetime && validRIDPoint(track.Lat, track.Lon)
}

func atakContactNumber(id string) (uint64, bool) {
	suffix, ok := strings.CutPrefix(id, "track-")
	if !ok {
		return 0, false
	}
	value, err := strconv.ParseUint(suffix, 10, 64)
	return value, err == nil && value != 0
}

func marshalATAKFix(instance string, contact uint64, track Track) ([]byte, error) {
	at := track.lastFix.UTC()
	hae := atakUnknown
	if value := track.lastFixHAE; value != nil && *value > -999 && validCoordinate(*value, 31767.5) {
		hae = strconv.FormatFloat(*value, 'f', 1, 64)
	}
	id := strconv.FormatUint(contact, 10)
	event := atakEvent{
		Version: "2.0", UID: "orecchino-rid-" + instance + "-" + id, Type: "a-u-A", How: "m-r", Access: "Undefined",
		Time: at.Format(atakTimestamp), Start: at.Format(atakTimestamp), Stale: at.Add(atakFixLifetime).Format(atakTimestamp),
		Point: atakPoint{
			Lat: strconv.FormatFloat(*track.Lat, 'f', 7, 64), Lon: strconv.FormatFloat(*track.Lon, 'f', 7, 64),
			HAE: hae, CE: atakUnknown, LE: atakUnknown,
		},
		Contact: atakContact{Callsign: "Orecchino UAS " + id},
	}
	body, err := xml.Marshal(event)
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), body...), nil
}

type atakDelivery struct {
	fix  time.Time
	sent time.Time
}

type atakCandidate struct {
	track    Track
	number   uint64
	lastSent time.Time
}

func (service *atakService) run(ctx context.Context, settings atakSettings, generation uint64) {
	ticker := time.NewTicker(atakTick)
	defer ticker.Stop()
	delivered := make(map[string]atakDelivery)
	var connection *net.UDPConn
	defer func() {
		if connection != nil {
			_ = connection.Close()
		}
	}()
	var retryAt time.Time
	failures := 0

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		now := time.Now()
		if now.Before(retryAt) {
			continue
		}
		tracks := service.snapshot().Tracks
		present := make(map[string]struct{}, len(tracks))
		candidates := make([]atakCandidate, 0, len(tracks))
		hasFixes := false
		for _, track := range tracks {
			present[track.ID] = struct{}{}
			number, ok := atakContactNumber(track.ID)
			if !ok || !atakFixUsable(track, now) {
				continue
			}
			hasFixes = true
			previous := delivered[track.ID]
			if track.lastFix.After(previous.fix) && now.Sub(previous.sent) >= atakTrackInterval {
				candidates = append(candidates, atakCandidate{track: track, number: number, lastSent: previous.sent})
			}
		}
		for id := range delivered {
			if _, ok := present[id]; !ok {
				delete(delivered, id)
			}
		}
		if !hasFixes {
			service.mu.Lock()
			if service.generation == generation && service.view.Error == "" {
				service.view.State = "waiting"
			}
			service.mu.Unlock()
		}
		sort.Slice(candidates, func(i, j int) bool {
			if candidates[i].lastSent.Equal(candidates[j].lastSent) {
				return candidates[i].number < candidates[j].number
			}
			return candidates[i].lastSent.Before(candidates[j].lastSent)
		})
		for _, c := range candidates[:min(atakBatchLimit, len(candidates))] {
			if ctx.Err() != nil {
				return
			}
			var err error
			if connection == nil {
				connection, err = openATAKDestination(ctx, settings)
			}
			if err == nil {
				// DNS lookup or a busy batch must not extend fix validity.
				if !atakFixUsable(c.track, time.Now()) {
					continue
				}
				var packet []byte
				packet, err = marshalATAKFix(service.instance, c.number, c.track)
				if err == nil {
					var sent time.Time
					sent, err = service.write(ctx, generation, connection, packet)
					if err == nil {
						delivered[c.track.ID] = atakDelivery{fix: c.track.lastFix, sent: sent}
					}
				}
			}
			if err == nil {
				failures = 0
				continue
			}
			if connection != nil {
				_ = connection.Close()
				connection = nil
			}
			service.mu.Lock()
			if ctx.Err() == nil && service.generation == generation {
				service.view.State = "error"
				service.view.Error = "ATAK UDP-verzending mislukt: " + err.Error()
			}
			service.mu.Unlock()
			failures++
			retryAt = time.Now().Add(time.Second * time.Duration(min(15, 1<<min(failures, 4))))
			break
		}
	}
}

func (service *atakService) write(ctx context.Context, generation uint64, connection *net.UDPConn, packet []byte) (time.Time, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.generation != generation || ctx.Err() != nil {
		return time.Time{}, context.Canceled
	}
	if err := connection.SetWriteDeadline(time.Now().Add(atakWriteTimeout)); err != nil {
		return time.Time{}, err
	}
	count, err := connection.Write(packet)
	if err != nil {
		return time.Time{}, err
	}
	if count != len(packet) {
		return time.Time{}, io.ErrShortWrite
	}
	sent := time.Now().UTC()
	service.view.Sent++
	service.view.State = "ready"
	service.view.Error = ""
	service.view.LastSentAt = &sent
	return sent, nil
}

func openATAKDestination(ctx context.Context, settings atakSettings) (*net.UDPConn, error) {
	address, err := netip.ParseAddr(settings.Host)
	addresses := []netip.Addr{address}
	if err != nil {
		timeout, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
		defer cancel()
		addresses, err = net.DefaultResolver.LookupNetIP(timeout, "ip", settings.Host)
		if err != nil {
			return nil, fmt.Errorf("hostnaam: %w", err)
		}
	}
	var dialError error
	for _, candidate := range addresses {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if !atakUnicast(candidate) {
			continue
		}
		endpoint := net.UDPAddrFromAddrPort(netip.AddrPortFrom(candidate.Unmap(), uint16(settings.Port)))
		connection, err := net.DialUDP("udp", nil, endpoint)
		if err == nil {
			return connection, nil
		}
		dialError = err
	}
	if dialError != nil {
		return nil, dialError
	}
	return nil, errors.New("de hostnaam verwijst naar geen bruikbaar unicastadres")
}
