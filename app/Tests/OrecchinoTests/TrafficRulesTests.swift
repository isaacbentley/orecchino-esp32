// TrafficRulesTests.swift — TrafficRules against every shared vector in
// tests/vectors/traffic/*.json (the same files tests/traffic_test.cpp and
// mobile/test/traffic_rules_test.dart load). Wire aircraft go through
// TrafficWire.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Orecchino

private let vectorDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("tests/vectors/traffic")

/// Banned words: "clear" only as the instruction "KEEP CLEAR OF"; "conflict"
/// only in "conflict watch" / "ADS-B conflict(s)", never "conflict resolved".
private func forbidden(_ s: String) -> Bool {
    let l = s.lowercased().replacingOccurrences(of: "keep clear of", with: "")
    return ["collision", "safe", "clear", "tcas", "conflict resolved", "no traffic"].contains { l.contains($0) }
}

private func dbl(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, !TrafficWire.isBool(v) else { return nil }
    return n.doubleValue
}

private func close(_ got: Double?, _ want: Any?, _ tol: Double) -> Bool {
    switch (got, dbl(want)) {
    case (nil, nil): return true
    case let (g?, w?): return abs(g - w) <= tol
    default: return false
    }
}

private func observer(_ v: Any?) -> TrafficObserver {
    guard let o = v as? [String: Any] else { return .unknown }
    return TrafficObserver(lat: dbl(o["lat"]), lon: dbl(o["lon"]), elevM: dbl(o["elev_m"]))
}

private func loadVectors() throws -> [(String, [String: Any])] {
    let files = try FileManager.default.contentsOfDirectory(atPath: vectorDir.path)
        .filter { $0.hasSuffix(".json") }.sorted()
    return try files.map { f in
        let data = try Data(contentsOf: vectorDir.appendingPathComponent(f))
        return (f, try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
}

@Suite struct TrafficRulesTests {
    @Test func everyVectorFile() throws {
        let vectors = try loadVectors()
        #expect(vectors.count >= 12)
        var ruleFiles = 0, steps = 0, alerts = 0, cases = 0
        for (file, v) in vectors {
            if let cs = v["cases"] as? [[String: Any]] {
                cases += try runHostLines(file, v, cs)
            } else if let st = v["steps"] as? [[String: Any]] {
                ruleFiles += 1
                let r = try runRules(file, v, st)
                steps += r.0
                alerts += r.1
            } else {
                Issue.record("\(file): unknown vector shape")
            }
        }
        #expect(ruleFiles >= 11 && steps >= 37 && alerts >= 90 && cases >= 8,
                "coverage: \(ruleFiles) rule files, \(steps) steps, \(alerts) alerts, \(cases) host cases")
    }

    private func runRules(_ file: String, _ v: [String: Any], _ steps: [[String: Any]]) throws -> (Int, Int) {
        var state = TrafficState()
        var alertsChecked = 0
        for step in steps {
            let ts = try #require(dbl(step["t_s"]))
            let ctx = "\(file) t=\(ts)"
            let now: Int64 = 1_000_000 + Int64((ts * 1000).rounded())
            let dj = (step["drones"] ?? v["drones"]) as? [[String: Any]] ?? []
            let drones = dj.map { d in
                TrafficDrone(id: d["id"] as? String ?? "", lat: dbl(d["lat"]), lon: dbl(d["lon"]),
                             altGeoM: dbl(d["alt_geo_m"]), speedMps: dbl(d["speed_mps"]),
                             headingDeg: dbl(d["heading_deg"]), live: (d["live"] as? Bool) ?? false,
                             heightM: dbl(d["height_m"]))
            }
            let obs = observer(step["observer"] ?? v["observer"])
            var aircraft: [TrafficAircraft] = []
            for w in step["aircraft"] as? [[String: Any]] ?? [] {
                let a = TrafficWire.aircraft(from: w, nowMs: now)
                #expect(a != nil, "\(ctx): aircraft \(w["hex"] ?? "") parses")
                if let a { aircraft.append(a) }
            }
            let dataMs = dbl(step["data_age_s"]).map { now - Int64(($0 * 1000).rounded()) }
            let r = TrafficRules.evaluate(drones: drones, aircraft: aircraft, observer: obs,
                                          dataMs: dataMs, nowMs: now, state: &state)
            let e = try #require(step["expect"] as? [String: Any])
            #expect(r.haveData == (e["have_data"] as? Bool), "\(ctx): have_data")
            #expect(r.stale == (e["stale"] as? Bool), "\(ctx): stale")
            #expect(r.highest.name == e["highest"] as? String, "\(ctx): highest \(r.highest.name)")
            #expect(r.aircraftCount == (e["aircraft_count"] as? Int), "\(ctx): aircraft_count")
            #expect(r.summary == e["summary"] as? String, "\(ctx): summary '\(r.summary)'")
            #expect(!forbidden(r.summary))
            let want = e["alerts"] as? [[String: Any]] ?? []
            #expect(r.alerts.count == want.count, "\(ctx): \(r.alerts.map(\.text)) want \(want.map { $0["text"] ?? "" })")
            for (i, (a, w)) in zip(r.alerts, want).enumerated() {
                let c = "\(ctx) #\(i)"
                #expect(a.level.name == w["level"] as? String, "\(c): level")
                #expect(a.kind.name == w["kind"] as? String, "\(c): kind")
                #expect(a.droneId == w["drone"] as? String, "\(c): drone")
                #expect(a.hex == w["hex"] as? String, "\(c): hex")
                #expect(a.text == w["text"] as? String, "\(c): text '\(a.text)'")
                #expect(a.held == w["held"] as? Bool, "\(c): held")
                #expect(a.heightUnknown == w["height_unknown"] as? Bool, "\(c): height_unknown")
                #expect(a.vertRel.rawValue == w["vert_rel"] as? String, "\(c): vert_rel \(a.vertRel)")
                #expect(a.approx == w["approx"] as? Bool, "\(c): approx")
                #expect(a.fromObserver == w["from_observer"] as? Bool, "\(c): from_observer")
                #expect(a.action == w["action"] as? String, "\(c): action '\(a.action)'")
                #expect(a.resolution == w["resolution"] as? String, "\(c): resolution '\(a.resolution)'")
                #expect(a.resolution.hasPrefix(a.action) && !forbidden(a.resolution))
                #expect(a.onGround == w["on_ground"] as? Bool, "\(c): on_ground")
                #expect(close(a.horizM, w["horiz_m"], 1e-6), "\(c): horiz \(String(describing: a.horizM))")
                #expect(close(a.vertM, w["vert_m"], 1e-6), "\(c): vert \(String(describing: a.vertM))")
                #expect(close(a.bearingDeg, w["bearing_deg"], 1e-6), "\(c): bearing")
                #expect(close(a.cpaS, w["cpa_s"], 1e-6), "\(c): cpa \(String(describing: a.cpaS))")
                #expect(close(a.ageS, w["age_s"], 1e-9), "\(c): age")
                #expect(!forbidden(a.text))
                if let j = a.acIndex { #expect(aircraft[j].hex == a.hex) }
                if let j = a.droneIndex { #expect(drones[j].id == a.droneId) }
                alertsChecked += 1
            }
        }
        return (steps.count, alertsChecked)
    }

    private func runHostLines(_ file: String, _ v: [String: Any], _ cases: [[String: Any]]) throws -> Int {
        let now = Int64(try #require(dbl(v["now_ms"])))
        for (k, c) in cases.enumerated() {
            let ctx = "\(file) case \(k)"
            var feed = TrafficHostFeed(observer: observer(c["observer"]))
            let e = try #require(c["expect"] as? [String: Any])
            let lines = c["lines"] as? [String] ?? []
            let handled = e["handled"] as? [Bool] ?? []
            for (i, line) in lines.enumerated() {
                let h = feed.handle(line: line, nowMs: now)
                #expect(h == handled[i], "\(ctx): line \(i) handled")
            }
            #expect(feed.haveData == e["have_data"] as? Bool, "\(ctx): have_data")
            #expect(feed.partial == e["partial"] as? Bool, "\(ctx): partial")
            #expect(feed.aircraft.count == e["count"] as? Int, "\(ctx): count \(feed.aircraft.count)")
            if feed.haveData {
                #expect(close(TrafficRules.ageS(seenMs: feed.dataMs, nowMs: now), e["data_age_s"], 1e-9), "\(ctx): data age")
            }
            let want = e["aircraft"] as? [[String: Any]] ?? []
            for (i, (a, w)) in zip(feed.aircraft, want).enumerated() {
                let cc = "\(ctx) #\(i)"
                #expect(a.hex == w["hex"] as? String, "\(cc): hex")
                #expect(a.callsign == w["callsign"] as? String, "\(cc): callsign '\(a.callsign)'")
                #expect(a.type == w["type"] as? String, "\(cc): type")
                #expect(close(a.lat, w["lat"], 1e-12) && close(a.lon, w["lon"], 1e-12), "\(cc): position")
                #expect(close(a.altGeomM, w["alt_geom_m"], 1e-9), "\(cc): alt_geom")
                #expect(close(a.altBaroM, w["alt_baro_m"], 1e-9), "\(cc): alt_baro")
                #expect(close(a.gsMps, w["gs_mps"], 1e-9), "\(cc): gs")
                #expect(close(a.trackDeg, w["track_deg"], 1e-9), "\(cc): track")
                #expect(close(a.vsMps, w["vs_mps"], 1e-9), "\(cc): vs")
                #expect(a.squawk == w["squawk"] as? Int, "\(cc): squawk")
                #expect(a.emergency == w["emergency"] as? Bool, "\(cc): emergency")
                #expect(a.onGround == w["on_ground"] as? Bool, "\(cc): on_ground")
                #expect(close(a.ageS(nowMs: now), w["age_s"], 1e-9), "\(cc): age")
            }
            // What this app would push for the same set parses back to it.
            if !feed.aircraft.isEmpty {
                var back = TrafficHostFeed(observer: observer(c["observer"]))
                for l in TrafficWire.hostLines(aircraft: feed.aircraft, nowMs: now, unixS: 1_727_000_000, dataAgeS: 2) {
                    #expect(l.utf8.count < 1600, "\(ctx): line length")
                    let ok = back.handle(line: l, nowMs: now)
                    #expect(ok)
                }
                #expect(back.aircraft.map(\.hex) == feed.aircraft.map(\.hex), "\(ctx): round trip")
                #expect(!back.partial)
                for (a, b) in zip(back.aircraft, feed.aircraft) {
                    #expect(a.squawk == b.squawk && a.emergency == b.emergency && a.callsign == b.callsign)
                    #expect(a.onGround == b.onGround)
                    #expect(abs(a.lat - b.lat) < 1e-6 && abs((a.gsMps ?? 0) - (b.gsMps ?? 0)) < 0.05)
                }
            }
        }
        return cases.count
    }

    @Test func recordedSfoAnswerWithoutDronesIsConflictWatchOnly() throws {
        // The recorded adsb.lol answer at SFO: 38 of 45 report "alt_baro":"ground".
        // With no drone there is nothing to watch: no alerts, no aircraft counts.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/adsb_lol_point_sfo.json")
        let rx: Int64 = 1_790_190_047_500
        let list = try AdsbLol.parse(try Data(contentsOf: url), receivedMs: rx)
        #expect(list.filter(\.onGround).count == 38)
        var st = TrafficState()
        let r = TrafficRules.evaluate(drones: [], aircraft: list, dataMs: rx, nowMs: rx, state: &st)
        #expect(r.alerts.isEmpty)
        #expect(r.summary == "conflict watch on, no ADS-B conflicts, data 0 s old")
        // A drone hovering over the apron next to UAL1668: ground aircraft are cautions.
        let d = TrafficDrone(id: "1581F20000D9A11", lat: 37.621377, lon: -122.3870, altGeoM: 40,
                             speedMps: 0, headingDeg: 0, live: true)
        let r2 = TrafficRules.evaluate(drones: [d], aircraft: list, dataMs: rx, nowMs: rx, state: &st)
        #expect(!r2.alerts.isEmpty)
        #expect(r2.alerts.filter(\.onGround).allSatisfy {
            $0.level == .caution && $0.action == "KEEP CLEAR OF AIRCRAFT ON GROUND" })
    }

    @Test func antimeridianDistance() {
        // The old flat-earth code measured 24,643 km here.
        let d = TrafficRules.distanceM(52.0, 179.99, 52.0, -179.99)
        #expect(d > 1300 && d < 1400)
    }

    @Test func emptySetAndNoSourceWording() {
        var st = TrafficState()
        let none = TrafficRules.evaluate(drones: [], aircraft: [], dataMs: nil, nowMs: 10_000, state: &st)
        #expect(none.summary == "CONFLICT WATCH OFF: no ADS-B source")
        let empty = TrafficRules.evaluate(drones: [], aircraft: [], dataMs: 9_000, nowMs: 10_000, state: &st)
        #expect(empty.summary == "conflict watch on, no ADS-B conflicts, data 1 s old")
    }
}
