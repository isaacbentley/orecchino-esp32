// TrafficRules.swift — ADS-B conflict watch: manned aircraft near the drones,
// with a resolution advisory for each (14 CFR 107.37(a): the drone gives way).
//
// A line-for-line port of firmware/common/traffic.h (the reference; its
// header comment holds the rules, every choice made where plan §8 left room,
// and the `traffic` host-line format). mobile/lib/core/traffic/
// traffic_rules.dart is the third port. All three load every file in
// tests/vectors/traffic/*.json; change one, change all three.
//
// Unknown values are nil here (NaN in C). Times are milliseconds on one
// clock (Int64); use TrafficRules.nowMs() for wall-clock milliseconds.
// Words: never "collision", "safe", "clear" (other than the instruction
// "KEEP CLEAR OF"), "conflict resolved" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreLocation

public enum TrafficLevel: Int, Comparable, Sendable, CaseIterable {
    case none = 0, caution = 2, warning = 3          // (1 was the removed advisory)
    public static func < (a: TrafficLevel, b: TrafficLevel) -> Bool { a.rawValue < b.rawValue }
    public var name: String {
        switch self {
        case .none: return "none"
        case .caution: return "caution"
        case .warning: return "warning"
        }
    }
}

/// Drone-aircraft pairs, and LOW: an airborne aircraft in UAS airspace (one
/// per aircraft). No emergency-squawk rule.
public enum TrafficKind: Int, Sendable, CaseIterable {
    case near = 0, converging = 1, low = 2
    public var name: String { self == .near ? "near" : self == .converging ? "converging" : "low" }
    public var level: TrafficLevel { self == .low ? .caution : .warning }
    public var isPair: Bool { self != .low }
    /// A pair with an aircraft on the ground is a caution, not a warning; LOW is a caution.
    public func level(onGround: Bool) -> TrafficLevel { self == .low || onGround ? .caution : .warning }
}

/// Where the aircraft is relative to the drone (current vertical; level =
/// within 30 m).
public enum TrafficVertical: String, Sendable, CaseIterable {
    case unknown, above, level, below
}

/// One aircraft as reported by ADS-B. `squawk` is the four octal digits read
/// as a decimal number (7700), 0 when unknown.
public struct TrafficAircraft: Sendable, Identifiable, Equatable {
    public var id: String { hex }
    public var hex: String            // ICAO address, lower-case hex
    public var callsign: String
    public var type: String
    public var lat: Double
    public var lon: Double
    public var altGeomM: Double?      // geometric, WGS-84 ellipsoid
    public var altBaroM: Double?      // pressure altitude (shown, never compared with drones)
    public var gsMps: Double?
    public var trackDeg: Double?
    public var vsMps: Double?
    public var squawk: Int
    public var emergency: Bool
    public var onGround: Bool         // reported on the ground (taxiing, parked)
    public var seenMs: Int64          // when the position was reported

    public init(hex: String, callsign: String = "", type: String = "", lat: Double, lon: Double,
                altGeomM: Double? = nil, altBaroM: Double? = nil, gsMps: Double? = nil,
                trackDeg: Double? = nil, vsMps: Double? = nil, squawk: Int = 0,
                emergency: Bool = false, onGround: Bool = false, seenMs: Int64) {
        self.hex = hex; self.callsign = callsign; self.type = type; self.lat = lat; self.lon = lon
        self.altGeomM = altGeomM; self.altBaroM = altBaroM; self.gsMps = gsMps; self.trackDeg = trackDeg
        self.vsMps = vsMps; self.squawk = squawk; self.emergency = emergency; self.onGround = onGround
        self.seenMs = seenMs
    }

    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    /// Callsign, else the hex in capitals.
    public var name: String { callsign.isEmpty ? hex.uppercased() : callsign }
    public func ageS(nowMs: Int64) -> Double { TrafficRules.ageS(seenMs: seenMs, nowMs: nowMs) }
}

public struct TrafficDrone: Sendable, Equatable {
    public var id: String             // stable id (UAS id, else MAC); the words use its last 5
    public var lat: Double?
    public var lon: Double?
    public var altGeoM: Double?       // ODID geodetic altitude (WGS-84)
    public var speedMps: Double?
    public var headingDeg: Double?
    public var live: Bool             // heard within 60 s with a position
    public var heightM: Double?       // height above take-off/ground (LOW's ground)

    public init(id: String, lat: Double?, lon: Double?, altGeoM: Double? = nil,
                speedMps: Double? = nil, headingDeg: Double? = nil, live: Bool, heightM: Double? = nil) {
        self.id = id; self.lat = lat; self.lon = lon; self.altGeoM = altGeoM
        self.speedMps = speedMps; self.headingDeg = headingDeg; self.live = live; self.heightM = heightM
    }
}

public struct TrafficObserver: Sendable, Equatable {
    public var lat: Double?
    public var lon: Double?
    public var elevM: Double?         // ellipsoid height preferred; MSL acceptable
    public init(lat: Double?, lon: Double?, elevM: Double?) { self.lat = lat; self.lon = lon; self.elevM = elevM }
    public static let unknown = TrafficObserver(lat: nil, lon: nil, elevM: nil)
}

public struct TrafficAlert: Sendable, Identifiable, Equatable {
    public var id: String { "\(kind.name)|\(droneId)|\(hex)" }
    public var level: TrafficLevel
    public var kind: TrafficKind
    public var held: Bool             // kept by hysteresis; the raise condition is false now
    public var heightUnknown: Bool
    public var onGround: Bool = false // the aircraft is reported on the ground
    public var droneIndex: Int?       // into this evaluation's drones
    public var acIndex: Int?          // into this evaluation's aircraft (nil: gone)
    public var droneId: String
    public var hex: String
    public var callsign: String
    public var horizM: Double?        // drone to aircraft (always set for a pair)
    public var vertM: Double?         // aircraft minus drone
    public var bearingDeg: Double?    // from the drone to the aircraft (always set)
    public var cpaS: Double?
    public var cpaM: Double?
    public var ageS: Double           // aircraft position age
    public var text: String           // "TRAFFIC NEAR DRONE D9A03"
    public var vertRel: TrafficVertical = .unknown
    public var action: String = ""        // "GIVE WAY: DESCEND AND LAND D9A03"
    public var resolution: String = ""    // action + "; " + the geometry
    /// True above, false level or below, nil unknown.
    public var aircraftAbove: Bool? { vertRel == .unknown ? nil : vertRel == .above }
    public var approx: Bool = false       // LOW: barometric aircraft height used
    public var fromObserver: Bool = false // LOW: horizM/bearingDeg from the observer (droneId "")
}

/// Caller-owned hysteresis memory.
public struct TrafficState: Sendable {
    struct Entry: Sendable {
        var a: TrafficAlert
        var seenMs: Int64
        var outSinceMs: Int64 = 0
        var out = false
        var visited = false
    }
    var entries: [Entry] = []
    public init() {}
}

public struct TrafficResult: Sendable, Equatable {
    public var alerts: [TrafficAlert] = []
    public var haveData = false
    public var stale = false
    public var dataAgeS: Double? = nil
    public var aircraftCount = 0      // aircraft present (<= 60 s); never shown as a count of threats
    public var highest: TrafficLevel { alerts.first?.level ?? .none }
    public var summary: String { TrafficRules.summary(self) }
    public func alert(forHex hex: String) -> TrafficAlert? { alerts.first { $0.hex == hex } }
    public static let empty = TrafficResult()
}

public enum TrafficRules {
    public static let maxAircraft = 32
    public static let maxAlerts = 16
    public static let freshS = 30.0, presentS = 60.0, staleS = 30.0
    public static let nearHM = 1000.0, nearVM = 150.0
    public static let cpaMaxS = 60.0, cpaMissM = 500.0
    public static let holdHM = 1300.0, holdVM = 200.0
    public static let clearMs: Int64 = 20000
    public static let levelBandM = 30.0, keepRM = 30000.0
    public static let lowRM = 3000.0, lowAglM = 460.0
    /// LOW with the ground unknown: only aircraft below 3,500 m MSL (see traffic.h).
    public static let lowUnknownGroundMaxM = 3500.0
    public static let earthRM = 6371000.0
    public static let deg = Double.pi / 180.0
    public static let ftToM = 0.3048
    public static let ktToMps = 1852.0 / 3600.0

    public static func nowMs(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func known(_ v: Double?) -> Bool { v.map { $0.isFinite } ?? false }
    static func altKnown(_ v: Double?) -> Bool { v.map { $0.isFinite && $0 > -999.0 } ?? false }

    public static func ageS(seenMs: Int64, nowMs: Int64) -> Double { Double(max(nowMs - seenMs, 0)) / 1000.0 }

    /// East/north metres from point 1 to point 2 (flat earth, longitude wrapped).
    public static func offsetM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> (dx: Double, dy: Double) {
        var dlon = lon2 - lon1
        if dlon > 180.0 { dlon -= 360.0 } else if dlon < -180.0 { dlon += 360.0 }
        let mlat = (lat1 + lat2) * 0.5 * deg
        return (dlon * deg * cos(mlat) * earthRM, (lat2 - lat1) * deg * earthRM)
    }

    public static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let o = offsetM(lat1, lon1, lat2, lon2)
        return (o.dx * o.dx + o.dy * o.dy).squareRoot()
    }

    public static func bearing(dx: Double, dy: Double) -> Double {
        var b = atan2(dx, dy) / deg
        if b < 0.0 { b += 360.0 }
        if b >= 360.0 { b -= 360.0 }
        return b
    }

    public static func compass8(_ d: Double) -> String {
        var i = Int(floor((d + 22.5) / 45.0)) % 8
        if i < 0 { i += 8 }
        return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][i]
    }

    /// A readable tail of a drone id (traffic_drone_label): "uas:"/"mac:"
    /// dropped; a MAC reads "MAC 4C:C5:A2" (its last three bytes); else the id
    /// when <= 8 characters, else its last 5 grown past leading punctuation
    /// ("1581F20000D9A03" -> "D9A03", "DRONE-B-9A01" -> "B-9A01").
    public static func droneLabel(_ raw: String) -> String {
        var id = Array(raw.utf8)
        if id.count >= 4, [UInt8]("uas:".utf8) == Array(id[0..<4]) || [UInt8]("mac:".utf8) == Array(id[0..<4]) {
            id.removeFirst(4)
        }
        func hex(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...102).contains(c) || (65...70).contains(c) }
        func alnum(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...122).contains(c) || (65...90).contains(c) }
        func up(_ c: UInt8) -> UInt8 { (97...122).contains(c) ? c - 32 : c }
        var b: (Int, Int)? = nil                  // offset of the last three bytes, step
        if id.count == 12, id.allSatisfy(hex) { b = (6, 2) }
        else if id.count == 17, id.indices.allSatisfy({ i in
            i % 3 == 2 ? (id[i] == 58 || id[i] == 45) && id[i] == id[2] : hex(id[i]) }) { b = (9, 3) }
        if let (o, s) = b {
            let d = [id[o], id[o + 1], 58, id[o + s], id[o + s + 1], 58, id[o + 2 * s], id[o + 2 * s + 1]].map(up)
            return "MAC " + String(decoding: d, as: UTF8.self)
        }
        if id.count <= 8 { return String(decoding: id, as: UTF8.self) }
        var tail = 5
        while tail < id.count && !alnum(id[id.count - tail]) { tail += 1 }
        return String(decoding: id[(id.count - tail)...], as: UTF8.self)
    }

    /// "ADS-B 6 s old"
    public static func ageWords(_ ageS: Double) -> String { "ADS-B \(Int(floor(ageS + 0.5))) s old" }

    public static func kmText(_ m: Double) -> String {
        let t = Int(floor(m / 100.0 + 0.5))
        return "\(t / 10).\(t % 10)"
    }

    static func cmp(_ a: TrafficAlert, _ b: TrafficAlert) -> Int {
        if a.level != b.level { return a.level > b.level ? -1 : 1 }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue ? -1 : 1 }
        let ah = a.horizM ?? .nan, bh = b.horizM ?? .nan
        if ah.isNaN != bh.isNaN { return ah.isNaN ? 1 : -1 }
        if !ah.isNaN && ah != bh { return ah < bh ? -1 : 1 }
        if a.droneId != b.droneId { return Array(a.droneId.utf8).lexicographicallyPrecedes(Array(b.droneId.utf8)) ? -1 : 1 }
        if a.hex != b.hex { return Array(a.hex.utf8).lexicographicallyPrecedes(Array(b.hex.utf8)) ? -1 : 1 }
        return 0
    }

    /// The aircraft above / level / below the drone, from the current vertical.
    static func vertRel(_ v: Double?) -> TrafficVertical {
        guard let v, !v.isNaN else { return .unknown }
        if v > levelBandM { return .above }
        if v < -levelBandM { return .below }
        return .level
    }

    /// The words, the action and the resolution for a pair (traffic_pair_words).
    static func pairWords(_ a: inout TrafficAlert, _ kind: TrafficKind) {
        let id = droneLabel(a.droneId)
        let hu = a.onGround ? ", AIRCRAFT ON GROUND" : a.heightUnknown ? ", HEIGHT UNKNOWN" : ""
        if kind == .near { a.text = "TRAFFIC NEAR DRONE \(id)\(hu)" }
        else if let t = a.cpaS { a.text = "TRAFFIC CONVERGING WITH \(id), \(Int(floor(t + 0.5))) S\(hu)" }
        else { a.text = "TRAFFIC CONVERGING WITH \(id)\(hu)" }

        a.vertRel = vertRel(a.vertM)
        let brg = a.bearingDeg ?? 0
        if a.onGround { a.action = "KEEP CLEAR OF AIRCRAFT ON GROUND" }
        else if a.vertRel == .below {
            a.action = "GIVE WAY: MOVE \(compass8(fmod(brg + 180.0, 360.0))), THEN LAND \(id)"
        } else { a.action = "GIVE WAY: DESCEND AND LAND \(id)" }

        let v = a.vertM.map { Int(floor(abs($0) + 0.5)) } ?? 0
        let vert: String
        if a.onGround { vert = "AIRCRAFT ON GROUND" }
        else {
            switch a.vertRel {
            case .above: vert = "AIRCRAFT \(v) M ABOVE"
            case .below: vert = "AIRCRAFT \(v) M BELOW"
            case .level: vert = "AIRCRAFT LEVEL WITHIN 30 M"
            case .unknown: vert = "AIRCRAFT HEIGHT UNKNOWN"
            }
        }
        let h = a.horizM ?? 0
        let hz = h < 1000.0 ? "\(Int(floor(h / 10.0 + 0.5)) * 10) M" : "\(kmText(h)) KM"
        let cpa = a.cpaS.map { ", CLOSEST IN \(Int(floor($0 + 0.5))) S" } ?? ""
        a.resolution = "\(a.action); \(vert), \(hz) \(compass8(brg))\(cpa)"
    }

    /// "800 M" to the nearest 10 m under 1 km, else "2.4 KM".
    static func distText(_ m: Double) -> String {
        m < 1000.0 ? "\(Int(floor(m / 10.0 + 0.5)) * 10) M" : "\(kmText(m)) KM"
    }

    /// LOW's words from its numbers (traffic_low_words).
    static func lowWords(_ a: inout TrafficAlert) {
        let dist = distText(a.horizM ?? 0)
        let brg = compass8(a.bearingDeg ?? 0)
        a.text = "LOW TRAFFIC \(brg) \(dist)" + (a.onGround ? ", AIRCRAFT ON GROUND"
            : a.heightUnknown ? ", HEIGHT UNKNOWN" : (a.approx ? ", APPROX." : ""))
        a.vertRel = a.vertM == nil ? .unknown : .above
        a.action = "BE READY TO LAND DRONES"
        let v = a.vertM.map { Int(floor($0 + 0.5)) } ?? 0
        let ab = a.approx ? "ABOUT " : ""
        let vert: String
        if a.onGround { vert = "AIRCRAFT ON GROUND" }
        else if a.heightUnknown { vert = "AIRCRAFT HEIGHT UNKNOWN" }
        else if v <= 0 { vert = "AIRCRAFT NEAR GROUND LEVEL" }   // "near" is the approximation
        else { vert = "AIRCRAFT \(ab)\(v) M ABOVE GROUND" }
        a.resolution = "\(a.action); \(vert), \(dist) \(brg)"
    }

    /// Raise or refresh an alert (mirrors traffic_apply): a pair keyed by
    /// drone and aircraft, LOW by the aircraft alone.
    static func apply(_ s: inout TrafficState, _ cand: TrafficAlert, raw: Bool, hold: Bool,
                      seenMs: Int64, nowMs: Int64) {
        let low = cand.kind == .low
        let idx = s.entries.firstIndex {
            $0.a.hex == cand.hex && (low ? $0.a.kind == .low : ($0.a.kind != .low && $0.a.droneId == cand.droneId))
        }
        var kind = cand.kind
        var i: Int
        if let found = idx {
            i = found
            let old = s.entries[i].a.kind
            if low { kind = .low } else if !raw { kind = old } else if old == .near && hold { kind = .near }
        } else {
            if !raw { return }
            let fresh = TrafficState.Entry(a: cand, seenMs: seenMs)
            if s.entries.count < maxAlerts {
                s.entries.append(fresh)
                i = s.entries.count - 1
            } else {
                var worst = 0
                for k in 1..<s.entries.count where cmp(s.entries[k].a, s.entries[worst].a) > 0 { worst = k }
                guard cmp(cand, s.entries[worst].a) < 0 else { return }
                s.entries[worst] = fresh
                i = worst
            }
        }
        var a = cand
        a.kind = kind
        a.level = kind.level(onGround: a.onGround)
        a.held = !raw
        if low { lowWords(&a) } else { pairWords(&a, kind) }
        s.entries[i].a = a
        s.entries[i].visited = true
        s.entries[i].seenMs = seenMs
        if raw || hold {
            s.entries[i].out = false
        } else if !s.entries[i].out {
            s.entries[i].out = true
            s.entries[i].outSinceMs = nowMs
        }
    }

    /// The rule function (traffic_evaluate). dataMs nil: no ADS-B source.
    /// `observer` only feeds LOW.
    public static func evaluate(drones: [TrafficDrone], aircraft ac: [TrafficAircraft],
                                observer obs: TrafficObserver = .unknown,
                                dataMs: Int64?, nowMs: Int64, state st: inout TrafficState) -> TrafficResult {
        var out = TrafficResult()
        out.haveData = dataMs != nil
        let dataAge: Double = dataMs.map { ageS(seenMs: $0, nowMs: nowMs) } ?? .nan
        out.dataAgeS = dataMs == nil ? nil : dataAge
        out.stale = out.haveData && !(dataAge <= staleS)
        let canRaise = out.haveData && !out.stale

        for k in st.entries.indices { st.entries[k].visited = false }

        func present(_ a: TrafficAircraft) -> Bool {
            ageS(seenMs: a.seenMs, nowMs: nowMs) <= presentS && a.lat.isFinite && a.lon.isFinite
        }
        out.aircraftCount = ac.filter(present).count

        for (i, d) in drones.enumerated() {
            guard let dlat = d.lat, let dlon = d.lon, dlat.isFinite, dlon.isFinite else { continue }
            for (j, a) in ac.enumerated() {
                guard present(a) else { continue }
                let age = ageS(seenMs: a.seenMs, nowMs: nowMs)
                let o = offsetM(dlat, dlon, a.lat, a.lon)
                let horiz = (o.dx * o.dx + o.dy * o.dy).squareRoot()
                let vert: Double = (altKnown(a.altGeomM) && altKnown(d.altGeoM)) ? a.altGeomM! - d.altGeoM! : .nan
                var cpaS = Double.nan, cpaM = Double.nan
                var vcpa = vert
                if !a.onGround, let gs = a.gsMps, gs.isFinite, gs >= 0, let trk = a.trackDeg, trk.isFinite,
                   let sp = d.speedMps, sp.isFinite, sp >= 0, let hd = d.headingDeg, hd.isFinite {
                    let avx = gs * sin(trk * deg), avy = gs * cos(trk * deg)
                    let dvx = sp * sin(hd * deg), dvy = sp * cos(hd * deg)
                    let wx = avx - dvx, wy = avy - dvy
                    let ww = wx * wx + wy * wy
                    if ww > 1e-9 {
                        let t = -(o.dx * wx + o.dy * wy) / ww
                        if t > 0.0 && t <= cpaMaxS {
                            let mx = o.dx + wx * t, my = o.dy + wy * t
                            cpaS = t
                            cpaM = (mx * mx + my * my).squareRoot()
                            if !vcpa.isNaN, let vs = a.vsMps, vs.isFinite { vcpa = vcpa + vs * t }
                        }
                    }
                }
                let eligible = canRaise && d.live && age < freshS
                let nearRaw = eligible && horiz <= nearHM && (vert.isNaN || abs(vert) <= nearVM)
                let convRaw = eligible && !cpaS.isNaN && cpaM < cpaMissM && (vcpa.isNaN || abs(vcpa) <= nearVM)
                let hold = horiz <= holdHM && (vert.isNaN || abs(vert) <= holdVM)
                let kind: TrafficKind = nearRaw ? .near : .converging
                let c = TrafficAlert(level: kind.level(onGround: a.onGround), kind: kind, held: false,
                                     heightUnknown: vert.isNaN, onGround: a.onGround,
                                     droneIndex: i, acIndex: j,
                                     droneId: d.id, hex: a.hex, callsign: a.callsign, horizM: horiz,
                                     vertM: vert.isNaN ? nil : vert, bearingDeg: bearing(dx: o.dx, dy: o.dy),
                                     cpaS: cpaS.isNaN ? nil : cpaS, cpaM: cpaM.isNaN ? nil : cpaM,
                                     ageS: age, text: "")
                apply(&st, c, raw: nearRaw || convRaw, hold: hold, seenMs: a.seenMs, nowMs: nowMs)
            }
        }

        // LOW: airborne aircraft in UAS airspace.
        let obsPos = known(obs.lat) && known(obs.lon)
        var ground = Double.nan
        if altKnown(obs.elevM) {
            ground = obs.elevM!
        } else {
            var lowest = Double.nan
            for d in drones {
                guard d.live, let la = d.lat, let lo = d.lon, la.isFinite, lo.isFinite else { continue }
                guard altKnown(d.altGeoM), let h = d.heightM, h.isFinite else { continue }
                if lowest.isNaN || d.altGeoM! < lowest { lowest = d.altGeoM!; ground = d.altGeoM! - h }
            }
        }
        for (j, a) in ac.enumerated() {
            guard present(a) else { continue }
            let age = ageS(seenMs: a.seenMs, nowMs: nowMs)
            var dx = Double.nan, dy = Double.nan, dist = Double.nan
            var anchor: Int? = nil
            var fromObs = false, within = false
            if obsPos {
                let o = offsetM(obs.lat!, obs.lon!, a.lat, a.lon)
                dx = o.dx; dy = o.dy; dist = (dx * dx + dy * dy).squareRoot()
                fromObs = true
                within = dist <= lowRM
            }
            if !within {
                var bi: Int? = nil
                var bd = Double.nan, bx = 0.0, by = 0.0
                for (i, d) in drones.enumerated() {
                    guard d.live, let la = d.lat, let lo = d.lon, la.isFinite, lo.isFinite else { continue }
                    let o = offsetM(la, lo, a.lat, a.lon)
                    let h = (o.dx * o.dx + o.dy * o.dy).squareRoot()
                    if bi == nil || h < bd { bi = i; bd = h; bx = o.dx; by = o.dy }
                }
                if let bi, bd <= lowRM || !fromObs {
                    anchor = bi; dist = bd; dx = bx; dy = by; fromObs = false
                    within = bd <= lowRM
                }
            }
            if !fromObs && anchor == nil { continue }
            var h = Double.nan
            var approx = false
            if altKnown(a.altGeomM) { h = a.altGeomM! } else if altKnown(a.altBaroM) { h = a.altBaroM!; approx = true }
            let vert: Double = (!h.isNaN && !ground.isNaN) ? h - ground : .nan
            if vert.isNaN { approx = false }
            var c = TrafficAlert(level: .caution, kind: .low, held: false, heightUnknown: vert.isNaN,
                                 onGround: a.onGround, droneIndex: anchor, acIndex: j,
                                 droneId: anchor.map { drones[$0].id } ?? "", hex: a.hex, callsign: a.callsign,
                                 horizM: dist, vertM: vert.isNaN ? nil : vert, bearingDeg: bearing(dx: dx, dy: dy),
                                 cpaS: nil, cpaM: nil, ageS: age, text: "")
            c.approx = approx
            c.fromObserver = fromObs
            let low = !vert.isNaN ? vert < lowAglM : (h.isNaN || !ground.isNaN || h < lowUnknownGroundMaxM)
            let cond = !a.onGround && within && low
            apply(&st, c, raw: canRaise && age < freshS && cond, hold: cond, seenMs: a.seenMs, nowMs: nowMs)
        }

        // Entries not seen are out of hold; expire after 20 s out.
        var kept: [TrafficState.Entry] = []
        for var e in st.entries {
            if !e.visited {
                e.a.held = true
                if !e.out { e.out = true; e.outSinceMs = nowMs }
            }
            if e.out && nowMs - e.outSinceMs >= clearMs { continue }
            kept.append(e)
            var o = e.a
            o.ageS = ageS(seenMs: e.seenMs, nowMs: nowMs)
            o.droneIndex = o.droneId.isEmpty ? nil : drones.firstIndex { $0.id == o.droneId }
            o.acIndex = ac.firstIndex { $0.hex == o.hex && ageS(seenMs: $0.seenMs, nowMs: nowMs) <= presentS }
            out.alerts.append(o)
        }
        st.entries = kept
        // A warning for an aircraft supersedes its LOW (kept, not shown).
        let warned = Set(out.alerts.filter { $0.kind != .low && $0.level == .warning }.map(\.hex))
        out.alerts.removeAll { $0.kind == .low && warned.contains($0.hex) }
        out.alerts.sort { cmp($0, $1) < 0 }
        return out
    }

    /// The conflict watch status, the one status line for every surface; it
    /// never counts aircraft and never claims the airspace is empty.
    public static func summary(_ r: TrafficResult) -> String {
        guard r.haveData else { return "CONFLICT WATCH OFF: no ADS-B source" }
        guard let age = r.dataAgeS else { return "TRAFFIC DATA STALE, data age unknown" }
        let a = Int(floor(age + 0.5))
        if r.stale { return "TRAFFIC DATA STALE, data \(a) s old" }
        let n = r.alerts.count
        if n == 0 { return "conflict watch on, no ADS-B conflicts, data \(a) s old" }
        let low = r.alerts.filter { $0.kind == .low }.count, conf = n - low
        let l = low > 0 ? "\(low) low aircraft, " : ""
        let c = conf > 0 ? "\(conf) ADS-B conflict\(conf == 1 ? "" : "s"), " : ""
        return "conflict watch on, \(l)\(c)data \(a) s old"
    }
}

// MARK: - The `traffic` host lines (format: firmware/common/traffic.h)

public enum TrafficWire {
    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A number (bools as 1/0) or NaN, like the firmware's reader.
    static func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return isBool(v) ? (n.boolValue ? 1 : 0) : n.doubleValue }
        return .nan
    }

    static func trimmed(_ s: String, _ max: Int) -> String {
        var t = Substring(s)
        while t.first == " " { t = t.dropFirst() }
        t = t.prefix(max)
        while t.last == " " { t = t.dropLast() }
        return String(t)
    }

    static func opt(_ d: Double) -> Double? { d.isNaN ? nil : d }

    /// One wire aircraft object; nil when unusable (no hex, no position, no
    /// finite age, older than 60 s). Mirrors traffic_parse_aircraft.
    public static func aircraft(from w: [String: Any], nowMs: Int64) -> TrafficAircraft? {
        var hex = ""
        if let s = w["hex"] as? String {
            for ch in s {
                if hex.count >= 6 { break }
                var c = ch
                if ("A"..."F").contains(c) { c = Character(c.lowercased()) }
                if c.isASCII && (c.isNumber || ("a"..."f").contains(c)) { hex.append(c) }
                else if c == "~" { continue }
                else { hex = ""; break }
            }
        }
        var lat = num(w["lat"]); if !(lat.isFinite && abs(lat) <= 90) { lat = .nan }
        var lon = num(w["lon"]); if !(lon.isFinite && abs(lon) <= 180) { lon = .nan }
        let gs = num(w["gs_kt"])
        var sq = 0
        if let s = w["sq"] as? String {
            if (1...4).contains(s.count) && s.allSatisfy({ ("0"..."7").contains($0) }) { sq = Int(s) ?? 0 }
        } else if w["sq"] is NSNumber && !isBool(w["sq"]) {
            let n = num(w["sq"])
            if n.isFinite && n >= 0 && n <= 7777 { sq = Int(n) }
        }
        var em = false
        if let s = w["em"] as? String { em = !s.isEmpty && s != "none" && s != "0" }
        else { let n = num(w["em"]); em = n.isFinite && n != 0 }
        var gnd = (w["altb_ft"] as? String) == "ground"
        if let s = w["gnd"] as? String { gnd = !s.isEmpty && s != "0" && s != "false" }
        else if w["gnd"] != nil { let n = num(w["gnd"]); gnd = n.isFinite && n != 0 }
        let age = num(w["age_s"])
        guard !hex.isEmpty, !lat.isNaN, !lon.isNaN, age >= 0, age <= TrafficRules.presentS else { return nil }
        return TrafficAircraft(
            hex: hex, callsign: trimmed(w["cs"] as? String ?? "", 8), type: trimmed(w["ty"] as? String ?? "", 4),
            lat: lat, lon: lon, altGeomM: opt(num(w["altg_m"])), altBaroM: opt(num(w["altb_ft"]) * TrafficRules.ftToM),
            gsMps: gs >= 0 ? gs * TrafficRules.ktToMps : nil, trackDeg: opt(num(w["trk"])),
            vsMps: opt(num(w["vr_fpm"]) * TrafficRules.ftToM / 60.0), squawk: sq, emergency: em,
            onGround: gnd, seenMs: nowMs - Int64((age * 1000).rounded()))
    }

    /// The wire object for one aircraft (the inverse of `aircraft(from:)`).
    public static func object(_ a: TrafficAircraft, nowMs: Int64) -> String {
        var f = ["\"hex\":\"\(a.hex)\""]
        func str(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") }
        if !a.callsign.isEmpty { f.append("\"cs\":\"\(str(a.callsign))\"") }
        if !a.type.isEmpty { f.append("\"ty\":\"\(str(a.type))\"") }
        f.append(String(format: "\"lat\":%.6f,\"lon\":%.6f", a.lat, a.lon))
        if let v = a.altGeomM, v.isFinite { f.append(String(format: "\"altg_m\":%.1f", v)) }
        if let v = a.altBaroM, v.isFinite { f.append(String(format: "\"altb_ft\":%.0f", v / TrafficRules.ftToM)) }
        if let v = a.gsMps, v.isFinite { f.append(String(format: "\"gs_kt\":%.1f", v / TrafficRules.ktToMps)) }
        if let v = a.trackDeg, v.isFinite { f.append(String(format: "\"trk\":%.1f", v)) }
        if let v = a.vsMps, v.isFinite { f.append(String(format: "\"vr_fpm\":%.0f", v * 60.0 / TrafficRules.ftToM)) }
        if a.squawk > 0 { f.append(String(format: "\"sq\":\"%04d\"", a.squawk)) }
        if a.emergency { f.append("\"em\":1") }
        if a.onGround { f.append("\"gnd\":1") }
        f.append(String(format: "\"age_s\":%.1f", a.ageS(nowMs: nowMs)))
        return "{" + f.joined(separator: ",") + "}"
    }

    /// The lines to push to a receiver every 10 s while there is data
    /// (nearest first, at most 6 aircraft per line, then traffic_done; an
    /// empty set is just traffic_done). dataAgeS: how old the set is.
    public static func hostLines(aircraft: [TrafficAircraft], nowMs: Int64, unixS: Int64, dataAgeS: Double) -> [String] {
        var lines: [String] = []
        let age = String(format: "%.1f", max(0, dataAgeS))
        var i = 0
        while i < aircraft.count {
            let chunk = aircraft[i..<min(i + 6, aircraft.count)].map { object($0, nowMs: nowMs) }
            lines.append("{\"cmd\":\"traffic\",\"t\":\(unixS),\"age_s\":\(age),\"ac\":[\(chunk.joined(separator: ","))]}")
            i += 6
        }
        lines.append("{\"cmd\":\"traffic_done\",\"n\":\(aircraft.count),\"age_s\":\(age)}")
        return lines
    }
}

/// A receiver's side of the host lines (mirrors traffic_host_line /
/// traffic_ingest); used by the tests to pin the format in Swift too.
public struct TrafficHostFeed {
    public var observer: TrafficObserver
    public private(set) var aircraft: [TrafficAircraft] = []
    public private(set) var haveData = false
    public private(set) var dataMs: Int64 = 0
    public private(set) var partial = false
    var open = false, t: Int64 = 0, stage: [TrafficAircraft] = [], rx = 0, stageAge = 0.0

    public init(observer: TrafficObserver) { self.observer = observer }

    mutating func ingest(_ list: [TrafficAircraft], dataMs: Int64, nowMs: Int64) {
        let pos = TrafficRules.known(observer.lat) && TrafficRules.known(observer.lon)
        var cand: [(d: Double, i: Int, a: TrafficAircraft)] = []
        for (i, a) in list.enumerated() {
            guard a.ageS(nowMs: nowMs) <= TrafficRules.presentS, a.lat.isFinite, a.lon.isFinite else { continue }
            let d = pos ? TrafficRules.distanceM(observer.lat!, observer.lon!, a.lat, a.lon) : 0.0
            if pos && d > TrafficRules.keepRM { continue }
            cand.append((d, i, a))
        }
        cand.sort { $0.d != $1.d ? $0.d < $1.d : $0.i < $1.i }
        aircraft = cand.prefix(TrafficRules.maxAircraft).map { $0.a }
        haveData = true
        self.dataMs = dataMs
    }

    public mutating func handle(line: String, nowMs: Int64) -> Bool {
        guard line.contains("\"traffic") else { return false }
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return line.contains("\"cmd\":\"traffic\"") || line.contains("\"cmd\":\"traffic_done\"")
        }
        let cmd = o["cmd"] as? String
        if cmd == "traffic" {
            let tv = TrafficWire.num(o["t"])
            let tt: Int64 = (tv.isFinite && tv > 0 && tv < 4294967295.0) ? Int64(tv) : 0
            if !open || tt != t { open = true; t = tt; stage = []; rx = 0; stageAge = 0 }
            if o.keys.contains("age_s") { stageAge = TrafficWire.num(o["age_s"]) }
            if let list = o["ac"] as? [Any] {
                for item in list {
                    guard let w = item as? [String: Any] else { break }
                    rx += 1
                    if let a = TrafficWire.aircraft(from: w, nowMs: nowMs), stage.count < TrafficRules.maxAircraft {
                        stage.append(a)
                    }
                }
            }
            return true
        }
        if cmd == "traffic_done" {
            var age = o.keys.contains("age_s") ? TrafficWire.num(o["age_s"]) : (open ? stageAge : 0.0)
            let list = open ? stage : []
            let received = open ? rx : 0
            let n = TrafficWire.num(o["n"])
            partial = o.keys.contains("n") && n.isFinite && Int(n) != received
            if !(age >= 0.0) { age = TrafficRules.staleS + 1.0 }
            if age > 86400.0 { age = 86400.0 }
            ingest(list, dataMs: nowMs - Int64((age * 1000).rounded()), nowMs: nowMs)
            open = false
            stage = []
            return true
        }
        return false
    }
}
