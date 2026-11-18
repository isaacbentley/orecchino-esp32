// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

const (
	droneguideMaxFeatures = 10000
	droneguideMaxPoints   = 500000
)

var errDroneguideNoArea = errors.New("polygoon heeft minder dan drie unieke punten of geen oppervlak")

type droneguideAuthority struct {
	Name           string `json:"name,omitempty"`
	Service        string `json:"service,omitempty"`
	Email          string `json:"email,omitempty"`
	ContactName    string `json:"contactName,omitempty"`
	SiteURL        string `json:"siteURL,omitempty"`
	Phone          string `json:"phone,omitempty"`
	Purpose        string `json:"purpose,omitempty"`
	IntervalBefore string `json:"intervalBefore,omitempty"`
}

type droneguideDailyPeriod struct {
	Day       []string `json:"day,omitempty"`
	StartTime string   `json:"startTime,omitempty"`
	EndTime   string   `json:"endTime,omitempty"`
}

type droneguidePeriod struct {
	Permanent     string                  `json:"permanent,omitempty"`
	StartDateTime string                  `json:"startDateTime,omitempty"`
	EndDateTime   string                  `json:"endDateTime,omitempty"`
	Schedule      []droneguideDailyPeriod `json:"schedule,omitempty"`
}

type droneguideCircle struct {
	Center  GeoPoint `json:"center"`
	RadiusM float64  `json:"radiusM"`
}

type droneguideZone struct {
	ID               string                `json:"id"`
	Name             string                `json:"name"`
	Restriction      string                `json:"restriction"`
	Reason           string                `json:"reason,omitempty"`
	Message          string                `json:"message,omitempty"`
	Schedule         string                `json:"schedule,omitempty"`
	Polygons         [][][]GeoPoint        `json:"polygons"`
	Circle           *droneguideCircle     `json:"circle,omitempty"`
	Lower            *float64              `json:"lower,omitempty"`
	Upper            *float64              `json:"upper,omitempty"`
	LowerReference   string                `json:"lowerReference,omitempty"`
	UpperReference   string                `json:"upperReference,omitempty"`
	LowerUnit        string                `json:"lowerUnit,omitempty"`
	UpperUnit        string                `json:"upperUnit,omitempty"`
	Unit             string                `json:"unit,omitempty"`
	ValidFrom        string                `json:"validFrom,omitempty"`
	ValidUntil       string                `json:"validUntil,omitempty"`
	Authorities      []droneguideAuthority `json:"authorities,omitempty"`
	Applicability    []droneguidePeriod    `json:"applicability,omitempty"`
	Conditions       []string              `json:"conditions,omitempty"`
	ActiveAtSnapshot *bool                 `json:"activeAtSnapshot,omitempty"`
	lowerAGL         *float64
	upperAGL         *float64
}

type droneguideProjection struct {
	Type        string
	Coordinates json.RawMessage
	Center      []*float64
	Radius      float64
	Geometries  []droneguideProjection
}

type droneguideAltitude struct {
	Lower    *float64 `json:"lowerLimit"`
	Upper    *float64 `json:"upperLimit"`
	LowerRef string   `json:"lowerVerticalReference"`
	UpperRef string   `json:"upperVerticalReference"`
	Unit     string   `json:"uomDimensions"`
}

type droneguideVolume struct {
	droneguideAltitude
	Projection droneguideProjection `json:"horizontalProjection"`
}

type droneguideMetadata struct {
	ID            string                `json:"identifier"`
	Name          json.RawMessage       `json:"name"`
	Country       string                `json:"country"`
	Restriction   string                `json:"restriction"`
	Conditions    []string              `json:"restrictionConditions"`
	Reason        json.RawMessage       `json:"reason"`
	OtherReason   string                `json:"otherReasonInfo"`
	Message       json.RawMessage       `json:"message"`
	Authorities   []droneguideAuthority `json:"zoneAuthority"`
	Applicability []droneguidePeriod    `json:"applicability"`
}

type droneguideEDZone struct {
	droneguideMetadata
	Geometry []droneguideVolume `json:"geometry"`
}

type droneguideGeoProps struct {
	droneguideMetadata
	droneguideAltitude
	UniqueID            string          `json:"unique_identifier"`
	Code                string          `json:"code"`
	TypeCode            string          `json:"type_code"`
	Description         json.RawMessage `json:"description"`
	NativeLower         *float64        `json:"lower_limit_altitude"`
	NativeUpper         *float64        `json:"upper_limit_altitude"`
	NativeLowerAGL      *float64        `json:"lower_limit_altitude_meter_agl"`
	NativeUpperAGL      *float64        `json:"upper_limit_altitude_meter_agl"`
	NativeLowerRef      string          `json:"lower_limit_reference"`
	NativeUpperRef      string          `json:"upper_limit_reference"`
	NativeLowerUnit     string          `json:"lower_limit_unit"`
	NativeUpperUnit     string          `json:"upper_limit_unit"`
	Lower               *float64        `json:"lower"`
	Upper               *float64        `json:"upper"`
	LowerRef            string          `json:"lowerReference"`
	UpperRef            string          `json:"upperReference"`
	LowerUnit           string          `json:"lowerUnit"`
	UpperUnit           string          `json:"upperUnit"`
	Unit                string          `json:"unit"`
	ValidFrom           string          `json:"validFrom"`
	ValidUntil          string          `json:"validUntil"`
	Schedule            string          `json:"schedule"`
	ActiveAtWindowStart *int            `json:"active_at_window_start"`
}

type droneguideGeoFeature struct {
	Type       string
	ID         json.RawMessage
	Geometry   *droneguideProjection
	Properties droneguideGeoProps
}

type droneguideCollection struct {
	Type     string
	Features json.RawMessage
	CRS      *struct {
		Properties struct{ Name string }
	}
}

func (c droneguideCollection) checkGeoJSON() error {
	if c.CRS != nil {
		crs := strings.ToUpper(c.CRS.Properties.Name)
		if !strings.HasSuffix(crs, ":4326") && !strings.HasSuffix(crs, ":CRS84") && !strings.HasSuffix(crs, "/CRS84") {
			return errors.New("het bestand gebruikt geen WGS 84-coördinaten")
		}
	}
	return nil
}

func parseDroneguide(data []byte) ([]droneguideZone, error) {
	zones, _, err := parseDroneguideSnapshot(data, false)
	return zones, err
}

func droneguideJSONBytes(data []byte) []byte {
	return bytes.TrimSpace(bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}))
}

func parseDroneguideSnapshot(data []byte, live bool) ([]droneguideZone, int, error) {
	data = droneguideJSONBytes(data)
	if len(data) == 0 {
		return nil, 0, errors.New("leeg JSON-bestand")
	}
	var features []json.RawMessage
	var collection droneguideCollection
	if data[0] == '[' {
		if err := json.Unmarshal(data, &features); err != nil {
			return nil, 0, errors.New("ongeldige geozone-JSON")
		}
	} else {
		if err := json.Unmarshal(data, &collection); err != nil {
			return nil, 0, errors.New("ongeldige geozone-JSON")
		}
		if collection.Type == "Feature" {
			features = []json.RawMessage{data}
		} else if len(collection.Features) == 0 {
			features = []json.RawMessage{data}
		} else if err := json.Unmarshal(collection.Features, &features); err != nil {
			return nil, 0, errors.New("geen geozoneverzameling gevonden in de JSON")
		}
	}
	if len(features) == 0 || len(features) > droneguideMaxFeatures {
		return nil, 0, errors.New("het bestand bevat geen zones of te veel zones")
	}
	geoJSON := collection.Type == "FeatureCollection" || collection.Type == "Feature"
	if live && collection.Type != "FeatureCollection" {
		return nil, 0, errors.New("Droneguide levert geen GeoJSON-verzameling")
	}
	if geoJSON {
		if err := collection.checkGeoJSON(); err != nil {
			return nil, 0, err
		}
	}
	zones := make([]droneguideZone, 0, len(features))
	ids := make(map[string]bool, len(features))
	points, omitted := 0, 0
	for index, raw := range features {
		var parsed []droneguideZone
		var err error
		if geoJSON {
			parsed, err = droneguideFromGeo(raw, live)
		} else {
			parsed, err = droneguideFromED(raw)
		}
		if live && errors.Is(err, errDroneguideNoArea) {
			omitted++
			continue
		}
		if err != nil {
			return nil, 0, fmt.Errorf("zone %d: %w", index+1, err)
		}
		for _, zone := range parsed {
			if ids[zone.ID] {
				return nil, 0, fmt.Errorf("zone %d: dubbele zonecode %q", index+1, zone.ID)
			}
			ids[zone.ID] = true
			for _, polygon := range zone.Polygons {
				for _, ring := range polygon {
					points += len(ring)
				}
			}
			if len(zones) >= droneguideMaxFeatures || points > droneguideMaxPoints {
				return nil, 0, errors.New("het bestand bevat te veel zones of kaartpunten")
			}
			zones = append(zones, zone)
		}
	}
	if len(zones) == 0 {
		return nil, 0, errors.New("geen Belgische dronezones gevonden")
	}
	return zones, omitted, nil
}

func droneguideText(raw json.RawMessage) string {
	var direct string
	choices := make(map[string]string)
	if json.Unmarshal(raw, &direct) == nil {
		direct = strings.TrimSpace(direct)
		if !strings.HasPrefix(direct, "{") || json.Unmarshal([]byte(direct), &choices) != nil {
			return direct
		}
	} else if json.Unmarshal(raw, &choices) != nil {
		return ""
	}
	for _, language := range []string{"nl", "nl-BE", "en", "fr", "de"} {
		if name := strings.TrimSpace(choices[language]); name != "" {
			return name
		}
	}
	keys := make([]string, 0, len(choices))
	for key := range choices {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if name := strings.TrimSpace(choices[key]); name != "" {
			return name
		}
	}
	return ""
}

func droneguideReasons(reason json.RawMessage, other string) string {
	var reasons []string
	text := droneguideText(reason)
	if json.Unmarshal(reason, &reasons) == nil {
		text = strings.Join(reasons, ", ")
	}
	if text == "" {
		return strings.TrimSpace(other)
	}
	if other == "" {
		return text
	}
	return text + " · " + strings.TrimSpace(other)
}

func droneguideFirst(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func droneguideRestriction(restriction string) (string, error) {
	upper := strings.ToUpper(strings.TrimSpace(restriction))
	switch upper {
	case "PROHIBITED", "REQ_AUTHORISATION", "CONDITIONAL", "NO_RESTRICTION":
		return upper, nil
	case "REQ_AUTHORIZATION":
		return "REQ_AUTHORISATION", nil
	default:
		return "", fmt.Errorf("onbekende beperking %q", restriction)
	}
}

func (m droneguideMetadata) zone() (droneguideZone, error) {
	if country := strings.ToUpper(strings.TrimSpace(m.Country)); country != "" && country != "BEL" && country != "BE" {
		return droneguideZone{}, fmt.Errorf("landcode %q valt buiten België", m.Country)
	}
	restriction, err := droneguideRestriction(m.Restriction)
	if err != nil {
		return droneguideZone{}, err
	}
	id := strings.TrimSpace(m.ID)
	if id == "" {
		return droneguideZone{}, errors.New("geen zonecode opgegeven")
	}
	zone := droneguideZone{
		ID: id, Name: droneguideFirst(droneguideText(m.Name), id), Restriction: restriction,
		Reason: droneguideReasons(m.Reason, m.OtherReason), Message: droneguideText(m.Message),
		Applicability: m.Applicability, Authorities: m.Authorities, Conditions: m.Conditions,
	}
	if len(zone.Applicability) == 1 {
		p := zone.Applicability[0]
		zone.ValidFrom, zone.ValidUntil = p.StartDateTime, p.EndDateTime
	}
	var schedule []string
	for _, period := range zone.Applicability {
		if err := droneguideCheckValidity(period.StartDateTime, period.EndDateTime); err != nil {
			return droneguideZone{}, err
		}
		var details []string
		if strings.EqualFold(period.Permanent, "YES") {
			details = append(details, "Permanent")
		}
		if len(zone.Applicability) > 1 {
			if period.StartDateTime != "" {
				details = append(details, "Vanaf "+period.StartDateTime)
			}
			if period.EndDateTime != "" {
				details = append(details, "Tot "+period.EndDateTime)
			}
		}
		for _, daily := range period.Schedule {
			if daily.StartTime != "" || daily.EndTime != "" {
				details = append(details, strings.TrimSpace(strings.Join(daily.Day, ", ")+" "+daily.StartTime+" – "+daily.EndTime))
			}
		}
		if len(details) > 0 {
			schedule = append(schedule, strings.Join(details, " · "))
		}
	}
	zone.Schedule = strings.Join(schedule, " | ")
	return zone, nil
}

func droneguideCheckValidity(from, until string) error {
	fields := []string{from, until}
	var dates [2]time.Time
	for index, field := range fields {
		if field == "" {
			continue
		}
		parsed, err := time.Parse(time.RFC3339, field)
		if err != nil {
			return fmt.Errorf("ongeldige geldigheidstijd %q", field)
		}
		dates[index] = parsed
	}
	if !dates[0].IsZero() && !dates[1].IsZero() && dates[1].Before(dates[0]) {
		return errors.New("einddatum ligt vóór de begindatum")
	}
	return nil
}

func droneguideUnit(unit string) string {
	switch upper := strings.ToUpper(strings.TrimSpace(unit)); upper {
	case "F", "FEET", "FT":
		return "FT"
	case "METERS", "METRES", "M":
		return "M"
	default:
		return upper
	}
}

func (z *droneguideZone) altitude(alt droneguideAltitude, lowUnit, highUnit string) {
	z.Lower, z.Upper, z.LowerReference, z.UpperReference = alt.Lower, alt.Upper, alt.LowerRef, alt.UpperRef
	z.LowerUnit = droneguideUnit(droneguideFirst(lowUnit, alt.Unit))
	z.UpperUnit = droneguideUnit(droneguideFirst(highUnit, alt.Unit))
	if z.LowerUnit == z.UpperUnit {
		z.Unit = z.LowerUnit
	}
	z.lowerAGL = droneguideDirectAGL(z.Lower, z.LowerReference, z.LowerUnit)
	z.upperAGL = droneguideDirectAGL(z.Upper, z.UpperReference, z.UpperUnit)
}

func droneguideFromED(raw json.RawMessage) ([]droneguideZone, error) {
	var item droneguideEDZone
	if err := json.Unmarshal(raw, &item); err != nil {
		return nil, errors.New("ongeldig ED-269-zoneobject")
	}
	root, err := item.zone()
	if err != nil {
		return nil, err
	}
	if len(item.Geometry) == 0 || len(item.Geometry) > droneguideMaxFeatures {
		return nil, errors.New("geen geldige zonevolumes gevonden")
	}
	zones := make([]droneguideZone, 0, len(item.Geometry))
	for index, volume := range item.Geometry {
		z := root
		if index > 0 {
			z.ID = fmt.Sprintf("%s#%d", z.ID, index+1)
		}
		z.altitude(volume.droneguideAltitude, "", "")
		z.Polygons, z.Circle, err = volume.Projection.polygons(false)
		if err != nil {
			return nil, err
		}
		zones = append(zones, z)
	}
	return zones, nil
}

func droneguideFromGeo(raw json.RawMessage, live bool) ([]droneguideZone, error) {
	var feature droneguideGeoFeature
	if err := json.Unmarshal(raw, &feature); err != nil || feature.Type != "Feature" {
		return nil, errors.New("ongeldig GeoJSON-object")
	}
	p := feature.Properties
	if strings.EqualFold(p.TypeCode, "TIME_ZONE") {
		return nil, nil
	}
	var featureID string
	if json.Unmarshal(feature.ID, &featureID) != nil {
		var n json.Number
		if json.Unmarshal(feature.ID, &n) == nil {
			featureID = n.String()
		}
	}
	p.ID = droneguideFirst(p.ID, p.UniqueID, featureID, p.Code)
	z, err := p.zone()
	if err != nil {
		return nil, err
	}
	if z.Message == "" {
		z.Message = droneguideText(p.Description)
	}
	if z.Reason == "" {
		z.Reason = p.TypeCode
	}
	z.ValidFrom = droneguideFirst(p.ValidFrom, z.ValidFrom)
	z.ValidUntil = droneguideFirst(p.ValidUntil, z.ValidUntil)
	z.Schedule = droneguideFirst(p.Schedule, z.Schedule)
	if err := droneguideCheckValidity(z.ValidFrom, z.ValidUntil); err != nil {
		return nil, err
	}
	alt := p.droneguideAltitude
	if alt.Lower == nil {
		alt.Lower = p.NativeLower
	}
	if alt.Lower == nil {
		alt.Lower = p.Lower
	}
	if alt.Upper == nil {
		alt.Upper = p.NativeUpper
	}
	if alt.Upper == nil {
		alt.Upper = p.Upper
	}
	alt.LowerRef = droneguideFirst(alt.LowerRef, p.NativeLowerRef, p.LowerRef)
	alt.UpperRef = droneguideFirst(alt.UpperRef, p.NativeUpperRef, p.UpperRef)
	alt.Unit = droneguideFirst(alt.Unit, p.Unit)
	z.altitude(alt, droneguideFirst(p.NativeLowerUnit, p.LowerUnit), droneguideFirst(p.NativeUpperUnit, p.UpperUnit))
	if z.lowerAGL == nil {
		z.lowerAGL = p.NativeLowerAGL
	}
	if z.upperAGL == nil {
		z.upperAGL = p.NativeUpperAGL
	}
	// The WFS window fields use 0 for active and 1 for inactive. Never
	// interpret unbound defaults in an imported file as live timings.
	if live && p.ActiveAtWindowStart != nil {
		switch *p.ActiveAtWindowStart {
		case 0, 1:
			active := *p.ActiveAtWindowStart == 0
			z.ActiveAtSnapshot = &active
		}
	}
	if feature.Geometry == nil {
		return nil, errDroneguideNoArea
	}
	z.Polygons, z.Circle, err = feature.Geometry.polygons(live)
	if err != nil {
		return nil, err
	}
	return []droneguideZone{z}, nil
}

func droneguidePoint(raw []*float64) (GeoPoint, error) {
	if len(raw) < 2 || raw[0] == nil || raw[1] == nil || !(math.Abs(*raw[0]) <= 180 && math.Abs(*raw[1]) <= 90) {
		return GeoPoint{}, errors.New("ongeldig kaartpunt")
	}
	return GeoPoint{Lat: *raw[1], Lon: *raw[0]}, nil
}

func droneguideRingHasArea(ring []GeoPoint) bool {
	if len(ring) < 3 {
		return false
	}
	var area float64
	previous := ring[len(ring)-1]
	origin := ring[0]
	for _, point := range ring {
		area += math.Remainder(previous.Lon-origin.Lon, 360)*(point.Lat-origin.Lat) -
			math.Remainder(point.Lon-origin.Lon, 360)*(previous.Lat-origin.Lat)
		previous = point
	}
	return area != 0
}

func droneguidePolygon(raw [][][]*float64, live bool) ([][]GeoPoint, error) {
	polygon := make([][]GeoPoint, 0, len(raw))
	exteriorHasArea := false
	for index, rawRing := range raw {
		ring := make([]GeoPoint, 0, len(rawRing)+1)
		for _, coord := range rawRing {
			point, err := droneguidePoint(coord)
			if err != nil {
				return nil, err
			}
			ring = append(ring, point)
		}
		hasArea := droneguideRingHasArea(ring)
		if index == 0 {
			exteriorHasArea = hasArea
		}
		if !hasArea {
			if !live {
				return nil, errDroneguideNoArea
			}
			continue
		}
		if ring[0] != ring[len(ring)-1] {
			ring = append(ring, ring[0])
		}
		polygon = append(polygon, ring)
	}
	if !exteriorHasArea {
		return nil, errDroneguideNoArea
	}
	return polygon, nil
}

func (p droneguideProjection) polygons(live bool) ([][][]GeoPoint, *droneguideCircle, error) {
	switch strings.ToLower(p.Type) {
	case "polygon":
		var raw [][][]*float64
		if err := json.Unmarshal(p.Coordinates, &raw); err != nil {
			return nil, nil, errors.New("ongeldige polygooncoördinaten")
		}
		polygon, err := droneguidePolygon(raw, live)
		if err != nil {
			return nil, nil, err
		}
		return [][][]GeoPoint{polygon}, nil, nil
	case "multipolygon":
		var raw [][][][]*float64
		if err := json.Unmarshal(p.Coordinates, &raw); err != nil || len(raw) == 0 {
			return nil, nil, errors.New("ongeldige MultiPolygon-coördinaten")
		}
		polys := make([][][]GeoPoint, 0, len(raw))
		for _, item := range raw {
			polygon, err := droneguidePolygon(item, live)
			if live && errors.Is(err, errDroneguideNoArea) {
				continue
			}
			if err != nil {
				return nil, nil, err
			}
			polys = append(polys, polygon)
		}
		if len(polys) == 0 {
			return nil, nil, errDroneguideNoArea
		}
		return polys, nil, nil
	case "circle":
		center, err := droneguidePoint(p.Center)
		if err != nil || !(p.Radius > 0 && p.Radius <= 1_000_000) {
			return nil, nil, errors.New("ongeldige cirkel")
		}
		circle := droneguideCircle{Center: center, RadiusM: p.Radius}
		return [][][]GeoPoint{{circle.ring()}}, &circle, nil
	case "geometrycollection":
		var polygons [][][]GeoPoint
		for _, part := range p.Geometries {
			// An area can have supplementary lines in a GeometryCollection.
			switch strings.ToLower(part.Type) {
			case "linestring", "multilinestring", "point", "multipoint":
				continue
			}
			areas, _, err := part.polygons(live)
			if live && errors.Is(err, errDroneguideNoArea) {
				continue
			}
			if err != nil {
				return nil, nil, err
			}
			polygons = append(polygons, areas...)
		}
		if len(polygons) > 0 {
			return polygons, nil, nil
		}
		return nil, nil, errDroneguideNoArea
	case "linestring", "multilinestring", "point", "multipoint":
		if live {
			return nil, nil, errDroneguideNoArea
		}
	}
	return nil, nil, fmt.Errorf("niet-ondersteunde zonegeometrie %q", p.Type)
}
