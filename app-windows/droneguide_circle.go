// SPDX-License-Identifier: GPL-3.0-or-later
package main

import "math"

func (circle droneguideCircle) ring() []GeoPoint {
	// At close map zoom, keep the chord error below about half a metre for
	// ordinary geozones. Larger circles retain their exact radius as well.
	segments := min(720, max(96, int(math.Ceil(math.Pi/math.Acos(1-min(0.5/circle.RadiusM, 1))))))
	points := make([]GeoPoint, 0, segments+1)
	for i := range segments {
		bearing := 2 * math.Pi * float64(i) / float64(segments)
		points = append(points, droneguideDestination(circle.Center, bearing, circle.RadiusM))
	}
	return append(points, points[0])
}

// Vincenty's direct geodesic on the WGS 84 ellipsoid. The distance along
// each bearing is the published radius rather than a fixed degree offset.
func droneguideDestination(center GeoPoint, bearing, radius float64) GeoPoint {
	const (
		a   = 6378137.0
		f   = 1.0 / 298.257223563
		b   = a * (1 - f)
		rad = math.Pi / 180
	)
	sinBearing, cosBearing := math.Sincos(bearing)
	tanU := (1 - f) * math.Tan(center.Lat*rad)
	cosU := 1 / math.Hypot(1, tanU)
	sinU := tanU * cosU
	sigma1 := math.Atan2(tanU, cosBearing)
	sinAlpha := cosU * sinBearing
	cosSqAlpha := 1 - sinAlpha*sinAlpha
	uSq := cosSqAlpha * (a*a - b*b) / (b * b)
	littleA := 1 + uSq/16384*(4096+uSq*(-768+uSq*(320-175*uSq)))
	littleB := uSq / 1024 * (256 + uSq*(-128+uSq*(74-47*uSq)))
	base := radius / (b * littleA)
	sigma := base
	for range 20 {
		sinSigma, cosSigma := math.Sincos(sigma)
		cosMid := math.Cos(2*sigma1 + sigma)
		squareMid := cosMid * cosMid
		delta := littleB * sinSigma * (cosMid + littleB/4*(cosSigma*(-1+2*squareMid)-
			littleB/6*cosMid*(-3+4*sinSigma*sinSigma)*(-3+4*squareMid)))
		next := base + delta
		if math.Abs(next-sigma) < 1e-12 {
			sigma = next
			break
		}
		sigma = next
	}
	sinSigma, cosSigma := math.Sincos(sigma)
	cosMid := math.Cos(2*sigma1 + sigma)
	tmp := sinU*sinSigma - cosU*cosSigma*cosBearing
	lat2 := math.Atan2(sinU*cosSigma+cosU*sinSigma*cosBearing, (1-f)*math.Hypot(sinAlpha, tmp))
	lambda := math.Atan2(sinSigma*sinBearing, cosU*cosSigma-sinU*sinSigma*cosBearing)
	c := f / 16 * cosSqAlpha * (4 + f*(4-3*cosSqAlpha))
	lonDelta := lambda - (1-c)*f*sinAlpha*(sigma+c*sinSigma*(cosMid+c*cosSigma*(-1+2*cosMid*cosMid)))
	return GeoPoint{Lat: lat2 / rad, Lon: math.Remainder(center.Lon+lonDelta/rad, 360)}
}
