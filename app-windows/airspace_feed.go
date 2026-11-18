// Windows port of TrafficService.swift and the TrafficRules.swift host format.
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
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const defaultTrafficSource = "https://api.adsb.lol/v2/point/{lat}/{lon}/{radius}"

type airArea struct {
	Center  GeoPoint
	RadiusM float64
}

func airMakeArea(observer *GeoPoint, drones []airDrone, radiusKm float64) *airArea {
	points := make([]GeoPoint, 0, len(drones))
	for _, drone := range drones {
		if point := drone.point(); drone.Live && point != nil {
			points = append(points, *point)
		}
	}
	dronePoints := points
	base := radiusKm * 1000
	if airValidPoint(observer) {
		near := true
		for _, drone := range points {
			if airDistance(*observer, drone) > 3000 {
				near = false
				break
			}
		}
		if near {
			return &airArea{Center: *observer, RadiusM: base}
		}
		points = append([]GeoPoint{*observer}, points...)
	}
	if len(points) == 0 {
		return nil
	}

	ref := points[0]
	minX, minY, maxX, maxY := 0.0, 0.0, 0.0, 0.0
	for _, point := range points {
		x, y := airOffset(ref, point)
		minX, maxX = math.Min(minX, x), math.Max(maxX, x)
		minY, maxY = math.Min(minY, y), math.Max(maxY, y)
	}
	center := ref
	center.Lat += (minY + maxY) / (2 * trafficEarthM * trafficDeg)
	if lonScale := math.Cos(ref.Lat * trafficDeg); math.Abs(lonScale) > 1e-10 {
		center.Lon = airWrap(center.Lon + (minX+maxX)/(2*trafficEarthM*trafficDeg*lonScale))
	}
	for _, drone := range dronePoints {
		base = math.Max(base, airDistance(center, drone)+9000)
	}
	return &airArea{Center: center, RadiusM: math.Min(base, 30000)}
}

func airValidSource(source string) bool {
	if !strings.Contains(source, "{lat}") || !strings.Contains(source, "{lon}") ||
		!strings.Contains(source, "{radius}") || len(source) > 2048 {
		return false
	}
	parsed, err := url.Parse(strings.NewReplacer("{lat}", "0", "{lon}", "0", "{radius}", "1").Replace(source))
	if err != nil || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" {
		return false
	}
	return parsed.Scheme == "https" || parsed.Scheme == "http"
}

func airFetch(ctx context.Context, client *http.Client, template string, area airArea) ([]airAircraft, error) {
	radius := strconv.Itoa(max(1, int(math.Ceil(area.RadiusM/1852-1e-9))))
	address := strings.NewReplacer(
		"{lat}", fmt.Sprintf("%.2f", area.Center.Lat),
		"{lon}", fmt.Sprintf("%.2f", area.Center.Lon),
		"{radius}", radius,
	).Replace(template)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, errors.New("invalid ADS-B URL")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "Orecchino/1.0 (Windows; ADS-B conflict watch)")
	response, err := client.Do(request)
	if err != nil {
		var requestError *url.Error
		if errors.As(err, &requestError) {
			return nil, requestError.Err
		}
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 4*1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 4*1024*1024 {
		return nil, errors.New("ADS-B answer exceeds 4 MB")
	}
	return airParseADSB(data, time.Now())
}

func airValue(value any) *float64 {
	n, ok := value.(float64)
	if !ok || math.IsInf(n, 0) || math.IsNaN(n) {
		return nil
	}
	return &n
}

func airText(value any, width int) string {
	text, _ := value.(string)
	text = strings.TrimSpace(text)
	runes := []rune(text)
	if len(runes) > width {
		text = string(runes[:width])
	}
	return strings.TrimRight(text, " ")
}

func airScale(value any, factor float64) *float64 {
	if v := airValue(value); v != nil {
		scaled := *v * factor
		if !math.IsInf(scaled, 0) && !math.IsNaN(scaled) {
			return &scaled
		}
	}
	return nil
}

func airTruthy(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case float64:
		return v != 0
	case string:
		return v != "" && v != "none" && v != "0" && v != "false"
	}
	return false
}

func airParseWire(item map[string]any, received time.Time) (airAircraft, bool) {
	id := strings.Builder{}
	rawID, _ := item["hex"].(string)
	for i := range len(rawID) {
		if id.Len() >= 6 {
			break
		}
		character := rawID[i]
		if character == '~' {
			continue
		}
		if !airHex(character) {
			return airAircraft{}, false
		}
		id.WriteByte(character)
	}
	lat, lon, age := airValue(item["lat"]), airValue(item["lon"]), airValue(item["age_s"])
	if id.Len() == 0 || lat == nil || lon == nil || age == nil || *age < 0 || *age > trafficPresent {
		return airAircraft{}, false
	}
	pos := GeoPoint{Lat: *lat, Lon: *lon}
	if !airValidPoint(&pos) {
		return airAircraft{}, false
	}
	speed := airScale(item["gs_kt"], trafficKnots)
	if speed != nil && *speed < 0 {
		speed = nil
	}
	var squawk int
	switch value := item["sq"].(type) {
	case string:
		if len(value) >= 1 && len(value) <= 4 {
			if _, err := strconv.ParseUint(value, 8, 16); err == nil {
				squawk, _ = strconv.Atoi(value)
			}
		}
	case float64:
		if value >= 0 && value <= 7777 {
			squawk = int(value)
		}
	}
	ground := item["altb_ft"] == "ground"
	if v := item["gnd"]; v != nil {
		ground = airTruthy(v)
	}
	return airAircraft{
		ID: strings.ToLower(id.String()), Callsign: airText(item["cs"], 8), Type: airText(item["ty"], 4), Point: pos,
		Alt: airValue(item["altg_m"]), BaroAlt: airScale(item["altb_ft"], trafficFeet), Speed: speed,
		Heading: airValue(item["trk"]), VSpeed: airScale(item["vr_fpm"], trafficFeet/60), Squawk: squawk,
		Emergency: airTruthy(item["em"]), Ground: ground,
		Seen: received.Add(-time.Duration(math.Round(*age*1000)) * time.Millisecond),
	}, true
}

func airParseADSB(data []byte, received time.Time) ([]airAircraft, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, errors.New("unreadable ADS-B answer")
	}
	var list []json.RawMessage
	if raw := response["ac"]; raw != nil {
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil, errors.New("unreadable ADS-B aircraft list")
		}
	} else if response["now"] == nil && response["total"] == nil {
		return nil, errors.New("missing ADS-B aircraft list")
	}
	out := make([]airAircraft, 0, len(list))
	for _, raw := range list {
		var item map[string]any
		if err := json.Unmarshal(raw, &item); err != nil {
			continue
		}
		age := item["seen_pos"]
		if age == nil {
			age = item["seen"]
		}
		rate := item["geom_rate"]
		if rate == nil {
			rate = item["baro_rate"]
		}
		wire := map[string]any{
			"hex": item["hex"], "cs": item["flight"], "ty": item["t"],
			"lat": item["lat"], "lon": item["lon"], "altb_ft": item["alt_baro"],
			"gs_kt": item["gs"], "trk": item["track"], "vr_fpm": rate,
			"sq": item["squawk"], "em": item["emergency"], "age_s": age,
		}
		if geometric := airScale(item["alt_geom"], trafficFeet); geometric != nil {
			wire["altg_m"] = *geometric
		}
		if aircraft, ok := airParseWire(wire, received); ok {
			out = append(out, aircraft)
		}
	}
	return out, nil
}

func airMerge(old, new []airAircraft, area airArea, now time.Time) []airAircraft {
	byID := make(map[string]airAircraft)
	for _, list := range [][]airAircraft{old, new} {
		for _, aircraft := range list {
			previous, exists := byID[aircraft.ID]
			if airAge(aircraft.Seen, now) <= trafficPresent && (!exists || !previous.Seen.After(aircraft.Seen)) {
				byID[aircraft.ID] = aircraft
			}
		}
	}
	type rankedAircraft struct {
		Distance float64
		Aircraft airAircraft
	}
	ranked := make([]rankedAircraft, 0, len(byID))
	for _, aircraft := range byID {
		distance := airDistance(area.Center, aircraft.Point)
		if distance <= area.RadiusM {
			ranked = append(ranked, rankedAircraft{distance, aircraft})
		}
	}
	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].Distance != ranked[j].Distance {
			return ranked[i].Distance < ranked[j].Distance
		}
		return ranked[i].Aircraft.ID < ranked[j].Aircraft.ID
	})
	kept := make([]airAircraft, 0, min(len(ranked), trafficMaxAircraft))
	for _, item := range ranked[:cap(kept)] {
		kept = append(kept, item.Aircraft)
	}
	return kept
}

func airHostObject(a airAircraft, now time.Time) map[string]any {
	wire := map[string]any{
		"hex": a.ID, "lat": math.Round(a.Point.Lat*1e6) / 1e6, "lon": math.Round(a.Point.Lon*1e6) / 1e6,
		"age_s": math.Round(airAge(a.Seen, now)*10) / 10,
	}
	if a.Callsign != "" {
		wire["cs"] = strings.NewReplacer(`"`, "", `\`, "").Replace(a.Callsign)
	}
	if a.Type != "" {
		wire["ty"] = strings.NewReplacer(`"`, "", `\`, "").Replace(a.Type)
	}
	if airKnown(a.Alt) {
		wire["altg_m"] = math.Round(*a.Alt*10) / 10
	}
	if airKnown(a.BaroAlt) {
		wire["altb_ft"] = math.Round(*a.BaroAlt / trafficFeet)
	}
	if airKnown(a.Speed) {
		wire["gs_kt"] = math.Round(*a.Speed/trafficKnots*10) / 10
	}
	if airKnown(a.Heading) {
		wire["trk"] = math.Round(*a.Heading*10) / 10
	}
	if airKnown(a.VSpeed) {
		wire["vr_fpm"] = math.Round(*a.VSpeed * 60 / trafficFeet)
	}
	if a.Squawk > 0 {
		wire["sq"] = fmt.Sprintf("%04d", a.Squawk)
	}
	if a.Emergency {
		wire["em"] = 1
	}
	if a.Ground {
		wire["gnd"] = 1
	}
	return wire
}

func airHostCommands(aircraft []airAircraft, received, now time.Time) []any {
	age := math.Round(airAge(received, now)*10) / 10
	present := make([]map[string]any, 0, len(aircraft))
	for _, a := range aircraft {
		if airAge(a.Seen, now) <= trafficPresent {
			present = append(present, airHostObject(a, now))
		}
	}
	commands := make([]any, 0, len(present)/6+2)
	for start := 0; start < len(present); start += 6 {
		part := present[start:min(start+6, len(present))]
		commands = append(commands, map[string]any{"cmd": "traffic", "t": now.Unix(), "age_s": age, "ac": part})
	}
	return append(commands, map[string]any{"cmd": "traffic_done", "n": len(present), "age_s": age})
}
