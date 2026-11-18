// Windows port of TrafficRules.swift and firmware/common/traffic.h.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later.
package main

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

const (
	trafficEarthM      = 6371000.0
	trafficDeg         = math.Pi / 180
	trafficKnots       = 1852.0 / 3600
	trafficFeet        = 0.3048
	trafficMaxAircraft = 32
	trafficMaxAlerts   = 16
	trafficFresh       = 30
	trafficPresent     = 60
)

type airDrone struct {
	ID      string   `json:"id"`
	Label   string   `json:"-"`
	Lat     *float64 `json:"lat"`
	Lon     *float64 `json:"lon"`
	Alt     *float64 `json:"alt_geo_m"`
	Speed   *float64 `json:"speed_mps"`
	Heading *float64 `json:"heading_deg"`
	Height  *float64 `json:"height_m"`
	Live    bool     `json:"live"`
}

type airObserver struct {
	Point *GeoPoint
	Elev  *float64
}

type airAircraft struct {
	ID, Callsign, Type                   string
	Point                                GeoPoint
	Alt, BaroAlt, Speed, Heading, VSpeed *float64
	Squawk                               int
	Emergency, Ground                    bool
	Seen                                 time.Time
}

type airAircraftView struct {
	ID         string    `json:"id"`
	Callsign   string    `json:"callsign"`
	Coordinate GeoPoint  `json:"coordinate"`
	Projection *GeoPoint `json:"projection,omitempty"`
}

type airAlert struct {
	ID                           string           `json:"id"`
	Level                        string           `json:"level"`
	Kind                         string           `json:"kind"`
	Action                       string           `json:"action"`
	Summary                      string           `json:"summary"`
	Detail                       string           `json:"detail"`
	DroneID                      string           `json:"droneId"`
	Aircraft                     *airAircraftView `json:"aircraft,omitempty"`
	Origin                       *GeoPoint        `json:"origin,omitempty"`
	HorizontalM                  float64          `json:"horizontalM"`
	VerticalM                    *float64         `json:"verticalM,omitempty"`
	BearingDeg                   float64          `json:"bearingDeg"`
	CPAS                         *float64         `json:"cpaSec,omitempty"`
	Age                          float64          `json:"dataAgeSec"`
	Simulated                    bool             `json:"simulated"`
	Held                         bool             `json:"held"`
	Hex, DroneLabel              string           `json:"-"`
	Callsign                     string           `json:"callsign,omitempty"`
	Ground, Approx, FromObserver bool             `json:"-"`
	VerticalRelation             string           `json:"-"`
}

type airAlertEntry struct {
	Alert          airAlert
	Seen, OutSince time.Time
	Visited        bool
}

type airRuleState struct {
	Entries []airAlertEntry
}

func airNumber(value float64) *float64 { return &value }

func airKnown(value *float64) bool {
	return value != nil && !math.IsNaN(*value) && !math.IsInf(*value, 0)
}

func airAltitude(value *float64) bool { return airKnown(value) && *value > -999 }

func airValidPoint(point *GeoPoint) bool {
	return point != nil && math.Abs(point.Lat) <= 90 && math.Abs(point.Lon) <= 180
}

func (drone airDrone) point() *GeoPoint {
	if !airKnown(drone.Lat) || !airKnown(drone.Lon) {
		return nil
	}
	point := &GeoPoint{Lat: *drone.Lat, Lon: *drone.Lon}
	if !airValidPoint(point) {
		return nil
	}
	return point
}

func airAge(seen, now time.Time) float64 { return math.Max(now.Sub(seen).Seconds(), 0) }

func airWrap(lon float64) float64 {
	return math.Remainder(lon, 360)
}

func airOffset(from, to GeoPoint) (float64, float64) {
	deltaLon := airWrap(to.Lon - from.Lon)
	meanLat := (from.Lat + to.Lat) * 0.5 * trafficDeg
	return deltaLon * trafficDeg * math.Cos(meanLat) * trafficEarthM,
		(to.Lat - from.Lat) * trafficDeg * trafficEarthM
}

func airDistance(from, to GeoPoint) float64 {
	x, y := airOffset(from, to)
	return math.Hypot(x, y)
}

func airBearing(dx, dy float64) float64 {
	return math.Mod(math.Atan2(dx, dy)/trafficDeg+360, 360)
}

func airCompass(degrees float64) string {
	headings := [...]string{"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
	return headings[int(math.Floor((degrees+22.5)/45))%len(headings)]
}

func airHex(character byte) bool {
	return character >= '0' && character <= '9' || character >= 'a' && character <= 'f' || character >= 'A' && character <= 'F'
}

func airAlphaNumeric(character byte) bool {
	return character >= '0' && character <= '9' || character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z'
}

func airDroneLabel(id string) string {
	id = strings.TrimPrefix(strings.TrimPrefix(id, "uas:"), "mac:")
	if len(id) == 17 || len(id) == 12 {
		mac := true
		for index := range len(id) {
			if len(id) == 17 && index%3 == 2 {
				if id[index] != id[2] || id[index] != ':' && id[index] != '-' {
					mac = false
					break
				}
			} else if !airHex(id[index]) {
				mac = false
				break
			}
		}
		if mac {
			if len(id) == 17 {
				return "MAC " + strings.ToUpper(strings.ReplaceAll(id[9:], "-", ":"))
			}
			return "MAC " + strings.ToUpper(id[6:8]+":"+id[8:10]+":"+id[10:])
		}
	}
	if len(id) <= 8 {
		return id
	}
	tail := len(id) - 5
	for tail > 0 && !airAlphaNumeric(id[tail]) {
		tail--
	}
	return strings.ToValidUTF8(id[tail:], "�")
}

func airRounded(number float64) int {
	return int(math.Floor(number + 0.5))
}

func airDistanceText(distance float64) string {
	if distance < 1000 {
		return fmt.Sprintf("%d M", airRounded(distance/10)*10)
	}
	tenths := airRounded(distance / 100)
	return fmt.Sprintf("%d.%d KM", tenths/10, tenths%10)
}

func airRelation(vert *float64) string {
	if !airKnown(vert) {
		return "unknown"
	}
	if *vert > 30 {
		return "above"
	}
	if *vert < -30 {
		return "below"
	}
	return "level"
}

func (alert *airAlert) describe() {
	alert.VerticalRelation = airRelation(alert.VerticalM)
	bearing := airCompass(alert.BearingDeg)
	distance := airDistanceText(alert.HorizontalM)
	if alert.Kind == "low" {
		alert.Summary = fmt.Sprintf("LOW TRAFFIC %s %s", bearing, distance)
		alert.Action = "BE READY TO LAND DRONES"
		vertical := "AIRCRAFT HEIGHT UNKNOWN"
		switch {
		case alert.Ground:
			alert.Summary += ", AIRCRAFT ON GROUND"
			vertical = "AIRCRAFT ON GROUND"
		case alert.VerticalM == nil:
			alert.Summary += ", HEIGHT UNKNOWN"
		default:
			height := airRounded(*alert.VerticalM)
			vertical = "AIRCRAFT NEAR GROUND LEVEL"
			if height > 0 {
				amount := fmt.Sprintf("%d", height)
				if alert.Approx {
					amount = "ABOUT " + amount
				}
				vertical = fmt.Sprintf("AIRCRAFT %s M ABOVE GROUND", amount)
			}
			if alert.Approx {
				alert.Summary += ", APPROX."
			}
		}
		alert.Detail = fmt.Sprintf("%s, %s %s", vertical, distance, bearing)
		return
	}
	label := alert.DroneLabel
	if label == "" {
		label = alert.DroneID
	}
	id := airDroneLabel(label)
	if alert.Kind == "near" {
		alert.Summary = "TRAFFIC NEAR DRONE " + id
	} else {
		alert.Summary = "TRAFFIC CONVERGING WITH " + id
		if alert.CPAS != nil {
			alert.Summary += fmt.Sprintf(", %d S", airRounded(*alert.CPAS))
		}
	}
	if alert.Ground {
		alert.Summary += ", AIRCRAFT ON GROUND"
	} else if alert.VerticalM == nil {
		alert.Summary += ", HEIGHT UNKNOWN"
	}
	alert.Action = "GIVE WAY: DESCEND AND LAND " + id
	vertical := "AIRCRAFT HEIGHT UNKNOWN"
	if alert.Ground {
		vertical = "AIRCRAFT ON GROUND"
		alert.Action = "KEEP CLEAR OF AIRCRAFT ON GROUND"
	} else {
		switch alert.VerticalRelation {
		case "below":
			vertical = fmt.Sprintf("AIRCRAFT %d M BELOW", airRounded(math.Abs(*alert.VerticalM)))
			opposite := airCompass(math.Mod(alert.BearingDeg+180, 360))
			alert.Action = fmt.Sprintf("GIVE WAY: MOVE %s, THEN LAND %s", opposite, id)
		case "above":
			vertical = fmt.Sprintf("AIRCRAFT %d M ABOVE", airRounded(*alert.VerticalM))
		case "level":
			vertical = "AIRCRAFT LEVEL WITHIN 30 M"
		}
	}
	alert.Detail = fmt.Sprintf("%s, %s %s", vertical, distance, bearing)
	if alert.CPAS != nil {
		alert.Detail += fmt.Sprintf(", CLOSEST IN %d S", airRounded(*alert.CPAS))
	}
}

func airRank(kind string) int {
	switch kind {
	case "near":
		return 0
	case "converging":
		return 1
	default:
		return 2
	}
}

func airAlertBefore(left, right airAlert) bool {
	if left.Level != right.Level {
		return left.Level == "warning"
	}
	if left.Kind != right.Kind {
		return airRank(left.Kind) < airRank(right.Kind)
	}
	if left.HorizontalM != right.HorizontalM {
		return left.HorizontalM < right.HorizontalM
	}
	if left.DroneID != right.DroneID {
		return left.DroneID < right.DroneID
	}
	return left.Hex < right.Hex
}

func airLevel(kind string, ground bool) string {
	if kind == "low" || ground {
		return "caution"
	}
	return "warning"
}

func (state *airRuleState) apply(candidate airAlert, raw, hold bool, seen, now time.Time) {
	low := candidate.Kind == "low"
	candidate.Level = airLevel(candidate.Kind, candidate.Ground)
	index := -1
	for i, entry := range state.Entries {
		existing := entry.Alert
		if existing.Hex == candidate.Hex && (low && existing.Kind == "low" || !low && existing.Kind != "low" && existing.DroneID == candidate.DroneID) {
			index = i
			break
		}
	}
	switch {
	case index >= 0:
		oldKind := state.Entries[index].Alert.Kind
		if !low && (!raw || oldKind == "near" && hold) {
			candidate.Kind = oldKind
		}
	case !raw:
		return
	case len(state.Entries) < trafficMaxAlerts:
		index = len(state.Entries)
		state.Entries = append(state.Entries, airAlertEntry{})
	default:
		index = 0
		for i := 1; i < len(state.Entries); i++ {
			if airAlertBefore(state.Entries[index].Alert, state.Entries[i].Alert) {
				index = i
			}
		}
		if !airAlertBefore(candidate, state.Entries[index].Alert) {
			return
		}
		state.Entries[index] = airAlertEntry{}
	}
	candidate.ID = candidate.Kind + "|" + candidate.DroneID + "|" + candidate.Hex
	candidate.Level = airLevel(candidate.Kind, candidate.Ground)
	candidate.Held = !raw
	candidate.describe()
	entry := &state.Entries[index]
	entry.Alert = candidate
	entry.Visited = true
	entry.Seen = seen
	if raw || hold {
		entry.OutSince = time.Time{}
	} else if entry.OutSince.IsZero() {
		entry.OutSince = now
	}
}

func airVelocity(speed, heading float64) (float64, float64) {
	return speed * math.Sin(heading*trafficDeg), speed * math.Cos(heading*trafficDeg)
}

func airComparePair(drone airDrone, point GeoPoint, aircraft airAircraft, canRaise bool, now time.Time) (airAlert, bool, bool) {
	dx, dy := airOffset(point, aircraft.Point)
	distance := math.Hypot(dx, dy)
	var vertical, projectedVertical, closestTime *float64
	miss := math.Inf(1)
	if airAltitude(aircraft.Alt) && airAltitude(drone.Alt) {
		vertical = airNumber(*aircraft.Alt - *drone.Alt)
		projectedVertical = vertical
	}
	if !aircraft.Ground && airKnown(aircraft.Speed) && *aircraft.Speed >= 0 && airKnown(aircraft.Heading) &&
		airKnown(drone.Speed) && *drone.Speed >= 0 && airKnown(drone.Heading) {
		ax, ay := airVelocity(*aircraft.Speed, *aircraft.Heading)
		bx, by := airVelocity(*drone.Speed, *drone.Heading)
		wx, wy := ax-bx, ay-by
		magnitude := wx*wx + wy*wy
		if magnitude > 1e-9 {
			at := -(dx*wx + dy*wy) / magnitude
			if at > 0 && at <= 60 {
				closestTime = airNumber(at)
				miss = math.Hypot(dx+wx*at, dy+wy*at)
				if projectedVertical != nil && airKnown(aircraft.VSpeed) {
					projectedVertical = airNumber(*vertical + *aircraft.VSpeed*at)
				}
			}
		}
	}
	eligible := canRaise && drone.Live && airAge(aircraft.Seen, now) < trafficFresh
	near := eligible && distance <= 1000 && (vertical == nil || math.Abs(*vertical) <= 150)
	converging := eligible && closestTime != nil && miss < 500 && (projectedVertical == nil || math.Abs(*projectedVertical) <= 150)
	hold := drone.Live && distance <= 1300 && (vertical == nil || math.Abs(*vertical) <= 200)
	kind := "converging"
	if near {
		kind = "near"
	}
	return airAlert{
		Kind: kind, DroneID: drone.ID, DroneLabel: drone.Label, Hex: aircraft.ID, Callsign: aircraft.Callsign,
		HorizontalM: distance, VerticalM: vertical, BearingDeg: airBearing(dx, dy),
		CPAS: closestTime, Ground: aircraft.Ground,
	}, near || converging, hold
}

func airGround(observer airObserver, drones []airDrone) *float64 {
	if airAltitude(observer.Elev) {
		return observer.Elev
	}
	lowest := math.Inf(1)
	var ground *float64
	for _, drone := range drones {
		if drone.Live && drone.point() != nil && airAltitude(drone.Alt) && airKnown(drone.Height) && *drone.Alt < lowest {
			lowest = *drone.Alt
			ground = airNumber(lowest - *drone.Height)
		}
	}
	return ground
}

func airCompareLow(drones []airDrone, observer airObserver, ground *float64, aircraft airAircraft) (airAlert, bool, bool) {
	pos := observer.Point
	validObserver := airValidPoint(pos)
	fromObserver := validObserver
	distance := math.Inf(1)
	anchor := -1
	if validObserver {
		distance = airDistance(*pos, aircraft.Point)
	}
	if distance > 3000 {
		best := math.Inf(1)
		for index, drone := range drones {
			p := drone.point()
			if !drone.Live || p == nil {
				continue
			}
			d := airDistance(*p, aircraft.Point)
			if d < best {
				best, anchor = d, index
			}
		}
		if anchor >= 0 && (best <= 3000 || !validObserver) {
			pos = drones[anchor].point()
			distance = best
			fromObserver = false
		} else {
			anchor = -1
		}
	}
	if !validObserver && anchor < 0 {
		return airAlert{}, false, false
	}
	droneID := ""
	if anchor >= 0 {
		drone := drones[anchor]
		droneID = drone.ID
		if airAltitude(drone.Alt) && airKnown(drone.Height) {
			ground = airNumber(*drone.Alt - *drone.Height)
		}
	}
	height := aircraft.Alt
	useBaro := !airAltitude(height)
	if useBaro {
		height = aircraft.BaroAlt
	}
	var vertical *float64
	if airAltitude(height) && ground != nil {
		vertical = airNumber(*height - *ground)
	}
	low := vertical != nil && *vertical < 460 || vertical == nil && (!airAltitude(height) || ground != nil || *height < 3500)
	dx, dy := airOffset(*pos, aircraft.Point)
	return airAlert{
		Kind: "low", DroneID: droneID, Hex: aircraft.ID, Callsign: aircraft.Callsign,
		HorizontalM: distance, VerticalM: vertical, BearingDeg: airBearing(dx, dy),
		Ground: aircraft.Ground, Approx: useBaro && vertical != nil, FromObserver: fromObserver,
	}, true, !aircraft.Ground && distance <= 3000 && low
}

func airProjection(aircraft airAircraft) *GeoPoint {
	if !airKnown(aircraft.Speed) || !airKnown(aircraft.Heading) || aircraft.Ground || *aircraft.Speed < 0 {
		return nil
	}
	startLat, startLon := aircraft.Point.Lat*trafficDeg, aircraft.Point.Lon*trafficDeg
	angle := *aircraft.Speed * 60 / trafficEarthM
	bearing := *aircraft.Heading * trafficDeg
	sinLat := math.Sin(startLat)*math.Cos(angle) + math.Cos(startLat)*math.Sin(angle)*math.Cos(bearing)
	lat := math.Asin(max(-1, min(1, sinLat)))
	lon := startLon + math.Atan2(math.Sin(bearing)*math.Sin(angle)*math.Cos(startLat), math.Cos(angle)-math.Sin(startLat)*math.Sin(lat))
	return &GeoPoint{Lat: lat / trafficDeg, Lon: airWrap(lon / trafficDeg)}
}

func (state *airRuleState) evaluate(drones []airDrone, aircraft []airAircraft, observer airObserver, received, now time.Time) []airAlert {
	canRaise := !received.IsZero() && airAge(received, now) <= trafficFresh
	present := make(map[string]airAircraft, len(aircraft))
	positions := make(map[string]*GeoPoint, len(drones))
	for i := range state.Entries {
		state.Entries[i].Visited = false
	}
	for _, a := range aircraft {
		if airAge(a.Seen, now) <= trafficPresent && airValidPoint(&a.Point) {
			present[a.ID] = a
		}
	}

	// Preserve input order when alerts compete for the firmware's 16 slots.
	for _, drone := range drones {
		point := drone.point()
		if point == nil {
			continue
		}
		positions[drone.ID] = point
		for _, a := range aircraft {
			if _, ok := present[a.ID]; !ok {
				continue
			}
			candidate, raw, hold := airComparePair(drone, *point, a, canRaise, now)
			state.apply(candidate, raw, hold, a.Seen, now)
		}
	}

	ground := airGround(observer, drones)
	for _, a := range aircraft {
		if _, ok := present[a.ID]; !ok {
			continue
		}
		candidate, ok, hold := airCompareLow(drones, observer, ground, a)
		if ok {
			state.apply(candidate, canRaise && airAge(a.Seen, now) < trafficFresh && hold, hold, a.Seen, now)
		}
	}

	kept := state.Entries[:0]
	warned := make(map[string]bool)
	for _, entry := range state.Entries {
		if !entry.Visited {
			entry.Alert.Held = true
			if entry.OutSince.IsZero() {
				entry.OutSince = now
			}
		}
		if !entry.OutSince.IsZero() && now.Sub(entry.OutSince) >= 20*time.Second {
			continue
		}
		kept = append(kept, entry)
		if entry.Alert.Level == "warning" {
			warned[entry.Alert.Hex] = true
		}
	}
	state.Entries = kept

	alerts := make([]airAlert, 0, len(kept))
	for _, entry := range kept {
		alert := entry.Alert
		if alert.Kind == "low" && warned[alert.Hex] {
			continue
		}
		alert.Age = airAge(entry.Seen, now)
		alert.Origin = positions[alert.DroneID]
		if alert.FromObserver {
			alert.Origin = observer.Point
		}
		if aircraft, ok := present[alert.Hex]; ok {
			callsign := aircraft.Callsign
			if callsign == "" {
				callsign = strings.ToUpper(aircraft.ID)
			}
			alert.Aircraft = &airAircraftView{
				ID: aircraft.ID, Callsign: callsign,
				Coordinate: aircraft.Point, Projection: airProjection(aircraft),
			}
		}
		alerts = append(alerts, alert)
	}
	sort.Slice(alerts, func(i, j int) bool { return airAlertBefore(alerts[i], alerts[j]) })
	return alerts
}

func airTrafficSummary(alerts []airAlert, received, now time.Time) string {
	if received.IsZero() {
		return "CONFLICT WATCH OFF: no ADS-B source"
	}
	age := airAge(received, now)
	if age > trafficFresh {
		return fmt.Sprintf("TRAFFIC DATA STALE, data %d s old", airRounded(age))
	}
	description := "no ADS-B conflicts, "
	if len(alerts) > 0 {
		lowCount := 0
		for _, alert := range alerts {
			if alert.Kind == "low" {
				lowCount++
			}
		}
		description = ""
		if lowCount > 0 {
			description = "low traffic, "
		}
		if conflicts := len(alerts) - lowCount; conflicts > 0 {
			suffix := "s"
			if conflicts == 1 {
				suffix = ""
			}
			description += fmt.Sprintf("%d ADS-B conflict%s, ", conflicts, suffix)
		}
	}
	return fmt.Sprintf("conflict watch on, %sdata %d s old", description, airRounded(age))
}
