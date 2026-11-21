// Windows port of Orecchino's ADS-B and FAA airspace services.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

type airspaceSettings struct {
	Enabled  bool    `json:"enabled"`
	RadiusKm float64 `json:"radiusKm"`
	Source   string  `json:"source"`
}

type airspaceView struct {
	TFRStatus      string            `json:"tfrStatus"`
	TFRState       string            `json:"tfrState"`
	TFRCount       *int              `json:"tfrCount,omitempty"`
	TFRRevision    uint64            `json:"tfrRevision"`
	Zones          *[]tfrZone        `json:"zones,omitempty"`
	TrackTFRs      map[string]string `json:"trackTfrs"`
	TrafficStatus  string            `json:"trafficStatus"`
	TrafficState   string            `json:"trafficState"`
	TrafficAge     *float64          `json:"trafficAgeSec,omitempty"`
	TrafficEnabled bool              `json:"trafficEnabled"`
	RadiusKm       float64           `json:"radiusKm"`
	Source         string            `json:"source"`
	Alerts         []airAlert        `json:"alerts"`
}

type airspaceService struct {
	mu              sync.Mutex
	settings        airspaceSettings
	settingsPath    string
	view            airspaceView
	refreshTFR      chan struct{}
	zones           []tfrZone
	mapVisibleUntil time.Time
	wakeTraffic     chan struct{}
}

const airMapVisibilityLease = 15 * time.Second

func registerAirspace(mux *http.ServeMux, receiver *Receiver, location func() *GeoPoint, dataDirs ...string) (func(), func() []airAlert) {
	service := &airspaceService{
		settings: airspaceSettings{Enabled: true, RadiusKm: 10, Source: defaultTrafficSource},
		view: airspaceView{
			TFRStatus: "TFR …", TFRState: "loading",
			TrafficStatus: "Waiting for a position", TrafficState: "position",
			TrackTFRs: map[string]string{}, Alerts: []airAlert{},
		},
		refreshTFR:  make(chan struct{}, 1),
		zones:       []tfrZone{},
		wakeTraffic: make(chan struct{}, 1),
	}
	if len(dataDirs) > 0 && dataDirs[0] != "" {
		service.settingsPath = filepath.Join(dataDirs[0], "traffic.json")
		if data, err := os.ReadFile(service.settingsPath); err == nil {
			settings := service.settings
			if json.Unmarshal(data, &settings) == nil && service.valid(settings) {
				service.settings = settings
			}
		}
	}

	mux.HandleFunc("GET /api/airspace", service.getView)
	mux.HandleFunc("POST /api/airspace/traffic", service.saveSettings)
	mux.HandleFunc("POST /api/airspace/refresh", service.manualTFRRefresh)
	mux.HandleFunc("POST /api/airspace/map-visibility", service.setMapVisibility)

	ctx, cancel := context.WithCancel(context.Background())
	service.refreshTFR <- struct{}{}
	go service.runTFRRefresh(ctx)
	go service.run(ctx, receiver, location)
	return cancel, func() []airAlert {
		service.mu.Lock()
		defer service.mu.Unlock()
		return slices.Clone(service.view.Alerts)
	}
}

func (service *airspaceService) valid(settings airspaceSettings) bool {
	return settings.RadiusKm >= 5 && settings.RadiusKm <= 30 && airValidSource(settings.Source)
}

func (service *airspaceService) getView(w http.ResponseWriter, r *http.Request) {
	service.mu.Lock()
	view := service.view
	view.TrafficEnabled = service.settings.Enabled
	view.RadiusKm = service.settings.RadiusKm
	view.Source = service.settings.Source
	if r.URL.Query().Get("zones") != "0" {
		zones := service.zones
		view.Zones = &zones
	}
	if view.TFRRevision > 0 {
		count := len(service.zones)
		view.TFRCount = &count
	}
	service.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(view)
}

func (service *airspaceService) saveSettings(w http.ResponseWriter, r *http.Request) {
	var update struct {
		Enabled  *bool    `json:"enabled"`
		RadiusKm *float64 `json:"radiusKm"`
		Source   *string  `json:"source"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&update) != nil || decoder.Decode(new(any)) != io.EOF {
		replyError(w, http.StatusBadRequest, errors.New("ongeldige verkeersinstellingen"))
		return
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	settings := service.settings
	if update.Enabled != nil {
		settings.Enabled = *update.Enabled
	}
	if update.RadiusKm != nil {
		settings.RadiusKm = *update.RadiusKm
	}
	if update.Source != nil {
		settings.Source = strings.TrimSpace(*update.Source)
		if settings.Source == "" {
			settings.Source = defaultTrafficSource
		}
	}
	if !service.valid(settings) {
		replyError(w, http.StatusBadRequest, errors.New("kies een straal van 5 tot 30 km en een URL met {lat}, {lon} en {radius}"))
		return
	}
	if settings != service.settings {
		if err := airSaveSettings(service.settingsPath, settings); err != nil {
			replyError(w, http.StatusInternalServerError, errors.New("verkeersinstellingen opslaan mislukt"))
			return
		}
		service.settings = settings
		service.wake()
	}
	w.WriteHeader(http.StatusNoContent)
}

func (service *airspaceService) setMapVisibility(w http.ResponseWriter, r *http.Request) {
	var update struct {
		Visible *bool `json:"visible"`
	}
	if !readRequest(w, r, &update) {
		return
	}
	if update.Visible == nil {
		replyError(w, http.StatusBadRequest, errors.New("geef aan of de kaart zichtbaar is"))
		return
	}
	now := time.Now()
	service.mu.Lock()
	wasVisible := now.Before(service.mapVisibleUntil)
	if *update.Visible {
		service.mapVisibleUntil = now.Add(airMapVisibilityLease)
	} else {
		service.mapVisibleUntil = time.Time{}
	}
	service.mu.Unlock()
	if *update.Visible != wasVisible {
		service.wake()
	}
	w.WriteHeader(http.StatusNoContent)
}

func (service *airspaceService) wake() {
	select {
	case service.wakeTraffic <- struct{}{}:
	default:
	}
}

func airSaveSettings(path string, settings airspaceSettings) error {
	if path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "traffic-settings-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := json.NewEncoder(tmp).Encode(settings); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func (service *airspaceService) manualTFRRefresh(w http.ResponseWriter, r *http.Request) {
	select {
	case service.refreshTFR <- struct{}{}:
	default:
	}
	w.WriteHeader(http.StatusNoContent)
}

func (service *airspaceService) runTFRRefresh(ctx context.Context) {
	timer := time.NewTicker(15 * time.Minute)
	defer timer.Stop()
	client := &http.Client{Timeout: 30 * time.Second}
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		case <-service.refreshTFR:
		}

		service.mu.Lock()
		service.view.TFRStatus, service.view.TFRState = "TFR …", "loading"
		service.mu.Unlock()

		zones, err := fetchTFR(ctx, client)
		if ctx.Err() != nil {
			return
		}
		service.mu.Lock()
		if err != nil {
			service.view.TFRStatus, service.view.TFRState = "TFR unavailable: "+err.Error(), "error"
		} else {
			service.view.TFRStatus, service.view.TFRState = fmt.Sprintf("TFR %d", len(zones)), "ready"
			service.zones = zones
			service.view.TFRRevision++
		}
		service.mu.Unlock()
	}
}

type airFetchResult struct {
	Aircraft   []airAircraft
	Err        error
	Area       airArea
	Source     string
	Generation uint64
}

type airTrafficDemand uint8

const (
	airNoDemand airTrafficDemand = iota
	airMapDemand
	airDroneDemand
)

func airDemandFor(enabled, demo, hasArea, mapVisible bool, drones []airDrone) airTrafficDemand {
	if !enabled || demo || !hasArea {
		return airNoDemand
	}
	if slices.ContainsFunc(drones, func(drone airDrone) bool { return drone.Live }) {
		return airDroneDemand
	}
	if mapVisible {
		return airMapDemand
	}
	return airNoDemand
}

type airTrafficRun struct {
	State                airRuleState
	Aircraft             []airAircraft
	Received             time.Time
	LastAttempt, RetryAt time.Time
	LastPush, PushedData time.Time
	Failures             int
	FetchError           string
	FetchID              uint64
	Inflight             bool
	CancelFetch          context.CancelFunc
	Demand               airTrafficDemand
}

func (run *airTrafficRun) stopFetch() {
	if run.CancelFetch != nil {
		run.CancelFetch()
		run.CancelFetch = nil
		run.FetchID++
	}
}

func (run *airTrafficRun) reset(keepSchedule bool) {
	run.stopFetch()
	next := airTrafficRun{FetchID: run.FetchID, Inflight: run.Inflight}
	if keepSchedule {
		next.LastAttempt, next.RetryAt = run.LastAttempt, run.RetryAt
		next.Failures, next.FetchError = run.Failures, run.FetchError
		next.Demand = run.Demand
	}
	*run = next
}

func (run *airTrafficRun) updateDemand(next airTrafficDemand, firstLive bool) {
	if next == airDroneDemand && (firstLive || run.Demand != airDroneDemand) &&
		run.CancelFetch == nil && run.Failures == 0 {
		// A first live drone may request a fetch immediately after a map
		// fetch, provided that request has finished without a backoff.
		run.LastAttempt = time.Time{}
	}
	run.Demand = next
}

func (run *airTrafficRun) nextFetch() time.Time {
	interval := 10 * time.Second
	if run.Demand == airMapDemand {
		interval = 30 * time.Second
	}
	normal := run.LastAttempt.Add(interval)
	if run.RetryAt.After(normal) {
		return run.RetryAt
	}
	return normal
}

func (run *airTrafficRun) due(now time.Time) bool {
	return run.Demand != airNoDemand && !run.Inflight && !now.Before(run.nextFetch())
}

func (run *airTrafficRun) backOff(err error, now time.Time) {
	run.Failures++
	run.FetchError = err.Error()
	run.RetryAt = now.Add((10 << min(run.Failures, 4)) * time.Second)
	var httpError airFetchHTTPError
	if errors.As(err, &httpError) && httpError.RetryAt.After(run.RetryAt) {
		run.RetryAt = httpError.RetryAt
	}
}

func (run *airTrafficRun) accept(result airFetchResult, now time.Time, demand airTrafficDemand, source string) {
	// A canceled request still occupies the only slot until its worker
	// reports completion. Its stale result cannot update a new run.
	run.Inflight = false
	if result.Generation != run.FetchID {
		// A settings change that races a response may discard aircraft, but
		// a rate-limit deadline from that same source is still valid.
		var httpError airFetchHTTPError
		if result.Source == source && errors.As(result.Err, &httpError) && !httpError.RetryAt.IsZero() {
			run.backOff(result.Err, now)
		}
		return
	}
	if run.CancelFetch != nil {
		run.CancelFetch()
		run.CancelFetch = nil
	}
	if result.Err != nil {
		run.backOff(result.Err, now)
		return
	}
	run.FetchError = ""
	run.Failures = 0
	run.RetryAt = time.Time{}
	if demand != airNoDemand {
		run.Aircraft = airMerge(run.Aircraft, result.Aircraft, result.Area, now)
		run.Received = now
	}
}

func (run *airTrafficRun) fetch(ctx context.Context, client *http.Client, results chan<- airFetchResult, template string, area airArea, now time.Time) {
	run.Inflight = true
	run.LastAttempt = now
	run.FetchID++
	id := run.FetchID
	requestContext, cancel := context.WithCancel(ctx)
	run.CancelFetch = cancel
	go func() {
		aircraft, err := airFetch(requestContext, client, template, area)
		select {
		case <-ctx.Done():
		case results <- airFetchResult{Aircraft: aircraft, Err: err, Area: area, Source: template, Generation: id}:
		}
	}()
}

func airDrones(tracks []Track, demo bool) []airDrone {
	result := make([]airDrone, 0, len(tracks))
	for _, track := range tracks {
		if demo != track.Simulated {
			continue
		}
		result = append(result, airDrone{
			ID: track.ID, Label: track.Title, Lat: track.Lat, Lon: track.Lon, Alt: track.AltGeo,
			Speed: track.Speed, Heading: track.Heading, Height: track.Height, Live: !track.Stale,
		})
	}
	return result
}

func airDemo(now time.Time, drones []airDrone) []airAircraft {
	center := GeoPoint{Lat: 37.8039, Lon: -122.4640}
	alt := 130.0
	for _, drone := range drones {
		if p := drone.point(); p != nil {
			center = *p
			if airAltitude(drone.Alt) {
				alt = *drone.Alt + 50
			}
			break
		}
	}
	distance := 620.0 + 80*math.Sin(float64(now.Unix()%600)/10)
	lonScale := 111111 * math.Cos(center.Lat*trafficDeg)
	return []airAircraft{
		{
			ID: "a1b2c3", Callsign: "UAL123", Type: "B738", Point: GeoPoint{Lat: center.Lat + distance/111111, Lon: center.Lon + 250/lonScale},
			Alt: airNumber(alt), BaroAlt: airNumber(808), Speed: airNumber(180 * trafficKnots), Heading: airNumber(245),
			VSpeed: airNumber(-640 * trafficFeet / 60), Squawk: 1200, Seen: now.Add(-2 * time.Second),
		},
		{
			ID: "a4d5e6", Callsign: "SWA4211", Type: "B737", Point: GeoPoint{Lat: center.Lat + 0.035, Lon: center.Lon - 0.025},
			Alt: airNumber(3380), BaroAlt: airNumber(3352), Speed: airNumber(290 * trafficKnots), Heading: airNumber(70),
			VSpeed: airNumber(0), Squawk: 3421, Seen: now.Add(-4 * time.Second),
		},
	}
}

func airTFRReference(home *GeoPoint, drones []airDrone) *GeoPoint {
	if airValidPoint(home) {
		return home
	}
	var reference *GeoPoint
	var totalLat, totalLon float64
	count := 0
	for _, d := range drones {
		if point := d.point(); d.Live && point != nil {
			if reference == nil {
				reference = point
			}
			totalLat += point.Lat
			totalLon += airWrap(point.Lon - reference.Lon)
			count++
		}
	}
	if count == 0 {
		return nil
	}
	return &GeoPoint{Lat: totalLat / float64(count), Lon: airWrap(reference.Lon + totalLon/float64(count))}
}

type airDeviceRun struct {
	Session, Revision, ClockRevision uint64
	Home                             *GeoPoint
}

func airHomeChanged(previous, current *GeoPoint) bool {
	if previous == nil || current == nil {
		return previous != current
	}
	return *previous != *current
}

func (run *airDeviceRun) sendContext(receiver *Receiver, state ReceiverState, home *GeoPoint, zones []tfrZone, rev uint64, drones []airDrone, now time.Time) {
	if state.Status != "receiving" || state.Session == 0 {
		return
	}
	if run.Session != state.Session {
		run.Session, run.Revision, run.ClockRevision, run.Home = state.Session, 0, 0, nil
	}
	if rev != run.ClockRevision &&
		receiver.SendFor(state.Session, map[string]any{"cmd": "set_time", "utc": now.Unix()}) == nil {
		run.ClockRevision = rev
	}
	if rev == 0 || rev == run.Revision && !airHomeChanged(run.Home, home) ||
		!slices.Contains(state.Capabilities, "tfr") && len(state.Capabilities) > 0 {
		return
	}
	reference := airTFRReference(home, drones)
	commands := tfrCommands(zones, reference)
	if len(commands) == 0 {
		return
	}
	for _, command := range commands {
		if receiver.SendFor(state.Session, command) != nil {
			return
		}
	}
	run.Revision = rev
	run.Home = home
}

func (run *airTrafficRun) push(receiver *Receiver, state ReceiverState, now time.Time) {
	takesTraffic := slices.Contains(state.Capabilities, "traffic") ||
		len(state.Capabilities) == 0 && state.Board == "lilygo-t5-epaper-s3-pro"
	if state.Status != "receiving" || !takesTraffic || run.Received.IsZero() || airAge(run.Received, now) > trafficPresent ||
		run.PushedData.Equal(run.Received) && now.Sub(run.LastPush) < 10*time.Second {
		return
	}
	for _, command := range airHostCommands(run.Aircraft, run.Received, now) {
		if err := receiver.SendFor(state.Session, command); err != nil {
			return
		}
	}
	run.LastPush, run.PushedData = now, run.Received
}

func (service *airspaceService) run(ctx context.Context, receiver *Receiver, location func() *GeoPoint) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	results := make(chan airFetchResult, 1)
	client := &http.Client{Timeout: 8 * time.Second}
	var run airTrafficRun
	var device airDeviceRun
	var previous airspaceSettings
	var lastSession, liveRIDEpoch uint64
	var wasDemo, hadArea bool
	var lastHome *GeoPoint
	for {
		var result *airFetchResult
		select {
		case <-ctx.Done():
			return
		case fetched := <-results:
			result = &fetched
		case <-receiver.trafficWake:
		case <-service.wakeTraffic:
		case <-ticker.C:
		}
		now := time.Now()
		snapshot := receiver.Snapshot()
		var home *GeoPoint
		if location != nil {
			home = location()
		}
		homeChanged := airHomeChanged(lastHome, home)
		lastHome = home
		service.mu.Lock()
		settings, zones, revision := service.settings, service.zones, service.view.TFRRevision
		mapVisible := now.Before(service.mapVisibleUntil)
		service.mu.Unlock()
		areaChanged := settings.RadiusKm != previous.RadiusKm || homeChanged && !snapshot.Demo
		if snapshot.Demo != wasDemo || settings != previous || areaChanged {
			run.reset(settings.Source == previous.Source)
			// An area change needs fresh data when no retry/backoff is
			// pending. Changing the query cannot bypass a source cooldown.
			if areaChanged && run.Failures == 0 {
				run.LastAttempt = time.Time{}
			}
		}
		if lastSession != snapshot.Session {
			run.PushedData, run.LastPush = time.Time{}, time.Time{}
			lastSession = snapshot.Session
		}
		previous, wasDemo = settings, snapshot.Demo
		drones := airDrones(snapshot.Tracks, snapshot.Demo)
		area := airMakeArea(home, drones, settings.RadiusKm)
		if hadArea && area == nil && !snapshot.Demo {
			run.reset(true)
		}
		hadArea = area != nil
		demand := airDemandFor(settings.Enabled, snapshot.Demo, area != nil,
			mapVisible && desktopWindowVisible(), drones)
		if result != nil {
			run.accept(*result, now, demand, settings.Source)
		}
		run.updateDemand(demand, liveRIDEpoch != snapshot.liveRIDEpoch)
		liveRIDEpoch = snapshot.liveRIDEpoch
		status, code := "Conflict watch off", "off"
		alerts := []airAlert{}
		var trafficAge *float64
		if settings.Enabled {
			if snapshot.Demo {
				run.Received = now.Add(-2 * time.Second)
				run.Aircraft = airDemo(now, drones)
				home = nil
			} else if run.due(now) {
				run.fetch(ctx, client, results, settings.Source, *area, now)
			}
			if area != nil || snapshot.Demo {
				run.Aircraft = slices.DeleteFunc(run.Aircraft, func(a airAircraft) bool { return airAge(a.Seen, now) > trafficPresent })
				alerts = run.State.evaluate(drones, run.Aircraft, airObserver{Point: home}, run.Received, now)
			}
			if !run.Received.IsZero() {
				trafficAge = airNumber(airAge(run.Received, now))
			}
			switch {
			case snapshot.Demo:
				status, code = "SIMULATION ACTIVE", "simulation"
				for i := range alerts {
					alerts[i].Simulated = true
				}
			case area == nil:
				status, code = "Waiting for a position", "position"
			case demand == airNoDemand:
				status, code = "Waiting for a drone or a visible map", "idle"
			case !run.Received.IsZero() && airAge(run.Received, now) > trafficFresh:
				status, code = airTrafficSummary(alerts, run.Received, now), "stale"
			case run.FetchError != "":
				wait := max(0, int(math.Ceil(run.nextFetch().Sub(now).Seconds())))
				status, code = fmt.Sprintf("ADS-B fetch failed (%s); retry in %d s", run.FetchError, wait), "error"
			case run.Received.IsZero():
				status, code = "Waiting for ADS-B data", "loading"
			default:
				status, code = airTrafficSummary(alerts, run.Received, now), "ready"
			}
		}

		trackTFRs := make(map[string]string)
		for _, drone := range drones {
			point := drone.point()
			if !drone.Live || point == nil {
				continue
			}
			for _, zone := range zones {
				if zone.contains(*point) {
					trackTFRs[drone.ID] = zone.NOTAM
					break
				}
			}
		}
		service.mu.Lock()
		if service.settings == settings {
			service.view.Alerts = alerts
			service.view.TrafficState = code
			service.view.TrafficStatus = status
			service.view.TrafficAge = trafficAge
		}
		if service.view.TFRRevision == revision {
			service.view.TrackTFRs = trackTFRs
		}
		service.mu.Unlock()

		if !snapshot.Demo {
			device.sendContext(receiver, snapshot, home, zones, revision, drones, now)
			if settings.Enabled && area != nil {
				run.push(receiver, snapshot, now)
			}
		}
	}
}
