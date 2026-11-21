// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from app/Sources/Orecchino/TilePlan.swift and firmware/common/tile_plan.h.

package main

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

const (
	tileMinZoom       = 12
	tileMaxZoom       = 15
	tileZooms         = tileMaxZoom - tileMinZoom + 1
	tileRadiusStepM   = 250
	tileEarthRadiusM  = 6371000
	tileRadPerDegree  = math.Pi / 180
	tileDefaultBytes  = 12288
	tileMinSampleSize = 20
)

type tilePlan struct {
	RadiusKm      float64            `json:"radiusKm"`
	RadiiKm       [tileZooms]float64 `json:"radiiKm"`
	TileCount     int                `json:"tileCount"`
	Present       int                `json:"present"`
	Missing       int                `json:"missing"`
	PlanBytes     int64              `json:"planBytes"`
	CapacityBytes int64              `json:"capacityBytes"`
	FreeBytes     int64              `json:"freeBytes"`
	Shrunk        bool               `json:"shrunk"`
	paths         []string
	victims       []string
}

type tileKey struct{ zoom, x, y int }

type tileDiskEntry struct {
	key      tileKey
	bytes    int64
	paths    []string
	distance float64
}

func parseTilePath(path string) (tileKey, bool) {
	tail, ok := strings.CutPrefix(path, "/tiles/")
	if !ok || (!strings.HasSuffix(tail, ".jpg") && !strings.HasSuffix(tail, ".png")) {
		return tileKey{}, false
	}
	parts := strings.Split(tail[:len(tail)-4], "/")
	if len(parts) != 3 {
		return tileKey{}, false
	}
	for i, part := range parts {
		limit := 7
		if i == 0 {
			limit = 2
		}
		if len(part) == 0 || len(part) > limit || strings.Trim(part, "0123456789") != "" {
			return tileKey{}, false
		}
	}
	zoom, _ := strconv.Atoi(parts[0])
	x, _ := strconv.Atoi(parts[1])
	y, _ := strconv.Atoi(parts[2])
	if zoom > 22 || x >= 1<<zoom || y >= 1<<zoom {
		return tileKey{}, false
	}
	return tileKey{zoom, x, y}, true
}

func (t tileKey) jpegPath() string {
	return fmt.Sprintf("/tiles/%d/%d/%d.jpg", t.zoom, t.x, t.y)
}

func tileLongitude(x float64, zoom int) float64 {
	return x/math.Ldexp(1, zoom)*360 - 180
}

func tileLatitude(y float64, zoom int) float64 {
	n := math.Pi * (1 - 2*y/math.Ldexp(1, zoom))
	return math.Atan(math.Sinh(n)) / tileRadPerDegree
}

func tileAt(lat, lon float64, zoom int) tileKey {
	n := math.Ldexp(1, zoom)
	rad := lat * tileRadPerDegree
	x := (lon + 180) / 360 * n
	y := (1 - math.Log(math.Tan(rad)+1/math.Cos(rad))/math.Pi) / 2 * n
	if math.IsNaN(y) || math.IsInf(y, 0) {
		y = 0
	}
	return tileKey{zoom, int(min(max(x, 0), n-1)), int(min(max(y, 0), n-1))}
}

func tileDistance(lat1, lon1, lat2, lon2 float64) float64 {
	dlon := lon2 - lon1
	if dlon > 180 {
		dlon -= 360
	} else if dlon < -180 {
		dlon += 360
	}
	dx := dlon * tileRadPerDegree * math.Cos((lat1+lat2)*0.5*tileRadPerDegree) * tileEarthRadiusM
	dy := (lat2 - lat1) * tileRadPerDegree * tileEarthRadiusM
	return math.Sqrt(dx*dx + dy*dy)
}

func tileIntersectsCircle(lat, lon, radius float64, key tileKey) bool {
	if radius < 0 {
		return false
	}
	west, east := tileLongitude(float64(key.x), key.zoom), tileLongitude(float64(key.x+1), key.zoom)
	north, south := tileLatitude(float64(key.y), key.zoom), tileLatitude(float64(key.y+1), key.zoom)
	mid := (west + east) / 2
	if lon-mid > 180 {
		lon -= 360
	} else if mid-lon > 180 {
		lon += 360
	}
	return tileDistance(lat, lon, min(max(lat, south), north), min(max(lon, west), east)) <= radius
}

func visitCircleTiles(lat, lon, radius float64, zoom int, visit func(tileKey)) int {
	if radius < 0 {
		return 0
	}
	latDelta := radius / (tileEarthRadiusM * tileRadPerDegree)
	lonDelta := latDelta / max(0.02, math.Cos(lat*tileRadPerDegree))
	north, south := min(85, lat+latDelta), max(-85, lat-latDelta)
	west, east := lon-lonDelta, lon+lonDelta
	if west < -180 {
		west += 360
	}
	if east > 180 {
		east -= 360
	}
	start, end := tileAt(north, west, zoom), tileAt(south, east, zoom)
	mask := (1 << zoom) - 1
	if lonDelta >= 180 {
		start.x, end.x = 0, mask
	}
	count := 0
	// A wrapped x range continues in column zero on the other side of ±180°.
	for x := start.x; ; x = (x + 1) & mask {
		for y := start.y; y <= end.y; y++ {
			key := tileKey{zoom, x, y}
			if tileIntersectsCircle(lat, lon, radius, key) {
				count++
				if visit != nil {
					visit(key)
				}
			}
		}
		if x == end.x {
			break
		}
	}
	return count
}

func makeTilePlan(input tileInput, total, used int64, files map[string]int64) tilePlan {
	plan := tilePlan{RadiusKm: input.RadiusKm, FreeBytes: max(total-used, 0)}
	disk := make(map[tileKey]*tileDiskEntry)
	var diskBytes int64
	for path, size := range files {
		key, ok := parseTilePath(path)
		if !ok {
			continue
		}
		entry := disk[key]
		if entry == nil {
			entry = &tileDiskEntry{key: key}
			disk[key] = entry
		}
		size = max(size, 0)
		entry.bytes += size
		entry.paths = append(entry.paths, path)
		diskBytes += size
	}
	other := max(used-diskBytes, 0)
	plan.CapacityBytes = max(total-tileReserve-other, 0)
	average := int64(tileDefaultBytes)
	if len(disk) >= tileMinSampleSize {
		average = max(used/int64(len(disk)), 1024)
	}

	var radii [tileZooms]float64
	var counts [tileZooms]int
	wanted := input.RadiusKm * 1000
	for i := range radii {
		radii[i] = wanted
		counts[i] = visitCircleTiles(input.Lat, input.Lon, wanted, tileMinZoom+i, nil)
	}
	contains := func(key tileKey) bool {
		return key.zoom >= tileMinZoom && key.zoom <= tileMaxZoom &&
			tileIntersectsCircle(input.Lat, input.Lon, radii[key.zoom-tileMinZoom], key)
	}
	evaluate := func() bool {
		plan.TileCount, plan.Present = 0, 0
		var inBytes int64
		for _, count := range counts {
			plan.TileCount += count
		}
		for _, entry := range disk {
			if contains(entry.key) {
				plan.Present++
				inBytes += entry.bytes
			}
		}
		plan.Missing = max(plan.TileCount-plan.Present, 0)
		missingBytes := int64(plan.Missing) * average
		plan.PlanBytes = inBytes + missingBytes
		budget := max(plan.FreeBytes+(diskBytes-inBytes)-tileReserve, 0)
		return missingBytes <= budget
	}
	if !evaluate() {
		plan.Shrunk = true
		dropAt := int(math.Ceil(wanted/tileRadiusStepM)) + 1
		for i := len(radii) - 1; i >= 0; i-- {
			setRadius := func(step int) bool {
				if step == dropAt {
					radii[i] = -1
				} else {
					radii[i] = max(wanted-float64(step*tileRadiusStepM), 0)
				}
				counts[i] = visitCircleTiles(input.Lat, input.Lon, radii[i], tileMinZoom+i, nil)
				return evaluate()
			}
			// At each zoom find the first 250 m reduction that fits before
			// shrinking the next lower zoom. Fewer planned tiles never use more space.
			if !setRadius(dropAt) {
				continue
			}
			firstFit := sort.Search(dropAt, func(step int) bool { return setRadius(step + 1) })
			setRadius(firstFit + 1)
			break
		}
	}
	for i, radius := range radii {
		plan.RadiiKm[i] = radius / 1000
		if radius < 0 {
			plan.RadiiKm[i] = -1
		}
		visitCircleTiles(input.Lat, input.Lon, radius, tileMinZoom+i, func(key tileKey) {
			plan.paths = append(plan.paths, key.jpegPath())
		})
	}
	var evictable []*tileDiskEntry
	for _, entry := range disk {
		if contains(entry.key) {
			continue
		}
		entry.distance = tileDistance(input.Lat, input.Lon,
			tileLatitude(float64(entry.key.y)+0.5, entry.key.zoom),
			tileLongitude(float64(entry.key.x)+0.5, entry.key.zoom))
		evictable = append(evictable, entry)
	}
	sort.Slice(evictable, func(i, j int) bool {
		a, b := evictable[i], evictable[j]
		if a.key.zoom != b.key.zoom {
			return a.key.zoom > b.key.zoom
		}
		if a.distance != b.distance {
			return a.distance > b.distance
		}
		if a.key.x != b.key.x {
			return a.key.x < b.key.x
		}
		return a.key.y < b.key.y
	})
	for _, entry := range evictable {
		sort.Strings(entry.paths)
		plan.victims = append(plan.victims, entry.paths...)
	}
	return plan
}
