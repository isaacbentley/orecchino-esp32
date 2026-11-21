// FAA Temporary Flight Restrictions for the Orecchino Windows port.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"
)

const (
	tfrURL          = "https://tfr.faa.gov/geoserver/TFR/ows?service=WFS&version=1.1.0&request=GetFeature&typeName=TFR:V_TFR_LOC&outputFormat=application/json"
	tfrMaxFeedBytes = 24 << 20
	tfrMaxVertices  = 24
	tfrMaxZones     = 16
	tfrRadiusMeters = 200_000
)

type tfrZone struct {
	ID       string     `json:"id"`
	NOTAM    string     `json:"notam"`
	Title    string     `json:"title"`
	Legal    string     `json:"legal"`
	State    string     `json:"state,omitempty"`
	Ring     []GeoPoint `json:"ring"`
	centroid GeoPoint
	min, max GeoPoint
}

type tfrFeature struct {
	ID       string
	Geometry *struct {
		Type        string
		Coordinates json.RawMessage
	}
	Properties struct {
		GID   int64
		NOTAM string `json:"NOTAM_KEY"`
		Title string
		Legal string
		State string
	}
}

func fetchTFR(ctx context.Context, client *http.Client) ([]tfrZone, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, tfrURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "Orecchino (Windows; FAA TFR layer)")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("FAA restrictions returned HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, tfrMaxFeedBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > tfrMaxFeedBytes {
		return nil, errors.New("FAA restrictions exceeded the supported feed size")
	}
	return parseTFR(data)
}

func parseTFR(data []byte) ([]tfrZone, error) {
	var feed struct {
		Type     string
		Features json.RawMessage
	}
	if err := json.Unmarshal(data, &feed); err != nil {
		return nil, fmt.Errorf("read FAA restrictions: %w", err)
	}
	if feed.Type != "FeatureCollection" || len(feed.Features) == 0 || bytes.Equal(feed.Features, []byte("null")) {
		return nil, errors.New("unexpected FAA restrictions response")
	}
	var features []tfrFeature
	if err := json.Unmarshal(feed.Features, &features); err != nil {
		return nil, fmt.Errorf("read FAA restrictions features: %w", err)
	}

	zones := make([]tfrZone, 0, len(features))
	for featureIndex, feature := range features {
		if feature.Geometry == nil {
			continue
		}
		var polygons [][][][]float64
		switch feature.Geometry.Type {
		case "Polygon":
			var polygon [][][]float64
			if err := json.Unmarshal(feature.Geometry.Coordinates, &polygon); err != nil {
				return nil, fmt.Errorf("read FAA polygon %d: %w", featureIndex, err)
			}
			polygons = append(polygons, polygon)
		case "MultiPolygon":
			if err := json.Unmarshal(feature.Geometry.Coordinates, &polygons); err != nil {
				return nil, fmt.Errorf("read FAA multipolygon %d: %w", featureIndex, err)
			}
		default:
			continue
		}

		for polygonIndex, polygon := range polygons {
			if len(polygon) == 0 {
				continue
			}
			ring := make([]GeoPoint, 0, len(polygon[0]))
			for _, position := range polygon[0] {
				if len(position) < 2 || math.Abs(position[0]) > 180 || math.Abs(position[1]) > 90 {
					continue
				}
				p := GeoPoint{Lat: position[1], Lon: position[0]}
				if len(ring) == 0 || p != ring[len(ring)-1] {
					ring = append(ring, p)
				}
			}
			if len(ring) > 1 && ring[0] == ring[len(ring)-1] {
				ring = ring[:len(ring)-1]
			}
			if len(ring) < 3 {
				continue
			}
			p := feature.Properties
			zone := tfrZone{
				NOTAM: p.NOTAM,
				Title: p.Title,
				Legal: p.Legal,
				State: p.State,
				Ring:  ring,
				min:   ring[0],
				max:   ring[0],
			}
			if zone.NOTAM == "" {
				zone.NOTAM = "unknown"
			}
			if zone.Title == "" {
				zone.Title = "TFR"
			}
			if zone.Legal == "" {
				zone.Legal = "TFR"
			}
			switch {
			case p.GID != 0:
				zone.ID = fmt.Sprintf("%d-%s-%d", p.GID, zone.NOTAM, polygonIndex)
			case feature.ID != "":
				zone.ID = fmt.Sprintf("%s-%d", feature.ID, polygonIndex)
			default:
				zone.ID = fmt.Sprintf("faa-%d-%d", featureIndex, polygonIndex)
			}
			for _, point := range ring {
				zone.centroid.Lat += point.Lat
				zone.centroid.Lon += point.Lon
				zone.min.Lat = math.Min(zone.min.Lat, point.Lat)
				zone.min.Lon = math.Min(zone.min.Lon, point.Lon)
				zone.max.Lat = math.Max(zone.max.Lat, point.Lat)
				zone.max.Lon = math.Max(zone.max.Lon, point.Lon)
			}
			zone.centroid.Lat /= float64(len(ring))
			zone.centroid.Lon /= float64(len(ring))
			zones = append(zones, zone)
		}
	}
	if len(features) > 0 && len(zones) == 0 {
		return nil, errors.New("FAA restrictions response contained no usable polygons")
	}
	return zones, nil
}

func (z tfrZone) contains(point GeoPoint) bool {
	if point.Lat < z.min.Lat || point.Lat > z.max.Lat || point.Lon < z.min.Lon || point.Lon > z.max.Lon {
		return false
	}
	return tfrContains(z.Ring, point)
}

func tfrContains(ring []GeoPoint, point GeoPoint) bool {
	inside := false
	for i, j := 0, len(ring)-1; i < len(ring); j, i = i, i+1 {
		a, b := ring[i], ring[j]
		if (a.Lat > point.Lat) != (b.Lat > point.Lat) {
			crossing := a.Lon + (b.Lon-a.Lon)*(point.Lat-a.Lat)/(b.Lat-a.Lat)
			if point.Lon < crossing {
				inside = !inside
			}
		}
	}
	return inside
}

func tfrCommands(zones []tfrZone, reference *GeoPoint) []any {
	if reference == nil && len(zones) > 0 {
		return nil
	}
	commands := []any{map[string]any{"cmd": "tfr_clear"}}
	if len(zones) == 0 {
		return commands
	}
	type nearbyZone struct {
		zone     tfrZone
		distance float64
	}
	nearby := make([]nearbyZone, 0, len(zones))
	for _, zone := range zones {
		distance := tfrDistance(*reference, zone.centroid)
		if distance < tfrRadiusMeters {
			nearby = append(nearby, nearbyZone{zone: zone, distance: distance})
		}
	}
	sort.SliceStable(nearby, func(i, j int) bool {
		return nearby[i].distance < nearby[j].distance
	})

	for _, nearby := range nearby {
		wireRing := tfrEnclosure(nearby.zone.Ring)
		if len(wireRing) < 3 {
			continue
		}
		points := make([][2]float64, 0, len(wireRing))
		for _, point := range wireRing {
			points = append(points, [2]float64{point.Lat, point.Lon})
		}
		id := strings.Map(func(r rune) rune {
			if r < 0x20 || r > 0x7e || r == '"' || r == '\\' || r == '<' || r == '>' || r == '&' {
				return -1
			}
			return r
		}, nearby.zone.NOTAM)
		if len(id) > 14 {
			id = id[:14]
		}
		commands = append(commands, map[string]any{"cmd": "tfr_add", "id": id, "pts": points})
		if len(commands) == tfrMaxZones+1 {
			break
		}
	}
	return commands
}

func tfrDistance(a, b GeoPoint) float64 {
	const radians = math.Pi / 180
	dlat := (b.Lat - a.Lat) * radians
	dlon := (b.Lon - a.Lon) * radians
	sinLat, sinLon := math.Sin(dlat/2), math.Sin(dlon/2)
	h := sinLat*sinLat + math.Cos(a.Lat*radians)*math.Cos(b.Lat*radians)*sinLon*sinLon
	return 2 * 6_371_000 * math.Asin(math.Sqrt(math.Min(1, h)))
}

func tfrEnclosure(ring []GeoPoint) []GeoPoint {
	if len(ring) <= tfrMaxVertices {
		return ring
	}

	// Place 24 evenly spaced support lines around the source ring. Each
	// line lies five metres beyond the outermost source point in its
	// direction. Intersect adjacent lines to form an enclosing polygon.
	var origin GeoPoint
	minimum, maximum := ring[0], ring[0]
	for _, point := range ring {
		origin.Lat += point.Lat
		origin.Lon += point.Lon
		minimum.Lat = math.Min(minimum.Lat, point.Lat)
		minimum.Lon = math.Min(minimum.Lon, point.Lon)
		maximum.Lat = math.Max(maximum.Lat, point.Lat)
		maximum.Lon = math.Max(maximum.Lon, point.Lon)
	}
	origin.Lat /= float64(len(ring))
	origin.Lon /= float64(len(ring))
	const metresPerLat = 110_540.0
	const margin = 5.0
	metresPerLon := math.Max(1, 111_320*math.Cos(origin.Lat*math.Pi/180))
	type supportLine struct {
		x, y, offset float64
	}
	var lines [tfrMaxVertices]supportLine
	for i := range lines {
		angle := float64(i) * 2 * math.Pi / tfrMaxVertices
		line := supportLine{x: math.Cos(angle), y: math.Sin(angle), offset: math.Inf(-1)}
		for _, point := range ring {
			x := (point.Lon - origin.Lon) * metresPerLon
			y := (point.Lat - origin.Lat) * metresPerLat
			line.offset = math.Max(line.offset, line.x*x+line.y*y)
		}
		line.offset += margin
		lines[i] = line
	}
	enclosed := make([]GeoPoint, 0, len(lines))
	for i, a := range lines {
		b := lines[(i+1)%len(lines)]
		det := a.x*b.y - a.y*b.x
		x := (a.offset*b.y - a.y*b.offset) / det
		y := (a.x*b.offset - a.offset*b.x) / det
		p := GeoPoint{Lat: origin.Lat + y/metresPerLat, Lon: origin.Lon + x/metresPerLon}
		if math.Abs(p.Lat) > 90 || math.Abs(p.Lon) > 180 {
			// The receiver only accepts legal latitudes and longitudes.
			// A padded bounding box still encloses every original point.
			south := math.Max(-90, minimum.Lat-margin/metresPerLat)
			north := math.Min(90, maximum.Lat+margin/metresPerLat)
			west := math.Max(-180, minimum.Lon-margin/metresPerLon)
			east := math.Min(180, maximum.Lon+margin/metresPerLon)
			return []GeoPoint{{Lat: south, Lon: west}, {Lat: south, Lon: east}, {Lat: north, Lon: east}, {Lat: north, Lon: west}}
		}
		enclosed = append(enclosed, p)
	}
	return enclosed
}
