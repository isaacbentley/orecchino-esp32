// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

const (
	droneguideImportSource = "Droneguide · JSON-import"
	droneguideLiveSource   = "Droneguide (skeyes) · online"
	droneguideMaxJSON      = 12 << 20
	droneguideRefreshEvery = 15 * time.Minute
	droneguideMaxDiskState = 2*droneguideMaxJSON + 64<<10
)

type droneguideView struct {
	State                string            `json:"state"`
	Count                int               `json:"count"`
	Revision             uint64            `json:"revision"`
	ActivityRevision     uint64            `json:"activityRevision"`
	ActiveOnly           bool              `json:"activeOnly"`
	ActiveCount          int               `json:"activeCount"`
	UnknownActivityCount int               `json:"unknownActivityCount"`
	Source               string            `json:"source"`
	SourceType           string            `json:"sourceType"`
	LiveEnabled          bool              `json:"liveEnabled"`
	UnknownAltitudeCount int               `json:"unknownAltitudeCount"`
	OmittedCount         int               `json:"omittedCount"`
	Stale                bool              `json:"stale"`
	UpdatedAt            *time.Time        `json:"updatedAt,omitempty"`
	SnapshotAt           *time.Time        `json:"snapshotAt,omitempty"`
	Error                string            `json:"error,omitempty"`
	Zones                *[]droneguideZone `json:"zones,omitempty"`
}

type droneguideSnapshot struct {
	Raw                  json.RawMessage  `json:"data"`
	UpdatedAt            time.Time        `json:"updatedAt"`
	SnapshotAt           *time.Time       `json:"snapshotAt,omitempty"`
	Zones                []droneguideZone `json:"-"`
	Omitted              int              `json:"-"`
	UnknownAltitudeCount int              `json:"-"`
}

type droneguideDiskState struct {
	Version     int                 `json:"version"`
	LiveEnabled bool                `json:"liveEnabled"`
	ActiveOnly  bool                `json:"activeOnly"`
	Manual      *droneguideSnapshot `json:"manual,omitempty"`
	Live        *droneguideSnapshot `json:"live,omitempty"`
}

type droneguideService struct {
	mu               sync.Mutex
	ctx              context.Context
	path             string
	config           droneguideDiskState
	shown            *droneguideSnapshot
	state, lastError string
	revision         uint64
	activityRevision uint64
	lastActivity     []droneguideActivity
	client           *http.Client
	endpoint         string
	fetchCancel      context.CancelFunc
	generation       uint64
	lastAttempt      time.Time
}

func registerDroneguide(mux *http.ServeMux, dataDir string) func() {
	client := &http.Client{
		Timeout: 38 * time.Second,
		CheckRedirect: func(r *http.Request, via []*http.Request) error {
			if len(via) >= 3 || r.URL.Scheme != "https" || r.URL.Host != "map.droneguide.be" {
				return errors.New("onverwachte Droneguide-omleiding")
			}
			return nil
		},
	}
	return registerDroneguideSource(mux, dataDir, client, droneguideWFSEndpoint)
}

func registerDroneguideSource(mux *http.ServeMux, dataDir string, client *http.Client, endpoint string) func() {
	ctx, cancel := context.WithCancel(context.Background())
	service := &droneguideService{
		ctx: ctx, path: filepath.Join(dataDir, "droneguide-state.json"),
		config: droneguideDiskState{Version: 1}, state: "empty",
		client: client, endpoint: endpoint,
	}
	err := service.load(filepath.Join(dataDir, "droneguide.json"))
	service.choose()
	if err != nil {
		service.state, service.lastError = "error", "Opgeslagen Droneguide-gegevens laden mislukt. "+err.Error()
	}
	mux.HandleFunc("GET /api/droneguide", service.get)
	mux.HandleFunc("POST /api/droneguide/import", service.importFile)
	mux.HandleFunc("POST /api/droneguide/live", service.setLive)
	mux.HandleFunc("POST /api/droneguide/refresh", service.refresh)
	mux.HandleFunc("POST /api/droneguide/filter", service.setFilter)
	if service.config.LiveEnabled {
		service.startRefresh()
	}
	go service.periodicRefresh()
	return cancel
}

func readDroneguideFile(path string, limit int64) ([]byte, time.Time, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, time.Time{}, err
	}
	if info.Size() > limit {
		return nil, time.Time{}, errors.New("het bestand overschrijdt de groottebeperking")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, time.Time{}, err
	}
	if int64(len(data)) > limit {
		return nil, time.Time{}, errors.New("het bestand overschrijdt de groottebeperking")
	}
	return data, info.ModTime().UTC(), nil
}

func (service *droneguideService) load(legacy string) error {
	data, _, err := readDroneguideFile(service.path, droneguideMaxDiskState)
	if err == nil {
		var config droneguideDiskState
		if json.Unmarshal(data, &config) != nil || config.Version != 1 {
			return errors.New("onbekend cacheformaat")
		}
		var parseError error
		for _, entry := range []struct {
			dataset **droneguideSnapshot
			live    bool
		}{{&config.Manual, false}, {&config.Live, true}} {
			snapshot := *entry.dataset
			if snapshot == nil {
				continue
			}
			if len(snapshot.Raw) > droneguideMaxJSON || snapshot.UpdatedAt.IsZero() ||
				entry.live != (snapshot.SnapshotAt != nil) {
				parseError = errors.New("beschadigde gecachte dataset")
				*entry.dataset = nil
				continue
			}
			zones, omitted, err := parseDroneguideSnapshot(snapshot.Raw, entry.live)
			if err != nil {
				parseError = err
				*entry.dataset = nil
				continue
			}
			snapshot.selectAltitudeBand(zones, omitted)
		}
		service.config = config
		return parseError
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	// Retain imports from earlier builds that stored just the source file.
	raw, updatedAt, err := readDroneguideFile(legacy, droneguideMaxJSON)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	raw = droneguideJSONBytes(raw)
	zones, err := parseDroneguide(raw)
	if err != nil {
		return err
	}
	service.config.Manual = &droneguideSnapshot{Raw: raw, UpdatedAt: updatedAt}
	service.config.Manual.selectAltitudeBand(zones, 0)
	return nil
}

// The candidate settings and both datasets share one atomic transaction.
func (service *droneguideService) persist(config droneguideDiskState) error {
	var data bytes.Buffer
	encoder := json.NewEncoder(&data)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(config); err != nil {
		return err
	}
	if data.Len() > droneguideMaxDiskState {
		return errors.New("de Droneguide-cache overschrijdt de groottebeperking")
	}
	return writeDroneguideFile(service.path, data.Bytes())
}

func (service *droneguideService) choose() {
	target := service.config.Manual
	if (service.config.LiveEnabled || target == nil) && service.config.Live != nil {
		target = service.config.Live
	}
	if target != service.shown {
		service.shown = target
		service.revision++
	}
	service.state, service.lastError = "empty", ""
	if target != nil {
		service.state = "ready"
	}
}

func (service *droneguideService) snapshot(includeZones bool, now time.Time) droneguideView {
	view := droneguideView{
		State: service.state, Revision: service.revision, Error: service.lastError,
		LiveEnabled: service.config.LiveEnabled, ActiveOnly: service.config.ActiveOnly,
		Source: droneguideImportSource, SourceType: "import",
	}
	zones := []droneguideZone{}
	if service.shown != nil {
		zones = service.shown.Zones
		view.OmittedCount = service.shown.Omitted
		view.UnknownAltitudeCount = service.shown.UnknownAltitudeCount
		view.UpdatedAt = &service.shown.UpdatedAt
		view.SnapshotAt = service.shown.SnapshotAt
		view.Stale = view.LiveEnabled && view.State == "error"
		if view.SnapshotAt != nil {
			view.Source, view.SourceType = droneguideLiveSource, "live"
			view.Stale = view.Stale || !view.LiveEnabled || now.Before(*view.SnapshotAt) ||
				now.Sub(*view.SnapshotAt) >= 2*droneguideRefreshEvery
		}
	} else if view.LiveEnabled {
		view.Source, view.SourceType = droneguideLiveSource, "live"
	}
	view.Count = len(zones)
	activityChanged := len(service.lastActivity) != len(zones)
	if activityChanged {
		service.lastActivity = make([]droneguideActivity, len(zones))
	}
	for index, zone := range zones {
		activity := droneguideZoneActivity(zone, view, now)
		if service.lastActivity[index] != activity {
			service.lastActivity[index] = activity
			activityChanged = true
		}
		switch activity {
		case droneguideActivityActive:
			view.ActiveCount++
		case droneguideActivityUnknown:
			view.UnknownActivityCount++
		}
	}
	if activityChanged {
		service.activityRevision++
	}
	view.ActivityRevision = service.activityRevision
	if includeZones {
		zones = slices.Clone(zones)
		for index := range zones {
			zones[index].Activity = service.lastActivity[index].label()
		}
		view.Zones = &zones
	}
	return view
}

func (service *droneguideService) get(w http.ResponseWriter, r *http.Request) {
	service.mu.Lock()
	view := service.snapshot(r.URL.Query().Get("zones") != "0", time.Now())
	service.mu.Unlock()
	replyJSON(w, http.StatusOK, view)
}

func (service *droneguideService) setFilter(w http.ResponseWriter, r *http.Request) {
	var request struct {
		ActiveOnly *bool `json:"activeOnly"`
	}
	if !readRequest(w, r, &request) {
		return
	}
	if request.ActiveOnly == nil {
		replyError(w, http.StatusBadRequest, errors.New("geef aan of alleen actieve Droneguide-zones worden getoond"))
		return
	}

	service.mu.Lock()
	config := service.config
	if config.ActiveOnly != *request.ActiveOnly {
		config.ActiveOnly = *request.ActiveOnly
		if err := service.persist(config); err != nil {
			service.mu.Unlock()
			replyError(w, http.StatusInternalServerError, errors.New("de Droneguide-filter kan niet worden opgeslagen"))
			return
		}
		service.config = config
	}
	view := service.snapshot(false, time.Now())
	service.mu.Unlock()
	replyJSON(w, http.StatusOK, view)
}

func (service *droneguideService) importFile(w http.ResponseWriter, r *http.Request) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, droneguideMaxJSON))
	if err != nil {
		var limit *http.MaxBytesError
		if errors.As(err, &limit) {
			replyError(w, http.StatusRequestEntityTooLarge, errors.New("het bestand is groter dan 12 MiB"))
			return
		}
		replyError(w, http.StatusBadRequest, errors.New("het JSON-bestand kan niet worden gelezen"))
		return
	}
	data = droneguideJSONBytes(data)
	zones, err := parseDroneguide(data)
	if err != nil {
		replyError(w, http.StatusBadRequest, err)
		return
	}

	service.mu.Lock()
	config := service.config
	config.LiveEnabled = false
	config.Manual = &droneguideSnapshot{Raw: data, UpdatedAt: time.Now().UTC()}
	config.Manual.selectAltitudeBand(zones, 0)
	if err := service.persist(config); err != nil {
		service.mu.Unlock()
		replyError(w, http.StatusInternalServerError, errors.New("de Droneguide-import kan niet worden opgeslagen"))
		return
	}
	service.cancelRefresh()
	service.config = config
	service.choose()
	view := service.snapshot(false, time.Now())
	service.mu.Unlock()
	replyJSON(w, http.StatusOK, view)
}

func (service *droneguideService) setLive(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Enabled *bool `json:"enabled"`
	}
	if !readRequest(w, r, &request) {
		return
	}
	if request.Enabled == nil {
		replyError(w, http.StatusBadRequest, errors.New("geef aan of live ophalen aan of uit staat"))
		return
	}
	service.mu.Lock()
	config := service.config
	if config.LiveEnabled != *request.Enabled {
		config.LiveEnabled = *request.Enabled
		if err := service.persist(config); err != nil {
			service.mu.Unlock()
			replyError(w, http.StatusInternalServerError, errors.New("de instelling voor live Droneguide kan niet worden opgeslagen"))
			return
		}
		service.config = config
		if !config.LiveEnabled {
			service.cancelRefresh()
		}
		service.choose()
	}

	code := http.StatusOK
	if config.LiveEnabled {
		service.startRefresh()
		code = http.StatusAccepted
	}
	view := service.snapshot(false, time.Now())
	service.mu.Unlock()
	replyJSON(w, code, view)
}

func (service *droneguideService) refresh(w http.ResponseWriter, _ *http.Request) {
	service.mu.Lock()
	if !service.config.LiveEnabled {
		service.mu.Unlock()
		replyError(w, http.StatusConflict, errors.New("schakel live Droneguide in om online te vernieuwen"))
		return
	}
	service.startRefresh()
	view := service.snapshot(false, time.Now())
	service.mu.Unlock()
	replyJSON(w, http.StatusAccepted, view)
}

// All refresh state transitions run under mu, including the final cache write.
func (service *droneguideService) startRefresh() {
	if service.fetchCancel != nil || service.ctx.Err() != nil {
		return
	}
	ctx, cancel := context.WithTimeout(service.ctx, 45*time.Second)
	service.fetchCancel = cancel
	service.generation++
	generation := service.generation
	start := time.Now().UTC().Truncate(time.Millisecond)
	service.lastAttempt = start
	service.state, service.lastError = "loading", ""
	go func() {
		raw, zones, omitted, err := fetchDroneguideWFS(ctx, service.client, service.endpoint, start)
		service.mu.Lock()
		defer service.mu.Unlock()
		if generation != service.generation || service.ctx.Err() != nil {
			return
		}
		service.cancelRefresh()
		if err != nil {
			service.state, service.lastError = "error", err.Error()
			return
		}
		config := service.config
		config.Live = &droneguideSnapshot{Raw: raw, UpdatedAt: time.Now().UTC(), SnapshotAt: &start}
		config.Live.selectAltitudeBand(zones, omitted)
		if err := service.persist(config); err != nil {
			service.state, service.lastError = "error", "De online Droneguide-gegevens kunnen niet worden opgeslagen."
			return
		}
		service.config = config
		service.choose()
	}()
}

func (service *droneguideService) cancelRefresh() {
	service.generation++
	if service.fetchCancel != nil {
		service.fetchCancel()
		service.fetchCancel = nil
	}
}

func (service *droneguideService) periodicRefresh() {
	// A one-minute scheduler keeps the next periodic request spaced from a
	// recent manual refresh as well as one that started automatically.
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-service.ctx.Done():
			return
		case <-ticker.C:
			service.mu.Lock()
			if service.config.LiveEnabled && time.Since(service.lastAttempt) >= droneguideRefreshEvery {
				service.startRefresh()
			}
			service.mu.Unlock()
		}
	}
}

func writeDroneguideFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, "droneguide-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
