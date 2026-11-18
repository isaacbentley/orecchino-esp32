// Orecchino Windows adaptation of the offline map sender in TileSync.swift.
// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"image/jpeg"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	tileReserve     int64 = 1024 * 1024
	tileMargin      int64 = 16 * 1024
	tileMaxJPEG           = 64 * 1024
	tileChunkSize         = 768
	tileURLTemplate       = "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/%d/%d/%d"
)

type tileInput struct {
	Lat      float64 `json:"lat"`
	Lon      float64 `json:"lon"`
	RadiusKm float64 `json:"radiusKm"`
}

type tileState struct {
	Phase        string    `json:"phase"`
	Completed    int       `json:"completed"`
	Total        int       `json:"total"`
	Remaining    int       `json:"remaining"`
	Error        string    `json:"error,omitempty"`
	Plan         *tilePlan `json:"plan,omitempty"`
	StorageKnown bool      `json:"storageKnown"`
	input        tileInput
	session      uint64
}

func tileFlashSize(size int64) int64 {
	return (size + 4095) / 4096 * 4096
}

func (d *deviceAPI) tileStatus() tileState {
	d.tilesMu.RLock()
	defer d.tilesMu.RUnlock()
	return d.tiles
}

func (d *deviceAPI) setTileStatus(status tileState) {
	d.tilesMu.Lock()
	d.tiles = status
	d.tilesMu.Unlock()
}

func (d *deviceAPI) tileStatusHTTP(w http.ResponseWriter, _ *http.Request) {
	deviceJSON(w, http.StatusOK, d.tileStatus())
}

func readTileInput(w http.ResponseWriter, r *http.Request) (tileInput, bool) {
	var input tileInput
	var fields struct {
		Lat      *float64 `json:"lat"`
		Lon      *float64 `json:"lon"`
		RadiusKm float64  `json:"radiusKm"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048))
	if err := decoder.Decode(&fields); err != nil || fields.Lat == nil || fields.Lon == nil {
		deviceJSON(w, http.StatusBadRequest, map[string]string{"error": "voer een breedtegraad en lengtegraad in"})
		return input, false
	}
	input = tileInput{Lat: *fields.Lat, Lon: *fields.Lon, RadiusKm: fields.RadiusKm}
	if input.RadiusKm == 0 {
		input.RadiusKm = 3
	}
	if input.Lat < -85 || input.Lat > 85 || input.Lon < -180 || input.Lon > 180 || input.RadiusKm < 1 || input.RadiusKm > 30 {
		deviceJSON(w, http.StatusBadRequest, map[string]string{"error": "gebruik een breedtegraad van −85 tot 85°, een lengtegraad van −180 tot 180° en een straal van 1 tot 30 km"})
		return input, false
	}
	return input, true
}

func (d *deviceAPI) planTilesHTTP(w http.ResponseWriter, r *http.Request) {
	input, ok := readTileInput(w, r)
	if !ok {
		return
	}
	if !d.operation.TryLock() {
		deviceError(w, errDeviceBusy)
		return
	}
	defer d.operation.Unlock()

	state := tileState{Phase: "planning", input: input}
	d.setTileStatus(state)
	link, err := d.openLink()
	if err != nil {
		d.tileFailed(state, err)
		deviceError(w, err)
		return
	}
	defer link.close()
	state.session = link.state.Session
	ctx, cancel := context.WithTimeout(context.Background(), 70*time.Second)
	defer cancel()
	files, total, used, known, err := tileInventory(ctx, link, input, true)
	if err != nil {
		d.tileFailed(state, err)
		deviceError(w, err)
		return
	}
	if !known {
		for _, size := range files {
			used += tileFlashSize(size)
		}
		total = 1 << 40
	}
	plan := makeTilePlan(input, total, used, files)
	if !known {
		plan.CapacityBytes, plan.FreeBytes = 0, 0
	}
	state.Phase = "planned"
	state.Plan = &plan
	state.StorageKnown = known
	state.Total = plan.TileCount
	d.setTileStatus(state)
	deviceJSON(w, http.StatusOK, state)
}

func (d *deviceAPI) sendTilesHTTP(w http.ResponseWriter, r *http.Request) {
	input, ok := readTileInput(w, r)
	if !ok {
		return
	}
	if !d.operation.TryLock() {
		deviceError(w, errDeviceBusy)
		return
	}
	state := d.tileStatus()
	link, err := d.openLink()
	if err != nil {
		d.operation.Unlock()
		deviceError(w, err)
		return
	}
	if state.Plan == nil || state.input != input || state.session != link.state.Session || !state.StorageKnown {
		link.close()
		d.operation.Unlock()
		deviceJSON(w, http.StatusConflict, map[string]string{"error": "plan de kaart eerst met deze ontvanger aangesloten. De ontvanger moet zijn opslagruimte kunnen uitlezen"})
		return
	}

	state.Phase = "downloading"
	state.Completed = 0
	state.Total = state.Plan.TileCount
	state.Remaining = 0
	state.Error = ""
	d.setTileStatus(state)
	go func() {
		defer d.operation.Unlock()
		defer link.close()
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
		defer cancel()
		if err := d.transferTiles(ctx, link, state); err != nil {
			d.tileFailed(d.tileStatus(), err)
		}
	}()
	deviceJSON(w, http.StatusAccepted, state)
}

func (d *deviceAPI) tileFailed(state tileState, err error) {
	state.Phase = "failed"
	state.Error = err.Error()
	d.setTileStatus(state)
}

func tileInventory(ctx context.Context, link *deviceLink, input tileInput, allowUnknown bool) (map[string]int64, int64, int64, bool, error) {
	total, used, err := tileStorage(ctx, link, input)
	known := err == nil
	if err != nil && !(allowUnknown && errors.Is(err, errDeviceTimeout)) {
		return nil, 0, 0, false, err
	}

	if err := link.send(map[string]any{"cmd": "fs_ls"}); err != nil {
		return nil, 0, 0, false, err
	}
	files := make(map[string]int64)
	seen := int64(0)
	for {
		line, err := link.receive(ctx, 15*time.Second, func(line map[string]any) bool {
			switch deviceString(line, "type") {
			case "fs_f", "fs_ls_done", "fs_err":
				return true
			}
			return false
		})
		if err != nil {
			return nil, 0, 0, false, err
		}
		switch deviceString(line, "type") {
		case "fs_f":
			seen++
			path := deviceString(line, "p")
			size := intValue(deviceInt(line, "s"), -1)
			// Only valid tile names may become firmware eviction candidates or cache paths.
			if _, valid := parseTilePath(path); valid && size > 0 && size <= 256*1024 {
				files[path] = size
			}
		case "fs_ls_done":
			if reported := deviceInt(line, "n"); reported != nil && *reported != seen {
				return nil, 0, 0, false, errors.New("de bestandslijst van de ontvanger is onvolledig. Plan de kaart opnieuw")
			}
			return files, total, used, known, nil
		case "fs_err":
			return nil, 0, 0, false, tileReceiverError(line)
		}
	}
}

func tileStorage(ctx context.Context, link *deviceLink, input tileInput) (int64, int64, error) {
	command := map[string]any{"cmd": "fs_stat", "lat": input.Lat, "lon": input.Lon}
	if err := link.send(command); err != nil {
		return 0, 0, err
	}
	line, err := link.receive(ctx, 5*time.Second, func(line map[string]any) bool {
		kind := deviceString(line, "type")
		return kind == "fs_stat" || kind == "fs_err"
	})
	if err != nil {
		return 0, 0, err
	}
	if deviceString(line, "type") == "fs_err" {
		return 0, 0, tileReceiverError(line)
	}
	total := intValue(deviceInt(line, "total"), 0)
	used := intValue(deviceInt(line, "used"), -1)
	if total <= 0 || total > 1<<34 || used < 0 || used > total {
		return 0, 0, errors.New("de ontvanger gaf ongeldige opslagwaarden door")
	}
	return total, used, nil
}

func tileReceiverError(line map[string]any) error {
	if message := deviceString(line, "msg"); message != "" {
		return fmt.Errorf("de ontvanger heeft een kaartopdracht geweigerd (%s)", message)
	}
	return errors.New("de ontvanger heeft een kaartopdracht geweigerd")
}

func (d *deviceAPI) tileCachePath(receiverPath string) string {
	return filepath.Join(d.dataDir, "tiles-esri-dg1", filepath.FromSlash(strings.TrimPrefix(receiverPath, "/tiles/")))
}

func validTileJPEG(data []byte) bool {
	if len(data) == 0 || len(data) > tileMaxJPEG {
		return false
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(data))
	return err == nil && cfg.Width == 256 && cfg.Height == 256
}

func (d *deviceAPI) cacheTiles(ctx context.Context, link *deviceLink, state tileState) (map[string]int64, error) {
	client := &http.Client{Timeout: 12 * time.Second}
	sizes := make(map[string]int64)
	var fetchError error
	var lastHTTP time.Time
	for i, path := range state.Plan.paths {
		if !link.valid() {
			return nil, errDeviceDisconnected
		}
		state.Completed = i + 1
		cached, err := os.ReadFile(d.tileCachePath(path))
		if err == nil && validTileJPEG(cached) {
			sizes[path] = int64(len(cached))
			d.setTileStatus(state)
			continue
		}
		// After an unavailable service, keep looking for cached tiles.
		if fetchError != nil {
			d.setTileStatus(state)
			continue
		}
		if delay := time.Until(lastHTTP.Add(250 * time.Millisecond)); delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return nil, ctx.Err()
			case <-timer.C:
			}
		}
		lastHTTP = time.Now()
		image, responseErr := downloadTile(ctx, client, path)
		if responseErr != nil {
			fetchError = responseErr
		} else if len(image) > 0 {
			if err := writeDeviceFile(d.tileCachePath(path), image); err != nil {
				return nil, fmt.Errorf("kaarttegel opslaan: %w", err)
			}
			sizes[path] = int64(len(image))
		}
		d.setTileStatus(state)
	}
	if len(sizes) == 0 && fetchError != nil {
		return nil, fetchError
	}
	return sizes, nil
}

func downloadTile(ctx context.Context, client *http.Client, path string) ([]byte, error) {
	key, ok := parseTilePath(path)
	if !ok {
		return nil, errors.New("ongeldig pad voor kaarttegel")
	}
	url := fmt.Sprintf(tileURLTemplate, key.zoom, key.y, key.x)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "Orecchino/1.0 (Windows; offline map for an Orecchino receiver)")
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("kaartenservice onbereikbaar: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusNoContent {
		return nil, nil
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("kaartenservice antwoordde met HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, tileMaxJPEG+1))
	if err != nil {
		return nil, err
	}
	if !validTileJPEG(data) {
		return nil, nil
	}
	return data, nil
}

func (d *deviceAPI) transferTiles(ctx context.Context, link *deviceLink, state tileState) error {
	if state.Plan.TileCount == 0 {
		return errors.New("deze kaart past niet in de opslag van de ontvanger")
	}
	sizes, err := d.cacheTiles(ctx, link, state)
	if err != nil {
		return err
	}

	// Recheck after downloading. The receiver may have updated its own tiles meanwhile.
	files, total, used, _, err := tileInventory(ctx, link, state.input, false)
	if err != nil {
		return err
	}
	plan := makeTilePlan(state.input, total, used, files)
	if plan.RadiiKm != state.Plan.RadiiKm {
		return errors.New("de opslagruimte van de ontvanger is veranderd. Plan de kaart opnieuw voor je ze verstuurt")
	}

	state.Phase = "sending"
	state.Completed, state.Total, state.Remaining = 0, 0, 0
	state.Plan = &plan
	for _, path := range plan.paths {
		size := sizes[path]
		png := strings.TrimSuffix(path, ".jpg") + ".png"
		if size > 0 && (files[path] != size || files[png] > 0) {
			state.Total++
		}
	}
	d.setTileStatus(state)

	free := plan.FreeBytes
	victims := plan.victims
	for _, path := range plan.paths {
		png := strings.TrimSuffix(path, ".jpg") + ".png"
		size := sizes[path]
		if size == 0 {
			if files[path] == 0 && files[png] == 0 {
				state.Remaining++
			}
			continue
		}
		previous := files[path]
		if previous == size && files[png] == 0 {
			continue
		}
		if previous != size {
			data, err := os.ReadFile(d.tileCachePath(path))
			if err != nil || int64(len(data)) != size || !validTileJPEG(data) {
				return errors.New("een opgeslagen kaarttegel is veranderd. Verstuur de kaart opnieuw")
			}
			// Allow headroom for a full new file plus LittleFS metadata before
			// any old version or in-plan PNG is removed.
			minFree := tileReserve + tileFlashSize(size) + tileMargin
			if free < minFree {
				total, used, err = tileStorage(ctx, link, state.input)
				if err != nil {
					return err
				}
				free = total - used
			}
			if free < minFree {
				n, recovered := 0, int64(0)
				for n < len(victims) && free+recovered < minFree {
					recovered += tileFlashSize(files[victims[n]])
					n++
				}
				if free+recovered < minFree {
					state.Remaining++
					continue
				}
				for _, victim := range victims[:n] {
					if err := removeTile(ctx, link, victim); err != nil {
						return err
					}
				}
				victims = victims[n:]
				total, used, err = tileStorage(ctx, link, state.input)
				if err != nil {
					return err
				}
				free = total - used
				if free < minFree {
					state.Remaining++
					continue
				}
			}
			if err := uploadTile(ctx, link, path, data); err != nil {
				return err
			}
			free += tileFlashSize(previous) - tileFlashSize(size)
		}
		if pngSize := files[png]; pngSize > 0 {
			if err := removeTile(ctx, link, png); err != nil {
				return err
			}
			free += tileFlashSize(pngSize)
		}
		state.Completed++
		if state.Completed%16 == 0 {
			total, used, err = tileStorage(ctx, link, state.input)
			if err != nil {
				return err
			}
			free = total - used
		}
		d.setTileStatus(state)
	}
	if state.Remaining == state.Plan.TileCount && state.Completed == 0 {
		d.setTileStatus(state)
		return errors.New("geen enkele geplande kaarttegel kon worden gekopieerd. Controleer de opslagruimte en internetverbinding")
	}
	state.Phase = "done"
	d.setTileStatus(state)
	return nil
}

func tileExchange(ctx context.Context, link *deviceLink, command map[string]any, reply string, seq *int, path string) error {
	if err := link.send(command); err != nil {
		return err
	}
	message, err := link.receive(ctx, 8*time.Second, func(line map[string]any) bool {
		kind := deviceString(line, "type")
		if kind == "fs_err" {
			return true
		}
		if kind != reply {
			return false
		}
		if number := deviceInt(line, "q"); seq != nil && number != nil && *number != int64(*seq) {
			return false
		}
		answerPath := deviceString(line, "p")
		return path == "" || answerPath == "" || path == answerPath
	})
	if err != nil {
		return err
	}
	if deviceString(message, "type") == "fs_err" {
		return tileReceiverError(message)
	}
	return nil
}

func removeTile(ctx context.Context, link *deviceLink, path string) error {
	if _, ok := parseTilePath(path); !ok {
		return errors.New("ongeldig pad om de kaarttegel te verwijderen")
	}
	return tileExchange(ctx, link, map[string]any{"cmd": "fs_rm", "p": path}, "fs_ok", nil, path)
}

func uploadTile(ctx context.Context, link *deviceLink, path string, data []byte) error {
	seq := 0
	if err := tileExchange(ctx, link, map[string]any{"cmd": "fs_begin", "p": path, "size": len(data)}, "ack", &seq, ""); err != nil {
		return err
	}
	for offset := 0; offset < len(data); offset += tileChunkSize {
		chunk := data[offset:min(offset+tileChunkSize, len(data))]
		seq++
		command := map[string]any{"cmd": "fs_data", "q": seq, "b64": base64.StdEncoding.EncodeToString(chunk)}
		if err := tileExchange(ctx, link, command, "ack", &seq, ""); err != nil {
			return err
		}
	}
	command := map[string]any{"cmd": "fs_end", "crc": crc32.ChecksumIEEE(data)}
	return tileExchange(ctx, link, command, "fs_ok", nil, path)
}
