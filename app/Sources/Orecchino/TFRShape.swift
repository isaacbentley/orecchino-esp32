// TFRShape.swift — fit a TFR outline into the receivers' 24-point polygons
// without ever cutting inside the real boundary.
//
// The firmware holds at most TFR_PTS_MAX (24) vertices per TFR and tests
// incursion with a point-in-polygon on latitude/longitude. Keeping every nth
// vertex, as the app used to, draws chords *inside* the outline: a 30 NM
// circle lost a band ~475 m deep, where a drone inside the TFR read as
// outside. This instead sends an enclosing polygon: the convex hull, reduced
// by extending neighbouring edges (each step only adds area), then grown by
// a small margin so rounding to 5 decimals cannot pull an edge inside. It
// errs outward (a 30 NM circle gains at most ~480 m at the corners; a
// concave outline is filled in), which for a restriction is the safe side.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreLocation

enum TFRShape {
    /// The firmware's per-TFR vertex limit (rx_core.h TFR_PTS_MAX).
    static let maxPoints = 24

    private struct P { var x: Double; var y: Double }

    /// At most `maxPoints` vertices whose polygon contains every vertex of
    /// `ring` (and so the whole ring). A ring that already fits is returned
    /// unchanged (less a repeated closing vertex).
    static func enclosing(_ ring: [CLLocationCoordinate2D], maxPoints: Int = maxPoints,
                          marginM: Double = 5) -> [CLLocationCoordinate2D] {
        var pts = ring
        if pts.count > 1, let f = pts.first, let l = pts.last,
           f.latitude == l.latitude, f.longitude == l.longitude { pts.removeLast() }
        guard pts.count > maxPoints, maxPoints >= 4 else { return pts }

        // An affine map of lat/lon to metres: containment, convexity and the
        // firmware's lat/lon point-in-polygon all carry over exactly.
        let lat0 = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
        let kx = 111_320.0 * cos(lat0 * .pi / 180), ky = 110_540.0
        guard kx > 1 else { return Array(pts.prefix(maxPoints)) }
        let proj = pts.map { P(x: $0.longitude * kx, y: $0.latitude * ky) }

        var hull = convexHull(proj)
        guard hull.count >= 3 else { return Array(pts.prefix(maxPoints)) }
        while hull.count > maxPoints {
            guard let next = dropCheapestEdge(hull) else { break }
            hull = next
        }
        if hull.count > maxPoints { return Array(pts.prefix(maxPoints)) }   // cannot happen for n >= 5

        // Grow about the centroid so every edge moves out by >= marginM.
        let cx = hull.map(\.x).reduce(0, +) / Double(hull.count)
        let cy = hull.map(\.y).reduce(0, +) / Double(hull.count)
        var minEdge = Double.infinity
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            minEdge = min(minEdge, abs((b.x - a.x) * (a.y - cy) - (b.y - a.y) * (a.x - cx)) / len)
        }
        let s = minEdge.isFinite && minEdge > 0 ? 1 + marginM / minEdge : 1
        return hull.map {
            CLLocationCoordinate2D(latitude: (cy + ($0.y - cy) * s) / ky,
                                   longitude: (cx + ($0.x - cx) * s) / kx)
        }
    }

    /// Andrew's monotone chain; counter-clockwise, no collinear points.
    private static func convexHull(_ input: [P]) -> [P] {
        let p = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func cross(_ o: P, _ a: P, _ b: P) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [P] = [], upper: [P] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Remove the edge v[i]v[i+1] whose removal adds the least area: extend
    /// the edges on either side until they meet at p and replace both ends
    /// with p. The result is convex and contains the input. nil: no edge can
    /// go (only possible with fewer than 5 vertices).
    private static func dropCheapestEdge(_ v: [P]) -> [P]? {
        let n = v.count
        var best: (i: Int, p: P, area: Double)?
        for i in 0..<n {
            let a0 = v[(i - 1 + n) % n], a1 = v[i], b1 = v[(i + 1) % n], b0 = v[(i + 2) % n]
            let d1 = P(x: a1.x - a0.x, y: a1.y - a0.y)       // along the edge before, forward
            let d2 = P(x: b1.x - b0.x, y: b1.y - b0.y)       // along the edge after, backward
            let den = d1.x * d2.y - d1.y * d2.x
            guard abs(den) > 1e-12 else { continue }
            // a1 + t d1 = b1 + u d2
            let rx = b1.x - a1.x, ry = b1.y - a1.y
            let t = (rx * d2.y - ry * d2.x) / den
            let u = (rx * d1.y - ry * d1.x) / den
            guard t > 0, u > 0 else { continue }
            let p = P(x: a1.x + t * d1.x, y: a1.y + t * d1.y)
            let area = abs((b1.x - a1.x) * (p.y - a1.y) - (b1.y - a1.y) * (p.x - a1.x)) / 2
            if best == nil || area < best!.area { best = (i, p, area) }
        }
        guard let b = best else { return nil }
        var out: [P] = []
        out.reserveCapacity(n - 1)
        let j = (b.i + 1) % n
        for k in 0..<n where k != b.i && k != j { out.append(v[k]) }
        // Put p where v[i] was: after v[i-1] in cyclic order.
        let before = (b.i - 1 + n) % n
        let at = out.firstIndex { $0.x == v[before].x && $0.y == v[before].y }.map { $0 + 1 } ?? out.count
        out.insert(b.p, at: at)
        return out
    }

    /// Ray-casting point-in-polygon on lat/lon, as the receivers test it.
    static func contains(_ poly: [CLLocationCoordinate2D], _ c: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.latitude > c.latitude) != (b.latitude > c.latitude) {
                let x = (b.longitude - a.longitude) * (c.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if c.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
