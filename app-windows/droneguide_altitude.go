// SPDX-License-Identifier: GPL-3.0-or-later
package main

import "strings"

const (
	droneguideMetersPerFoot = 0.3048
	droneguideAGLCeilingM   = 500 * droneguideMetersPerFoot
)

// Keep doubtful rows in the WFS result so the app can classify them using
// their original reference and unit. Filter clearly out-of-band rows upstream.
const droneguideAltitudeCQL = "type_code <> 'TIME_ZONE' AND (" +
	"lower_limit_altitude_meter_agl IS NULL OR upper_limit_altitude_meter_agl IS NULL OR " +
	"lower_limit_altitude_meter_agl > upper_limit_altitude_meter_agl OR " +
	"((lower_limit_altitude_meter_agl <= 152.4 OR lower_limit_reference IN ('AGL','GND','SFC')) AND " +
	"(upper_limit_altitude_meter_agl >= 0 OR upper_limit_reference IN ('AGL','GND','SFC'))))"

func droneguideDirectAGL(value *float64, reference, unit string) *float64 {
	ref := strings.ToUpper(strings.TrimSpace(reference))
	markGround := ref == "GND" || ref == "SFC"
	if !markGround && ref != "AGL" {
		return nil
	}
	if value == nil {
		if markGround {
			zero := 0.0
			return &zero
		}
		return nil
	}
	switch {
	case unit == "M", *value == 0 && unit == "":
		return value
	case unit == "FT":
		meters := *value * droneguideMetersPerFoot
		return &meters
	default:
		return nil
	}
}

type droneguideBandMatch uint8

const (
	droneguideBandUnknown droneguideBandMatch = iota
	droneguideBandOutside
	droneguideBandInside
)

func droneguideIntersectBand(lower, upper *float64) droneguideBandMatch {
	// Treat inconsistent converted limits as unknown.
	if lower != nil && upper != nil && *lower > *upper {
		return droneguideBandUnknown
	}
	if lower != nil && *lower > droneguideAGLCeilingM || upper != nil && *upper < 0 {
		return droneguideBandOutside
	}
	if lower != nil && upper != nil {
		return droneguideBandInside
	}
	// A boundary inside the band is enough to confirm overlap even when
	// the other bound has an absolute reference or is missing.
	if lower != nil && *lower >= 0 || upper != nil && *upper <= droneguideAGLCeilingM {
		return droneguideBandInside
	}
	return droneguideBandUnknown
}

func (snapshot *droneguideSnapshot) selectAltitudeBand(zones []droneguideZone, omitted int) {
	snapshot.Zones = make([]droneguideZone, 0, len(zones))
	snapshot.Omitted = omitted
	snapshot.UnknownAltitudeCount = 0
	for _, zone := range zones {
		switch droneguideIntersectBand(zone.lowerAGL, zone.upperAGL) {
		case droneguideBandInside:
			snapshot.Zones = append(snapshot.Zones, zone)
		case droneguideBandUnknown:
			snapshot.UnknownAltitudeCount++
		}
	}
}
