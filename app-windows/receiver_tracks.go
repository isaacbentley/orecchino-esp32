// SPDX-License-Identifier: GPL-3.0-only
// Windows Remote ID track fusion port of Orecchino, by Isaac Bentley.
package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

const (
	receiverTrackLimit = 256
	receiverTrailLimit = 600
)

//go:embed receiver_uas_models.json
var receiverModelsJSON []byte

var receiverModels = func() (table struct {
	Manufacturers map[string]string
	Models        map[string]string
}) {
	if err := json.Unmarshal(receiverModelsJSON, &table); err != nil {
		panic(err)
	}
	return table
}()

type GeoPoint struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

type Track struct {
	ID                  string     `json:"id"`
	Title               string     `json:"title"`
	UasID               string     `json:"uasId,omitempty"`
	IDType              *int       `json:"idType,omitempty"`
	UAType              *int       `json:"uaType,omitempty"`
	Manufacturer        string     `json:"manufacturer,omitempty"`
	Model               string     `json:"model,omitempty"`
	MACs                []string   `json:"macs"`
	Sources             []string   `json:"sources"`
	Lat                 *float64   `json:"lat,omitempty"`
	Lon                 *float64   `json:"lon,omitempty"`
	OperatorLat         *float64   `json:"operatorLat,omitempty"`
	OperatorLon         *float64   `json:"operatorLon,omitempty"`
	OperatorAlt         *float64   `json:"operatorAlt,omitempty"`
	OperatorID          string     `json:"operatorId,omitempty"`
	OperatorDistance    *float64   `json:"operatorDistance,omitempty"`
	OperatorImplausible bool       `json:"operatorImplausible,omitempty"`
	Trail               []GeoPoint `json:"trail"`
	FirstSeen           time.Time  `json:"firstSeen"`
	LastSeen            time.Time  `json:"lastSeen"`
	AgeSeconds          float64    `json:"ageSeconds"`
	Stale               bool       `json:"stale"`
	Simulated           bool       `json:"simulated"`
	ColorIndex          int        `json:"colorIndex"`
	Height              *float64   `json:"height,omitempty"`
	HeightRef           *int       `json:"heightRef,omitempty"`
	AltGeo              *float64   `json:"altGeo,omitempty"`
	AltBaro             *float64   `json:"altBaro,omitempty"`
	Speed               *float64   `json:"speed,omitempty"`
	VSpeed              *float64   `json:"vspeed,omitempty"`
	Heading             *float64   `json:"heading,omitempty"`
	RSSI                *int       `json:"rssi,omitempty"`
	Channel             *int       `json:"channel,omitempty"`
	Status              *int       `json:"status,omitempty"`
	AuthState           string     `json:"authState,omitempty"`
	AuthTS              *int       `json:"authTs,omitempty"`
	Format              string     `json:"format,omitempty"`
	PHY                 string     `json:"phy,omitempty"`
	SSID                string     `json:"ssid,omitempty"`
	SSIDMismatch        bool       `json:"ssidMismatch,omitempty"`
	MsgCount            int        `json:"msgCount"`
	SelfDesc            string     `json:"selfDesc,omitempty"`
	InTFR               *bool      `json:"inTfr,omitempty"`
	TFRID               string     `json:"tfrId,omitempty"`
	Evidence            string     `json:"evidence"`
	HAcc                *int       `json:"hAcc,omitempty"`
	VAcc                *int       `json:"vAcc,omitempty"`
	BaroAcc             *int       `json:"baroAcc,omitempty"`
	SpdAcc              *int       `json:"spdAcc,omitempty"`
	TSAcc               *int       `json:"tsAcc,omitempty"`
	AreaCount           *int       `json:"areaCount,omitempty"`
	AreaRadius          *float64   `json:"areaRadius,omitempty"`
	AreaCeiling         *float64   `json:"areaCeiling,omitempty"`
	AreaFloor           *float64   `json:"areaFloor,omitempty"`
	ClassType           *int       `json:"classType,omitempty"`
	CatEU               *int       `json:"catEu,omitempty"`
	ClassEU             *int       `json:"classEu,omitempty"`

	lastFix    time.Time
	lastFixHAE *float64
	evidence   [5]bool
}

func textField(message map[string]any, key string) string {
	value, _ := message[key].(string)
	return value
}

func numberField(message map[string]any, key string) *float64 {
	value, ok := message[key].(float64)
	if !ok || math.IsNaN(value) || math.IsInf(value, 0) {
		return nil
	}
	return &value
}

func counterField(message map[string]any, key string) *int64 {
	number := numberField(message, key)
	if number == nil || *number < math.MinInt64 || *number >= math.MaxInt64 || math.Trunc(*number) != *number {
		return nil
	}
	value := int64(*number)
	return &value
}

func intField(message map[string]any, key string) *int {
	n := counterField(message, key)
	if n == nil || *n < math.MinInt32 || *n > math.MaxInt32 {
		return nil
	}
	value := int(*n)
	return &value
}

func boolField(message map[string]any, key string) *bool {
	value, ok := message[key].(bool)
	if !ok {
		return nil
	}
	return &value
}

func objectField(message map[string]any, key string) map[string]any {
	object, _ := message[key].(map[string]any)
	return object
}

func clipReceiverText(value string, limit int) string {
	runes := []rune(value)
	if len(runes) > limit {
		return string(runes[:limit])
	}
	return value
}

func knownAltitude(value *float64) *float64 {
	if value != nil && *value > -999 {
		return value
	}
	return nil
}

func validRIDPoint(lat, lon *float64) bool {
	return lat != nil && lon != nil && math.Abs(*lat) <= 90 && math.Abs(*lon) <= 180 &&
		(math.Abs(*lat) >= 5 || math.Abs(*lon) >= 5)
}

func trackDistance(a, b GeoPoint) float64 {
	const toRadians = math.Pi / 180
	lat, lon := (b.Lat-a.Lat)*toRadians, (b.Lon-a.Lon)*toRadians
	x, y := math.Sin(lat/2), math.Sin(lon/2)
	h := x*x + math.Cos(a.Lat*toRadians)*math.Cos(b.Lat*toRadians)*y*y
	return 6371000 * 2 * math.Atan2(math.Sqrt(max(0, h)), math.Sqrt(max(0, 1-h)))
}

func insertTrackValue(values []string, value string) []string {
	index := sort.SearchStrings(values, value)
	if index == len(values) || values[index] != value {
		values = append(values, "")
		copy(values[index+1:], values[index:])
		values[index] = value
	}
	return values
}

func (r *Receiver) ingestTrackLocked(message map[string]any, now time.Time, simulated bool) {
	mac := strings.ToUpper(clipReceiverText(strings.TrimSpace(textField(message, "mac")), 24))
	if mac == "" {
		return
	}
	basics, _ := message["basic_id"].([]any)
	var selectedBasic map[string]any
	for _, raw := range basics {
		basic, _ := raw.(map[string]any)
		if textField(basic, "uas_id") != "" {
			selectedBasic = basic
			break
		}
	}
	uas := clipReceiverText(strings.TrimSpace(textField(selectedBasic, "uas_id")), 48)
	indexPrefix := trackIndexPrefix(simulated)
	macKey, uasKey := indexPrefix+mac, indexPrefix+uas
	byMAC, byUAS := r.tracks[r.macIndex[macKey]], r.tracks[r.uasIndex[uasKey]]

	track := byUAS
	if track == nil && byMAC != nil && (uas == "" || byMAC.UasID == "" || byMAC.UasID == uas) {
		track = byMAC
	}
	if track != nil && byMAC != nil && track != byMAC && byMAC.UasID == "" {
		r.mergeTrackLocked(track, byMAC)
	}
	if track == nil {
		if !simulated {
			r.makeTrackRoomLocked()
		}
		r.nextTrack++
		track = &Track{
			ID: fmt.Sprintf("track-%d", r.nextTrack), Title: mac, FirstSeen: now, Simulated: simulated,
			ColorIndex: int(r.nextTrack - 1),
		}
		r.tracks[track.ID] = track
	}
	r.macIndex[macKey] = track.ID
	track.LastSeen = now
	track.MsgCount++
	track.MACs = insertTrackValue(track.MACs, mac)
	if uas != "" {
		r.uasIndex[uasKey] = track.ID
		track.Title, track.UasID = uas, uas
		track.IDType = intField(selectedBasic, "id_type")
		track.UAType = intField(selectedBasic, "ua_type")
		track.Manufacturer, track.Model = "", ""
		if track.IDType != nil && *track.IDType == 1 {
			serial := strings.ToUpper(uas)
			if len(serial) >= 5 {
				track.Manufacturer = receiverModels.Manufacturers[serial[:4]]
			}
			if len(serial) >= 8 {
				track.Model = receiverModels.Models[serial[:8]]
			}
		}
		track.evidence[0] = true
	}
	updateTrackDetails(track, message, now)
}

func trackIndexPrefix(simulated bool) string {
	if simulated {
		return "demo:"
	}
	return "live:"
}

func (r *Receiver) mergeTrackLocked(track, old *Track) {
	for _, mac := range old.MACs {
		key := trackIndexPrefix(track.Simulated) + mac
		if r.macIndex[key] == old.ID {
			r.macIndex[key] = track.ID
		}
		track.MACs = insertTrackValue(track.MACs, mac)
	}
	for _, source := range old.Sources {
		track.Sources = insertTrackValue(track.Sources, source)
	}
	if old.FirstSeen.Before(track.FirstSeen) {
		track.FirstSeen = old.FirstSeen
	}
	track.MsgCount += old.MsgCount
	switch {
	case track.lastFix.IsZero() || (old.lastFix.After(track.lastFix) && len(old.Trail) > 0):
		track.Lat, track.Lon, track.lastFix, track.lastFixHAE, track.Trail =
			old.Lat, old.Lon, old.lastFix, old.lastFixHAE, old.Trail
	case len(old.Trail) > 0 && len(track.Trail) > 0:
		limit := 300 + 120*max(0, track.lastFix.Sub(old.lastFix).Seconds())
		if trackDistance(old.Trail[len(old.Trail)-1], track.Trail[0]) <= limit {
			track.Trail = append(old.Trail, track.Trail...)
			if len(track.Trail) > receiverTrailLimit {
				track.Trail = track.Trail[len(track.Trail)-receiverTrailLimit:]
			}
		}
	}
	if !track.evidence[1] && old.evidence[1] {
		track.Status, track.Height, track.HeightRef = old.Status, old.Height, old.HeightRef
		track.AltGeo, track.AltBaro = old.AltGeo, old.AltBaro
		track.Speed, track.VSpeed, track.Heading = old.Speed, old.VSpeed, old.Heading
		track.HAcc, track.VAcc, track.BaroAcc, track.SpdAcc, track.TSAcc =
			old.HAcc, old.VAcc, old.BaroAcc, old.SpdAcc, old.TSAcc
	}
	if !track.evidence[2] {
		track.SelfDesc = old.SelfDesc
	}
	if !track.evidence[3] {
		track.OperatorLat, track.OperatorLon, track.OperatorAlt = old.OperatorLat, old.OperatorLon, old.OperatorAlt
		track.AreaCount, track.AreaRadius, track.AreaCeiling, track.AreaFloor =
			old.AreaCount, old.AreaRadius, old.AreaCeiling, old.AreaFloor
		track.ClassType, track.CatEU, track.ClassEU = old.ClassType, old.CatEU, old.ClassEU
	}
	if !track.evidence[4] {
		track.OperatorID = old.OperatorID
	}
	if track.AuthState == "" {
		track.AuthState, track.AuthTS = old.AuthState, old.AuthTS
	}
	if track.InTFR == nil {
		track.InTFR, track.TFRID = old.InTFR, old.TFRID
	}
	for index, seen := range old.evidence {
		track.evidence[index] = track.evidence[index] || seen
	}
	r.forgetTrackLocked(old)
}

func (r *Receiver) makeTrackRoomLocked() {
	count := 0
	var oldestUnknown, oldestIdentified *Track
	for _, track := range r.tracks {
		if track.Simulated {
			continue
		}
		count++
		if track.UasID == "" {
			if oldestUnknown == nil || track.LastSeen.Before(oldestUnknown.LastSeen) {
				oldestUnknown = track
			}
		} else if oldestIdentified == nil || track.LastSeen.Before(oldestIdentified.LastSeen) {
			oldestIdentified = track
		}
	}
	if count < receiverTrackLimit {
		return
	}
	if oldestUnknown != nil {
		r.forgetTrackLocked(oldestUnknown)
	} else {
		r.forgetTrackLocked(oldestIdentified)
	}
}

func (r *Receiver) forgetTrackLocked(track *Track) {
	delete(r.tracks, track.ID)
	indexPrefix := trackIndexPrefix(track.Simulated)
	for _, mac := range track.MACs {
		key := indexPrefix + mac
		if r.macIndex[key] == track.ID {
			delete(r.macIndex, key)
		}
	}
	key := indexPrefix + track.UasID
	if r.uasIndex[key] == track.ID {
		delete(r.uasIndex, key)
	}
}

func updateTrackDetails(track *Track, message map[string]any, now time.Time) {
	if source := clipReceiverText(textField(message, "src"), 12); source != "" {
		track.Sources = insertTrackValue(track.Sources, source)
	}
	if rssi := intField(message, "rssi"); rssi != nil {
		track.RSSI = rssi
	}
	if channel := intField(message, "ch"); channel != nil {
		track.Channel = channel
	}
	if phy := textField(message, "phy"); phy != "" {
		track.PHY = clipReceiverText(phy, 16)
	}
	format := textField(message, "fmt")
	switch {
	case format == "gb46750":
		track.Format = "GB 46750-2025"
	case format != "":
		track.Format = clipReceiverText(format, 16)
	default:
		if version := intField(message, "proto"); version != nil {
			track.Format = fmt.Sprintf("ASTM F3411 v%d", *version)
		}
	}
	if ssid := textField(message, "ssid"); ssid != "" {
		track.SSID = clipReceiverText(ssid, 32)
	}
	if match := boolField(message, "ssid_id_match"); match != nil {
		track.SSIDMismatch = !*match
	}
	if loc := objectField(message, "loc"); loc != nil {
		updateTrackLocation(track, loc, now)
	}
	if self := objectField(message, "self_id"); self != nil {
		track.SelfDesc = clipReceiverText(textField(self, "desc"), 64)
		track.evidence[2] = true
	}
	if system := objectField(message, "system"); system != nil {
		updateTrackSystem(track, system, format)
	}
	if auth := objectField(message, "auth"); auth != nil {
		track.AuthState = clipReceiverText(textField(auth, "state"), 24)
		if timestamp := intField(auth, "auth_ts"); timestamp != nil {
			track.AuthTS = timestamp
		}
	}
	if inside := boolField(message, "in_tfr"); inside != nil {
		track.InTFR = inside
		track.TFRID = ""
		if *inside {
			track.TFRID = clipReceiverText(textField(message, "tfr_id"), 16)
		}
	}
	if op := objectField(message, "op_id"); op != nil {
		if id := textField(op, "id"); id != "" {
			track.OperatorID = clipReceiverText(id, 48)
			track.evidence[4] = true
		}
	}
	if track.Lat != nil && track.Lon != nil && track.OperatorLat != nil && track.OperatorLon != nil {
		distance := trackDistance(GeoPoint{*track.Lat, *track.Lon}, GeoPoint{*track.OperatorLat, *track.OperatorLon})
		track.OperatorDistance = &distance
		track.OperatorImplausible = distance > 15000
	}
	text := []rune("·····")
	for index, symbol := range []rune("BLSYO") {
		if track.evidence[index] {
			text[index] = symbol
		}
	}
	track.Evidence = string(text)
}

func updateTrackLocation(track *Track, loc map[string]any, now time.Time) {
	lat, lon := numberField(loc, "lat"), numberField(loc, "lon")
	hae := knownAltitude(numberField(loc, "alt_geo"))
	if validRIDPoint(lat, lon) {
		point := GeoPoint{*lat, *lon}
		track.Lat, track.Lon = lat, lon
		distance := 0.0
		if n := len(track.Trail); n > 0 {
			distance = trackDistance(track.Trail[n-1], point)
		}
		limit := 300 + 120*max(0, now.Sub(track.lastFix).Seconds())
		if distance > limit {
			track.Trail = track.Trail[:0]
		}
		if len(track.Trail) == 0 || distance > 1 {
			track.Trail = append(track.Trail, point)
			if len(track.Trail) > receiverTrailLimit {
				track.Trail = track.Trail[1:]
			}
		}
		track.lastFix = now
		track.lastFixHAE = hae
	}
	track.Status = intField(loc, "status")
	track.Height = knownAltitude(numberField(loc, "height"))
	track.AltGeo = hae
	track.AltBaro = knownAltitude(numberField(loc, "alt_baro"))
	track.VSpeed = numberField(loc, "vspeed")
	track.HAcc = intField(loc, "h_acc")
	track.VAcc = intField(loc, "v_acc")
	track.BaroAcc = intField(loc, "baro_acc")
	track.SpdAcc = intField(loc, "spd_acc")
	track.TSAcc = intField(loc, "ts_acc")
	track.HeightRef = nil
	if reference := intField(loc, "height_ref"); reference != nil && (*reference == 0 || *reference == 1) {
		track.HeightRef = reference
	}
	track.Speed = nil
	if speed := numberField(loc, "speed"); speed != nil && *speed >= 0 {
		track.Speed = speed
	}
	track.Heading = nil
	if heading := numberField(loc, "dir"); heading != nil && *heading >= 0 && *heading <= 360 {
		track.Heading = heading
	}
	track.evidence[1] = true
}

func updateTrackSystem(track *Track, system map[string]any, format string) {
	lat, lon := numberField(system, "op_lat"), numberField(system, "op_lon")
	if validRIDPoint(lat, lon) {
		track.OperatorLat, track.OperatorLon = lat, lon
	}
	track.OperatorAlt = knownAltitude(numberField(system, "op_alt"))
	track.AreaCount = nil
	if format != "gb46750" {
		track.AreaCount = intField(system, "area_count")
	}
	track.AreaRadius = numberField(system, "area_radius")
	track.AreaCeiling = knownAltitude(numberField(system, "area_ceiling"))
	track.AreaFloor = knownAltitude(numberField(system, "area_floor"))
	track.ClassType = intField(system, "class_type")
	track.CatEU, track.ClassEU = nil, nil
	if track.ClassType != nil && *track.ClassType == 1 {
		track.CatEU = intField(system, "cat_eu")
		track.ClassEU = intField(system, "class_eu")
	}
	track.evidence[3] = true
}

func (r *Receiver) SetDemo(enabled bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if enabled == r.demo {
		return
	}

	r.demo = enabled
	if !enabled {
		close(r.demoStop)
		r.demoStop = nil
		for _, track := range r.tracks {
			if track.Simulated {
				r.forgetTrackLocked(track)
			}
		}
		return
	}

	stop := make(chan struct{})
	r.demoStop = stop
	r.demoTickLocked(0)
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		angle := 0.0
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				angle += 0.02
				r.mu.Lock()
				if r.demoStop == stop {
					r.demoTickLocked(angle)
				}
				r.mu.Unlock()
			}
		}
	}()
}

func (r *Receiver) demoTickLocked(angle float64) {
	const centerLat, centerLon, metersPerLatitude = 37.8039, -122.464, 111111.0
	metersPerLongitude := metersPerLatitude * math.Cos(centerLat*math.Pi/180)
	now := time.Now()
	r.ingestTrackLocked(map[string]any{
		"type": "rid", "src": "ble", "mac": "DE:A0:00:00:00:01", "rssi": -60.0, "proto": 2.0,
		"basic_id": []any{map[string]any{"id_type": 1.0, "ua_type": 2.0, "uas_id": "1581F-DEMO-ALPHA"}},
		"loc": map[string]any{
			"status": 2.0, "lat": centerLat + 400*math.Sin(angle)/metersPerLatitude,
			"lon": centerLon + 400*math.Cos(angle)/metersPerLongitude, "alt_geo": 82.0,
			"alt_baro": 80.0, "height": 60.0, "height_ref": 0.0, "speed": 8.0,
			"vspeed": 0.0, "dir": math.Mod(360-math.Mod(angle*180/math.Pi, 360), 360),
		},
		"self_id": map[string]any{"desc": "Demo survey flight"},
		"system":  map[string]any{"op_lat": centerLat, "op_lon": centerLon, "op_alt": 12.0, "area_count": 1.0},
		"op_id":   map[string]any{"id": "FIN87astrdge12k8-demo"},
	}, now, true)
	r.ingestTrackLocked(map[string]any{
		"type": "rid", "src": "wifi", "mac": "DE:A0:00:00:00:02", "rssi": -75.0, "ch": 6.0, "proto": 2.0,
		"basic_id": []any{map[string]any{"id_type": 1.0, "ua_type": 2.0, "uas_id": "1581F-DEMO-BRAVO"}},
		"loc": map[string]any{
			"status": 2.0, "lat": centerLat + 0.004 + 125*math.Sin(2*angle)/metersPerLatitude,
			"lon": centerLon + 0.012 + 250*math.Sin(angle)/metersPerLongitude, "alt_geo": 45.0,
			"alt_baro": 44.0, "height": 30.0, "height_ref": 0.0, "speed": 4.2, "vspeed": 0.5, "dir": 90.0,
		},
	}, now, true)
}
