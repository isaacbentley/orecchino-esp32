// TilePlan.swift — which map tiles a receiver should hold, and whether they
// fit its flash. A line-for-line port of firmware/common/tile_plan.h (the
// reference, with tests/tile_plan_test.cpp); the T5's own Wi-Fi fetch and
// this Mac's push plan the same way. Change one, change both.
//
//   1. The area is a circle around the centre, per zoom (12-15): a tile is in
//      when the nearest point of its box is within that zoom's radius.
//   2. Tiles already on the board are counted (fs_ls: path + on-flash bytes).
//   3. Missing ones are estimated at the board's average on-flash tile size
//      (used / tiles, once >= 20 tiles exist), else 12 KB; never under 1 KB.
//      (Esri World Dark Gray JPEGs: 5.8-19.5 KB over San Francisco, 8-20 KB
//      on flash in 4 KB blocks.)
//   4. Budget = free + tiles on flash OUTSIDE the plan - 1 MB reserve (>= 0)
//      (they may be evicted; a tile inside the plan never is; a board already
//      under the reserve owes the difference out of them).
//   5. If the missing tiles do not fit, z15's radius shrinks first (250 m
//      steps, then dropped), then z14, z13, z12.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum TilePlanner {
    static let zmin = 12, zmax = 15, nz = 4
    static let reserve: UInt64 = 1024 * 1024
    static let defaultBytes: UInt32 = 12288
    static let minSample: UInt32 = 20
    static let stepM = 250.0
    static let maxRadiusM = 30000.0
    static let earthRM = 6371000.0
    static let deg = Double.pi / 180.0

    // MARK: Tiles and keys

    static func key(_ z: Int, _ x: Int32, _ y: Int32) -> UInt64 {
        (UInt64(UInt32(z)) << 44) | (UInt64(UInt32(bitPattern: x)) << 22) | UInt64(UInt32(bitPattern: y))
    }
    static func split(_ k: UInt64) -> (z: Int, x: Int32, y: Int32) {
        (Int(k >> 44), Int32((k >> 22) & 0x3FFFFF), Int32(k & 0x3FFFFF))
    }

    static func lonOf(_ x: Double, _ z: Int) -> Double { x / Double(1 << z) * 360.0 - 180.0 }
    static func latOf(_ y: Double, _ z: Int) -> Double {
        let n = Double.pi * (1.0 - 2.0 * y / Double(1 << z))
        return atan(sinh(n)) / deg
    }

    static func tileOf(lat: Double, lon: Double, z: Int) -> (x: Int32, y: Int32) {
        let n = Double(1 << z)
        let rad = lat * deg
        let fx = (lon + 180.0) / 360.0 * n
        let fy = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / Double.pi) / 2.0 * n
        let lim = Int32((1 << z) - 1)
        // C's (int32_t) cast truncates toward zero, as Int32(_:) does.
        var x = fx.isFinite ? Int32(max(min(fx, 2e9), -2e9)) : 0
        var y = fy.isFinite ? Int32(max(min(fy, 2e9), -2e9)) : 0
        x = min(max(x, 0), lim)
        y = min(max(y, 0), lim)
        return (x, y)
    }

    static func distM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        var dlon = lon2 - lon1
        if dlon > 180 { dlon -= 360 } else if dlon < -180 { dlon += 360 }
        let dx = dlon * deg * cos((lat1 + lat2) * 0.5 * deg) * earthRM
        let dy = (lat2 - lat1) * deg * earthRM
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Does tile (z, x, y) touch the circle (lat, lon, r)? r < 0: nothing does.
    static func inCircle(lat: Double, lon: Double, r: Double, z: Int, x: Int32, y: Int32) -> Bool {
        if r < 0 { return false }
        let w = lonOf(Double(x), z), e = lonOf(Double(x) + 1, z)
        let n = latOf(Double(y), z), s = latOf(Double(y) + 1, z)
        // The centre in the tile's frame (within 180° of the tile's middle):
        // across the antimeridian its nearest edge is the one 360° away in
        // raw longitude, which a plain clamp would miss.
        let mid = (w + e) * 0.5
        var lo = lon
        if lo - mid > 180 { lo -= 360 } else if mid - lo > 180 { lo += 360 }
        let plat = lat < s ? s : (lat > n ? n : lat)
        let plon = lo < w ? w : (lo > e ? e : lo)
        return distM(lat, lo, plat, plon) <= r
    }

    /// The columns run west to east from x0 to x1 and may wrap past the
    /// antimeridian: x0 > x1 means x0...lim, then 0...x1 (a circle
    /// straddling ±180 holds tiles on both sides). Walk them with
    /// boxColumns; rows never wrap. (tile_plan.h TileBox)
    struct Box { var x0, y0, x1, y1: Int32 }

    /// How many columns the box spans (wrapping counted through).
    static func boxCols(_ b: Box, z: Int) -> UInt32 {
        let n = Int32(1 << z)
        return b.x0 <= b.x1 ? UInt32(b.x1 - b.x0 + 1) : UInt32(n - b.x0 + b.x1 + 1)
    }
    /// The i-th column of the box (0 <= i < boxCols), wrapped.
    static func boxCol(_ b: Box, z: Int, _ i: UInt32) -> Int32 {
        Int32((UInt32(bitPattern: b.x0) &+ i) & UInt32((1 << z) - 1))
    }
    /// The box's columns, west to east, wrapped at the antimeridian.
    static func boxColumns(_ b: Box, z: Int) -> [Int32] {
        (0..<boxCols(b, z: z)).map { boxCol(b, z: z, $0) }
    }

    static func circleBox(lat: Double, lon: Double, r rIn: Double, z: Int) -> Box {
        let r = rIn < 0 ? 0 : rIn
        let dlat = r / (earthRM * deg)
        let c = cos(lat * deg)
        let dlon = r / (earthRM * deg * (c < 0.02 ? 0.02 : c))
        var n = lat + dlat, s = lat - dlat
        if n > 85.0 { n = 85.0 }
        if s < -85.0 { s = -85.0 }
        // Across the antimeridian the west/east edges wrap round (x0 > x1);
        // a circle wider than the world takes every column.
        var w = lon - dlon, e = lon + dlon
        if w < -180.0 { w += 360.0 }
        if e > 180.0 { e -= 360.0 }
        let a = tileOf(lat: n, lon: w, z: z), b = tileOf(lat: s, lon: e, z: z)
        var box = Box(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
        if dlon >= 180.0 { box.x0 = 0; box.x1 = Int32(1 << z) - 1 }
        return box
    }

    static func circleCount(lat: Double, lon: Double, r: Double, z: Int) -> UInt32 {
        if r < 0 { return 0 }
        let b = circleBox(lat: lat, lon: lon, r: r, z: z)
        var n: UInt32 = 0
        if b.y0 <= b.y1 {
            for x in boxColumns(b, z: z) { for y in b.y0...b.y1 where inCircle(lat: lat, lon: lon, r: r, z: z, x: x, y: y) { n += 1 } }
        }
        return n
    }

    /// Every tile of the circle at zoom z (columns west to east, then y
    /// ascending; tile_plan_next's order).
    static func circleTiles(lat: Double, lon: Double, r: Double, z: Int) -> [(x: Int32, y: Int32)] {
        if r < 0 { return [] }
        let b = circleBox(lat: lat, lon: lon, r: r, z: z)
        var out: [(Int32, Int32)] = []
        if b.y0 <= b.y1 {
            for x in boxColumns(b, z: z) { for y in b.y0...b.y1 where inCircle(lat: lat, lon: lon, r: r, z: z, x: x, y: y) { out.append((x, y)) } }
        }
        return out
    }

    // MARK: The plan

    struct OnDisk: Equatable { var key: UInt64; var bytes: UInt32 }

    struct Plan: Equatable {
        var lat = 0.0, lon = 0.0
        var radiusM = [Double](repeating: 0, count: nz)    // per zoom (z - 12); < 0: dropped
        var wantM = 0.0
        var tiles = [UInt32](repeating: 0, count: nz)
        var have = [UInt32](repeating: 0, count: nz)
        var total: UInt32 = 0, present: UInt32 = 0, missing: UInt32 = 0
        var avgBytes: UInt32 = 0
        var diskTiles: UInt32 = 0
        var diskTileBytes: UInt64 = 0
        var fsTotal: UInt64 = 0, fsUsed: UInt64 = 0, fsFree: UInt64 = 0
        var capacity: UInt64 = 0
        var evictable: UInt64 = 0
        var budget: UInt64 = 0
        var needBytes: UInt64 = 0
        var planBytes: UInt64 = 0
        var fits = false, shrunk = false

        func contains(z: Int, x: Int32, y: Int32) -> Bool {
            guard z >= zmin && z <= zmax else { return false }
            return inCircle(lat: lat, lon: lon, r: radiusM[z - zmin], z: z, x: x, y: y)
        }

        /// Every tile of the plan, zoom ascending, then x, then y (tile_plan_next).
        var allTiles: [(z: Int, x: Int32, y: Int32)] {
            (zmin...zmax).flatMap { z in circleTiles(lat: lat, lon: lon, r: radiusM[z - zmin], z: z).map { (z, $0.x, $0.y) } }
        }
    }

    static func eval(_ p: inout Plan, _ d: [OnDisk]) {
        p.total = 0
        for i in 0..<nz {
            p.tiles[i] = circleCount(lat: p.lat, lon: p.lon, r: p.radiusM[i], z: zmin + i)
            p.have[i] = 0
            p.total += p.tiles[i]
        }
        var inBytes: UInt64 = 0
        p.evictable = 0
        p.present = 0
        for t in d {
            let (z, x, y) = split(t.key)
            if p.contains(z: z, x: x, y: y) {
                p.have[z - zmin] += 1
                p.present += 1
                inBytes += UInt64(t.bytes)
            } else {
                p.evictable += UInt64(t.bytes)
            }
        }
        p.missing = p.total > p.present ? p.total - p.present : 0
        p.needBytes = UInt64(p.missing) * UInt64(p.avgBytes)
        p.planBytes = inBytes + p.needBytes
        let avail = p.fsFree + p.evictable   // under the reserve: the deficit comes off the evictable
        p.budget = avail > reserve ? avail - reserve : 0
        p.fits = p.needBytes <= p.budget
    }

    /// Plan the circle of radius wantM around (lat, lon), shrinking it (z15
    /// first) until it fits. d: the tiles on flash, sorted by key.
    static func make(lat: Double, lon: Double, wantM: Double, fsTotal: UInt64, fsUsed: UInt64,
                     disk dIn: [OnDisk]) -> Plan {
        let d = dIn.sorted { $0.key < $1.key }
        var p = Plan()
        p.lat = lat
        p.lon = lon
        p.wantM = wantM
        p.fsTotal = fsTotal
        p.fsUsed = fsUsed
        p.fsFree = fsTotal > fsUsed ? fsTotal - fsUsed : 0
        p.diskTiles = UInt32(d.count)
        for t in d { p.diskTileBytes += UInt64(t.bytes) }
        let other = fsUsed > p.diskTileBytes ? fsUsed - p.diskTileBytes : 0
        p.capacity = fsTotal > reserve + other ? fsTotal - reserve - other : 0
        p.avgBytes = UInt32(d.count) >= minSample ? UInt32(truncatingIfNeeded: fsUsed / UInt64(d.count)) : defaultBytes
        if p.avgBytes < 1024 { p.avgBytes = 1024 }
        for i in 0..<nz { p.radiusM[i] = wantM }
        eval(&p, d)
        var i = nz - 1
        while i >= 0 && !p.fits {
            while !p.fits && p.radiusM[i] >= 0 {
                p.radiusM[i] = p.radiusM[i] > stepM ? p.radiusM[i] - stepM : (p.radiusM[i] > 0 ? 0 : -1)
                p.shrunk = true
                eval(&p, d)
            }
            i -= 1
        }
        return p
    }

    /// The largest radius (250 m steps, up to 30 km) whose whole z12-15 circle
    /// fits in `capacity` bytes at `avgBytes` a tile.
    static func maxRadiusM(lat: Double, lon: Double, capacity: UInt64, avgBytes a: UInt32) -> Double {
        let avg = UInt64(a == 0 ? defaultBytes : a)
        func total(_ r: Double) -> UInt64 {
            (zmin...zmax).reduce(UInt64(0)) { $0 + UInt64(circleCount(lat: lat, lon: lon, r: r, z: $1)) }
        }
        var best = 0.0, lo = 0.0, hi = maxRadiusM
        while hi - lo > stepM / 2 {
            let mid = floor((lo + hi) / 2 / stepM + 0.5) * stepM
            if mid <= lo || mid >= hi { break }
            if total(mid) * avg <= capacity { best = mid; lo = mid } else { hi = mid }
        }
        if total(hi) * avg <= capacity { best = hi }
        return best
    }

    /// Which tiles outside the plan to evict to free `need` bytes: highest
    /// zoom first, then farthest from the centre. Never a tile inside the
    /// plan. Returns indices into d (sorted by key, as make() sorts it).
    static func victims(_ p: Plan, _ d: [OnDisk], need: UInt64, max: Int = .max) -> (indices: [Int], freed: UInt64) {
        var out: [Int] = []
        var got: UInt64 = 0
        var pz = 1 << 30, pd = Double.infinity, pi = -1
        while got < need && out.count < max {
            var best = -1, bz = -1, bd = -1.0
            for (i, t) in d.enumerated() {
                let (z, x, y) = split(t.key)
                if p.contains(z: z, x: x, y: y) { continue }
                let dist = distM(p.lat, p.lon, latOf(Double(y) + 0.5, z), lonOf(Double(x) + 0.5, z))
                let after = z < pz || (z == pz && (dist < pd || (dist == pd && i > pi)))
                if !after { continue }
                if z > bz || (z == bz && dist > bd) { best = i; bz = z; bd = dist }
            }
            if best < 0 { break }
            out.append(best)
            got += UInt64(d[best].bytes)
            pz = bz; pd = bd; pi = best
        }
        return (out, got)
    }

    /// "Map: 3 km z12–15 · 1.1 MB of 5.0 MB" (the Mac's wording of
    /// tile_plan_describe: same groups and numbers, en dash and middle dot).
    static func describe(_ p: Plan) -> String {
        var s = "Map:"
        var i = 0
        var any = false
        while i < nz {
            var j = i
            while j + 1 < nz && p.radiusM[j + 1] == p.radiusM[i] { j += 1 }
            if p.radiusM[i] >= 0 {
                let km = p.radiusM[i] / 1000.0
                let r = abs(km - floor(km + 0.5)) < 0.05 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
                s += (any ? "," : "") + " \(r) " + (j > i ? "z\(zmin + i)–\(zmin + j)" : "z\(zmin + i)")
                any = true
            }
            i = j + 1
        }
        if !any { s += " none" }
        return s + String(format: " · %.1f MB of %.1f MB", Double(p.planBytes) / 1048576.0,
                          Double(p.capacity) / 1048576.0)
    }

    /// "/tiles/15/5241/12665.jpg" (or an older ".png") -> key; nil for
    /// anything else (the "/tiles/.src" source mark included).
    static func key(path: String) -> UInt64? {
        let parts = path.split(separator: "/")
        guard parts.count == 4, parts[0] == "tiles",
              parts[3].hasSuffix(".jpg") || parts[3].hasSuffix(".png"),
              let z = Int(parts[1]), let x = Int32(parts[2]), let y = Int32(parts[3].dropLast(4)),
              (0...22).contains(z), x >= 0, y >= 0 else { return nil }
        return key(z, x, y)
    }
    /// Where a tile goes on the board: JPEG, the basemap now (tile_path.h).
    static func path(_ z: Int, _ x: Int32, _ y: Int32) -> String { "/tiles/\(z)/\(x)/\(y).jpg" }
}
