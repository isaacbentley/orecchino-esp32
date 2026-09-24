// TrafficServiceTests.swift — the Mac's ADS-B source and its surfaces (plan
// §8.1, §8.5): parsing a recorded adsb.lol answer, back-off, staleness, the
// receiver push and its gating, notifications' rate limit and words, TFR
// outlines, the match-log sync, and the sidebar selection.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreLocation
import Testing
@testable import Orecchino

private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/adsb_lol_point_sfo.json")
/// Where the fixture was recorded from (api.adsb.lol/v2/point/37.62/-122.38/8).
private let sfo = CLLocationCoordinate2D(latitude: 37.62, longitude: -122.38)
/// The default conflict-watch circle there: 10 km (asked for as 6 NM).
private let sfoArea = AdsbArea(lat: 37.62, lon: -122.38, radiusM: 10_000)

private func fixture() throws -> Data { try Data(contentsOf: fixtureURL) }

/// "clear" only as the instruction "KEEP CLEAR OF"; "conflict" only in
/// "conflict watch" / "ADS-B conflict(s)", never "conflict resolved".
private func forbidden(_ s: String) -> Bool {
    let l = s.lowercased().replacingOccurrences(of: "keep clear of", with: "")
    return ["collision", "conflict resolved", "safe", "clear", "tcas", "no traffic"].contains { l.contains($0) }
}

final class FakeClock: @unchecked Sendable {
    var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
}

final class FakeFetcher: AdsbFetching, @unchecked Sendable {
    var answer: Result<Data, Error>
    var urls: [URL] = []
    init(_ answer: Result<Data, Error>) { self.answer = answer }
    func data(from url: URL) async throws -> Data {
        urls.append(url)
        return try answer.get()
    }
}

@Suite struct AdsbLolParseTests {
    @Test func recordedAnswer() throws {
        let rx: Int64 = 1_790_190_047_500
        let list = try AdsbLol.parse(try fixture(), receivedMs: rx)
        let raw = try #require(JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        let n = (raw["ac"] as? [Any])?.count ?? 0
        #expect(n == 45)
        #expect(list.count == 45)                       // every entry has hex, position, age <= 60 s

        // An airborne one: every field mapped, units converted, age from receive time.
        let swa = try #require(list.first { $0.hex == "abdc56" })
        #expect(swa.callsign == "SWA1435" && swa.type == "B738")   // callsign trimmed
        #expect(swa.lat == 37.640371 && swa.lon == -122.421908)
        #expect(abs((swa.altGeomM ?? 0) - 1575 * 0.3048) < 0.01)   // alt_geom ft -> m (WGS-84)
        #expect(abs((swa.altBaroM ?? 0) - 1625 * 0.3048) < 0.01)
        #expect(abs((swa.gsMps ?? 0) - 195.1 * 1852 / 3600) < 0.01)
        #expect(swa.trackDeg == 298.14)
        #expect(abs((swa.vsMps ?? 0) - 1408 * 0.3048 / 60) < 0.001) // geom_rate preferred
        #expect(swa.squawk == 6310 && !swa.emergency)
        #expect(swa.seenMs == rx - 15)                               // seen_pos 0.015 s

        // On the ground: no pressure altitude, no invented number.
        let gnd = try #require(list.first { $0.hex == "a0ad1d" })
        #expect(gnd.altBaroM == nil && gnd.altGeomM == nil && gnd.trackDeg == nil)
        #expect(gnd.seenMs == rx - 24_071)
        // A non-ICAO (TIS-B) address loses its "~", as on the receivers.
        #expect(list.contains { $0.hex == "a34cac" })
        // No squawk, no emergency field: unknown, not an emergency.
        let ops = try #require(list.first { $0.hex == "a24f2b" })
        #expect(ops.squawk == 0 && !ops.emergency && ops.type.isEmpty)
    }

    @Test func edgeCases() throws {
        let rx: Int64 = 100_000
        let json = #"""
        {"now":1,"total":5,"ac":[
          {"hex":"abc123","lat":37.0,"lon":-122.0,"seen_pos":61},
          {"hex":"abc124","lon":-122.0,"seen_pos":1},
          {"hex":"abc125","lat":37.0,"lon":-122.0,"seen_pos":2,"squawk":"7700","emergency":"general","alt_baro":null},
          {"hex":"abc126","lat":37.0,"lon":-122.0,"seen":3,"emergency":"none","geom_rate":null,"baro_rate":-640},
          {"lat":37.0,"lon":-122.0,"seen_pos":1}
        ]}
        """#
        let list = try AdsbLol.parse(Data(json.utf8), receivedMs: rx)
        #expect(list.map(\.hex) == ["abc125", "abc126"])     // too old / no position / no hex: dropped
        #expect(list[0].squawk == 7700 && list[0].emergency && list[0].altBaroM == nil)
        #expect(list[1].seenMs == rx - 3000)                  // `seen` when there is no seen_pos
        #expect(abs((list[1].vsMps ?? 0) + 640 * 0.3048 / 60) < 1e-9)   // null geom_rate: baro_rate
        #expect(try AdsbLol.parse(Data(#"{"now":1,"total":0}"#.utf8), receivedMs: rx).isEmpty)
        #expect(throws: AdsbError.badAnswer) { try AdsbLol.parse(Data("<html>".utf8), receivedMs: rx) }
    }

    @Test func url() {
        #expect(AdsbLol.url(lat: 37.62, lon: -122.38)?.absoluteString
                == "https://api.adsb.lol/v2/point/37.6200/-122.3800/6")
        #expect(AdsbLol.url(lat: .nan, lon: 0) == nil)
        #expect(AdsbLol.url(template: "https://x/{lat},{lon}?r={radius}", lat: 1, lon: 2, radiusNM: 5)?
                    .absoluteString == "https://x/1.0000,2.0000?r=5")
    }
}

@Suite struct TrafficServiceTests {
    @MainActor private func service(_ answer: Result<Data, Error>, at ms: Int64)
        -> (TrafficService, FakeFetcher, FakeClock) {
        let f = FakeFetcher(answer), c = FakeClock(ms)
        return (TrafficService(fetcher: f, clock: { c.ms }), f, c)
    }

    @MainActor @Test func fetchInstallsNearestFirstAndSchedulesTenSeconds() async throws {
        let t0: Int64 = 1_790_190_047_000
        let (s, f, _) = service(.success(try fixture()), at: t0)
        await s.fetchNow(area: sfoArea)
        #expect(f.urls.count == 1)
        #expect(s.status == .ok && s.failures == 0)
        #expect(s.dataMs == t0)                               // stamped with the receive time
        #expect(s.nextFetchMs == t0 + 10_000)
        #expect(f.urls.first?.absoluteString == "https://api.adsb.lol/v2/point/37.6200/-122.3800/6")
        #expect(s.aircraft.count == 32)                       // 44 within 10 km, capped at 32
        let d = s.aircraft.map { TrafficRules.distanceM(sfo.latitude, sfo.longitude, $0.lat, $0.lon) }
        #expect(d == d.sorted())                              // nearest first
        #expect(d.allSatisfy { $0 <= 10_000 })
        #expect(s.area == sfoArea)
    }

    @MainActor @Test func aircraftBeyondTheRadiusAreDropped() async throws {
        let t0: Int64 = 1_790_190_047_000
        let (s, f, _) = service(.success(try fixture()), at: t0)
        let small = AdsbArea(lat: 37.62, lon: -122.38, radiusM: 5_000)
        await s.fetchNow(area: small)
        #expect(f.urls.first?.absoluteString.hasSuffix("/3") == true)   // 5 km -> 3 NM
        #expect(s.aircraft.count == 32)                       // 41 within 5 km, capped
        // adsb.lol answers in whole NM: what lies past the radius is dropped.
        let near = TrafficAircraft(hex: "aaaaaa", lat: 37.62 + 9_000 / 111_195, lon: -122.38, seenMs: t0)
        let past = TrafficAircraft(hex: "bbbbbb", lat: 37.62 + 10_500 / 111_195, lon: -122.38, seenMs: t0)
        let (s3, _, _) = service(.failure(AdsbError.badAnswer), at: t0)
        s3.install([near, past], receivedMs: t0, area: sfoArea)
        #expect(s3.aircraft == [near])
    }

    @MainActor @Test func backOffOnErrorsKeepsTheSetAndResetsOnSuccess() async throws {
        let t0: Int64 = 1_790_190_047_000
        let (s, f, c) = service(.success(try fixture()), at: t0)
        await s.fetchNow(area: sfoArea)
        let held = s.aircraft
        f.answer = .failure(AdsbError.http(503))
        var gaps: [Int64] = []
        for _ in 0..<6 {
            c.ms = s.nextFetchMs
            await s.fetchNow(area: sfoArea)
            gaps.append(s.nextFetchMs - c.ms)
        }
        #expect(gaps == [20_000, 40_000, 80_000, 160_000, 160_000, 160_000])
        #expect(s.failures == 6)
        if case .failed(let why, let retry) = s.status {
            #expect(why == "HTTP 503" && retry == s.nextFetchMs)
        } else {
            Issue.record("status should be failed")
        }
        #expect(s.aircraft == held)                            // a failure keeps what there was
        #expect(s.dataMs == t0)                                // ... and its age keeps growing
        f.answer = .success(try fixture())
        c.ms += 1_000
        await s.fetchNow(area: sfoArea)
        #expect(s.failures == 0 && s.nextFetchMs == c.ms + 10_000 && s.status == .ok)
        #expect(TrafficService.backoffMs(failures: 0) == 10_000)
    }

    @MainActor @Test func noPositionFetchesNothing() {
        let (s, f, _) = service(.failure(AdsbError.badAnswer), at: 0)
        s.pollIfDue(nowMs: 0, area: nil)
        #expect(s.status == .noPosition && !s.inFlight && f.urls.isEmpty)
        #expect(s.result.summary == "CONFLICT WATCH OFF: no ADS-B source")   // never "no traffic"
    }

    @MainActor @Test func stalenessAndRetention() async throws {
        let t0: Int64 = 1_790_190_047_000
        let (s, _, _) = service(.success(try fixture()), at: t0)
        let observer = TrafficObserver(lat: sfo.latitude, lon: sfo.longitude, elevM: nil)
        s.tick(nowMs: t0, observer: observer, drones: [])
        #expect(s.result.summary == "CONFLICT WATCH OFF: no ADS-B source")
        await s.fetchNow(area: sfoArea)

        s.tick(nowMs: t0 + 5_000, observer: observer, drones: [])
        #expect(!s.result.stale && s.result.haveData)
        // Two aircraft climbing out of SFO within 3 km of the observer: LOW,
        // counted in the watch's status (never as a count of aircraft).
        #expect(s.result.summary == "conflict watch on, 2 low aircraft, data 5 s old")
        #expect(s.result.alerts.allSatisfy { $0.kind == .low && $0.action == "BE READY TO LAND DRONES" })
        #expect(!forbidden(s.result.summary))

        s.tick(nowMs: t0 + 31_000, observer: observer, drones: [])
        #expect(s.result.stale)
        #expect(s.result.summary == "TRAFFIC DATA STALE, data 31 s old")
        #expect(!s.result.alerts.contains { !$0.held })       // nothing new is raised while stale

        // 60 s retention: every position is gone a minute after it was seen.
        s.tick(nowMs: t0 + 85_000, observer: observer, drones: [])
        #expect(s.aircraft.isEmpty && s.result.aircraftCount == 0)
        #expect(s.result.summary == "TRAFFIC DATA STALE, data 85 s old")
    }

    @MainActor @Test func quietTicksPublishNothingNew() async throws {
        let t0: Int64 = 1_790_190_047_000
        let (s, _, _) = service(.success(try fixture()), at: t0)
        await s.fetchNow(area: sfoArea)
        let obs = TrafficObserver(lat: sfo.latitude, lon: sfo.longitude, elevM: nil)
        s.tick(nowMs: t0 + 5_000, observer: obs, drones: [])
        let a = s.result
        s.tick(nowMs: t0 + 5_900, observer: obs, drones: [])   // same whole second
        #expect(s.result == a)
        s.tick(nowMs: t0 + 6_000, observer: obs, drones: [])   // the next second: ages move on
        #expect(s.result != a && s.result.dataAgeS == 6)
    }

    @MainActor @Test func mergeKeepsAircraftTheAnswerLeftOutForSixtySeconds() {
        let (s, _, _) = service(.failure(AdsbError.badAnswer), at: 0)
        let a = TrafficAircraft(hex: "aaaaaa", lat: 37.62, lon: -122.38, seenMs: 1_000)
        let b = TrafficAircraft(hex: "bbbbbb", lat: 37.63, lon: -122.38, seenMs: 1_000)
        s.install([a, b], receivedMs: 1_000, area: sfoArea)
        s.install([b], receivedMs: 30_000, area: sfoArea)
        #expect(Set(s.aircraft.map(\.hex)) == ["aaaaaa", "bbbbbb"])
        s.install([b], receivedMs: 62_000, area: sfoArea)
        #expect(s.aircraft.map(\.hex) == ["bbbbbb"])
    }
}

@Suite struct TrafficPushTests {
    private static let ac = (0..<8).map { i in
        TrafficAircraft(hex: String(format: "a0000%d", i), callsign: "T\(i)", lat: 37.62 + Double(i) * 0.001,
                        lon: -122.38, altGeomM: 300, gsMps: 60, trackDeg: 90, seenMs: 1_000_000 - 1_000)
    }

    @MainActor @Test func cadenceAndFormat() throws {
        let s = TrafficService(fetcher: FakeFetcher(.failure(AdsbError.badAnswer)))
        #expect(s.hostLinesIfDue(nowMs: 1_000_000, unixS: 1_000) == nil)   // no data: nothing
        s.updateAircraft(Self.ac, dataMs: 1_000_000)
        let lines = try #require(s.hostLinesIfDue(nowMs: 1_000_000, unixS: 1_790_000_000))
        #expect(lines.count == 3)                                          // 6 + 2, then done
        #expect(lines.last == #"{"cmd":"traffic_done","n":8,"age_s":0.0}"#)
        #expect(lines.allSatisfy { $0.utf8.count < 1600 })                 // RX_HOST_LINE_MAX
        // A receiver reading them gets the same set back.
        var feed = TrafficHostFeed(observer: .unknown)
        for l in lines {
            let taken = feed.handle(line: l, nowMs: 1_000_000)
            #expect(taken)
        }
        #expect(feed.aircraft.count == 8 && !feed.partial)

        #expect(s.hostLinesIfDue(nowMs: 1_005_000, unixS: 0) == nil)        // not yet 10 s
        #expect(s.hostLinesIfDue(nowMs: 1_010_000, unixS: 0) != nil)        // every 10 s
        s.updateAircraft(Self.ac, dataMs: 1_012_000)
        #expect(s.hostLinesIfDue(nowMs: 1_012_000, unixS: 0) != nil)        // a new set: at once
        #expect(s.hostLinesIfDue(nowMs: 1_073_000, unixS: 0) == nil)        // set over 60 s old
    }

    @MainActor @Test func onlyToAReceiverThatTakesTraffic() throws {
        let model = AppModel(startServices: false)
        var sent: [String] = []
        model.sendLine = { sent.append($0) }
        let now = TrafficRules.nowMs()
        model.traffic.updateAircraft(Self.ac.map { var a = $0; a.seenMs = now; return a }, dataMs: now)

        model.pushTrafficIfDue(nowMs: now)
        #expect(sent.isEmpty)                                   // no port

        model.serialStatus = .connected("/dev/cu.usbmodem1")
        model.ingest(line: #"{"type":"boot","fw":"orecchino","ver":"0.6.0","board":"lilygo-tembed-cc1101","wifi":true,"ble":true,"ble_ext":true}"#)
        model.pushTrafficIfDue(nowMs: now)
        #expect(sent.filter { $0.contains("traffic") }.isEmpty) // no "traffic" capability

        model.ingest(line: #"{"type":"boot","fw":"orecchino","ver":"0.6.0","board":"lilygo-tembed-cc1101","wifi":true,"ble":true,"ble_ext":true,"caps":["log","log_since","tfr","traffic"]}"#)
        #expect(model.receiverTakesTraffic)
        model.pushTrafficIfDue(nowMs: now)
        #expect(sent.filter { $0.hasPrefix(#"{"cmd":"traffic"#) }.count == 3)   // 6 + 2, then done

        model.showTraffic = false
        sent = []
        model.traffic.updateAircraft(Self.ac, dataMs: now + 1)
        model.pushTrafficIfDue(nowMs: now + 1)
        #expect(sent.isEmpty)                                   // the layer is off
    }

    @Test func capabilityRules() {
        #expect(AppModel.takesTraffic(caps: ["log", "traffic"], board: nil))
        #expect(!AppModel.takesTraffic(caps: ["log"], board: "lilygo-t5-epaper-s3-pro"))  // caps win
        #expect(AppModel.takesTraffic(caps: nil, board: "lilygo-t5-epaper-s3-pro"))
        #expect(!AppModel.takesTraffic(caps: nil, board: "sensecap-indicator"))
        #expect(!AppModel.takesTraffic(caps: nil, board: nil))
    }

    @MainActor @Test func heartbeatAndBootFields() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"boot","fw":"orecchino","ver":"0.6.0","board":"lilygo-t5-epaper-s3-pro","wifi":false,"ble":true,"ble_ext":true,"display":true}"#)
        #expect(model.stats.board == "lilygo-t5-epaper-s3-pro" && model.stats.bootWifi == false)
        #expect(model.receiverCaps == nil && model.receiverTakesTraffic)
        model.ingest(line: #"{"type":"hb","up":1,"wifi_frames":2,"ble_advs":3,"rid":0,"dropped":0,"ch":6,"ble":true,"ble_ext":true,"ble_rx_drop":4,"rx_stack":1520,"caps":["log"]}"#)
        #expect(model.stats.bleRxDrop == 4 && model.stats.rxStack == 1520)
        #expect(model.receiverCaps == ["log"] && !model.receiverTakesTraffic)
    }
}

@Suite struct TrafficModelTests {
    @Test func trafficIdsAndReference() {
        #expect(AppModel.trafficId(trackKey: "uas:1581F5FHD23AB00D") == "1581F5FHD23AB00D")
        #expect(AppModel.trafficId(trackKey: "mac:02:00:5E:7E:57:01") == "02:00:5E:7E:57:01")
        let mac = CLLocationCoordinate2D(latitude: 1, longitude: 2)
        let d = [CLLocationCoordinate2D(latitude: 10, longitude: 20),
                 CLLocationCoordinate2D(latitude: 12, longitude: 22)]
        #expect(AppModel.reference(mac: mac, drones: d)?.latitude == 1)
        #expect(AppModel.reference(mac: nil, drones: d)?.latitude == 11)
        #expect(AppModel.reference(mac: nil, drones: []) == nil)          // never a made-up place
    }

    @MainActor @Test func observerIsThisMacAndElevationOnlyWhenValid() {
        let model = AppModel(startServices: false)
        #expect(model.trafficObserver == .unknown)
        model.location.currentLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.8, longitude: -122.4), altitude: 30,
            horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: Date())
        #expect(model.trafficObserver.lat == 37.8 && model.trafficObserver.elevM == nil)
        model.location.currentLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.8, longitude: -122.4), altitude: 30,
            horizontalAccuracy: 50, verticalAccuracy: 10, timestamp: Date())
        #expect(model.trafficObserver.elevM != nil)
    }

    @MainActor @Test func pairAlertsNameTheDroneByItsId() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:30","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F20000D9A03"}],"loc":{"status":2,"lat":37.8,"lon":-122.4,"alt_geo":100,"alt_baro":95,"height":50,"height_ref":0,"speed":0,"dir":0,"ts":100}}"#)
        let now = TrafficRules.nowMs()
        model.now = Date(timeIntervalSince1970: Double(now) / 1000)
        model.traffic.updateAircraft([TrafficAircraft(hex: "a1b2c3", callsign: "UAL123", lat: 37.805, lon: -122.4,
                                                      altGeomM: 150, seenMs: now - 2_000)], dataMs: now - 2_000)
        model.trafficTick()
        let al = try #require(model.traffic.result.alerts.first)
        #expect(al.text == "TRAFFIC NEAR DRONE D9A03")
        #expect(model.track(trafficId: al.droneId)?.id == "uas:1581F20000D9A03")
        #expect(model.coordinates(of: al).count == 2)          // "Show" frames both
        #expect(al.ageS == 2)
    }

    @MainActor @Test func sidebarSelectionKeepsAircraftOutOfTheDroneSelection() {
        let model = AppModel(startServices: false)
        model.sidebarSelection = .drone("uas:X")
        #expect(model.selection == "uas:X" && model.selectedTraffic == nil)
        model.sidebarSelection = .traffic("a1b2c3")
        #expect(model.selection == nil && model.selectedTraffic == "a1b2c3")
        #expect(model.sidebarSelection == .traffic("a1b2c3"))
        model.sidebarSelection = nil
        #expect(model.selection == nil && model.selectedTraffic == nil)
    }

    @Test func nearestTrafficRow() throws {
        let a = TrafficAircraft(hex: "a1b2c3", callsign: "UAL123", type: "B738", lat: 37.81, lon: -122.4,
                                altGeomM: 190, gsMps: 90, trackDeg: 180, seenMs: 0)
        let far = TrafficAircraft(hex: "ffffff", lat: 38.2, lon: -122.4, seenMs: 0)
        let n = try #require(NearestTraffic.find(lat: 37.8, lon: -122.4, altGeoM: 100, speedMps: nil,
                                                 headingDeg: nil, aircraft: [far, a], nowMs: 1_000))
        #expect(n.text == "UAL123 B738 · 1.1 km · +90 m · closing")
        let away = TrafficAircraft(hex: "a1b2c3", lat: 37.81, lon: -122.4, gsMps: 90, trackDeg: 0, seenMs: 0)
        let o = try #require(NearestTraffic.find(lat: 37.8, lon: -122.4, altGeoM: nil, speedMps: nil,
                                                 headingDeg: nil, aircraft: [away], nowMs: 1_000))
        #expect(o.text == "A1B2C3 · 1.1 km · height unknown · opening")
        #expect(NearestTraffic.find(lat: 37.8, lon: -122.4, altGeoM: nil, speedMps: nil, headingDeg: nil,
                                    aircraft: [a], nowMs: 61_000) == nil)   // older than 60 s
    }

    @Test func menuBarLabelIsAboutDrones() {
        var r = TrafficResult()
        #expect(TrafficMenuLabel.text(drones: 0, r, showTraffic: true) == "")    // glyph only
        #expect(TrafficMenuLabel.text(drones: 2, r, showTraffic: true) == "2")   // drones heard
        r.haveData = true
        r.dataAgeS = 3
        r.alerts = Array(repeating: TrafficAlert(level: .warning, kind: .near, held: false, heightUnknown: false,
                                                 droneIndex: nil, acIndex: nil, droneId: "D9A03", hex: "a1b2c3",
                                                 callsign: "", horizM: 500, vertM: nil, bearingDeg: 0,
                                                 cpaS: nil, cpaM: nil, ageS: 3, text: ""), count: 3)
        #expect(TrafficMenuLabel.text(drones: 2, r, showTraffic: true) == "2 !3")  // 3 alerts, never aircraft
        r.stale = true
        #expect(TrafficMenuLabel.text(drones: 2, r, showTraffic: true) == "2 !3 STALE")
        #expect(TrafficMenuLabel.text(drones: 2, r, showTraffic: false) == "2")
    }
}

@Suite struct TrafficNotifyTests {
    private func alert(_ kind: TrafficKind, drone: String = "1581F20000D9A03", held: Bool = false) -> TrafficAlert {
        TrafficAlert(level: kind.level, kind: kind, held: held, heightUnknown: false,
                     droneIndex: nil, acIndex: nil, droneId: kind.isPair ? drone : "", hex: "a1b2c3",
                     callsign: "UAL123", horizM: 1_100, vertM: kind.isPair ? 90 : nil, bearingDeg: 45,
                     cpaS: nil, cpaM: nil, ageS: 6, text: kind == .near ? "TRAFFIC NEAR DRONE D9A03" : "LOW TRAFFIC NE 1.1 KM")
    }

    @Test func oncePerPairPerFiveMinutes() {
        var lim = TrafficNotifyLimiter()
        var act = Set<String>()
        func due(_ al: [TrafficAlert], _ t: Int64) -> Int {
            TrafficNotifier.toNotify(al, active: &act, limiter: &lim, nowMs: t).count
        }
        #expect(due([alert(.near)], 0) == 1)
        #expect(due([alert(.near)], 1_000) == 0)               // still the same raised alert
        #expect(due([], 2_000) == 0)
        #expect(due([alert(.near)], 60_000) == 0)              // raised again within 5 min
        // NEAR and CONVERGING are one pair.
        #expect(due([alert(.converging)], 120_000) == 0)
        // Another drone with the same aircraft is another pair.
        #expect(due([alert(.converging), alert(.near, drone: "OTHER")], 121_000) == 1)
        #expect(due([], 299_000) == 0)
        #expect(due([alert(.near)], 300_000) == 1)             // 5 min on, raised anew
        #expect(due([alert(.near)], 700_000) == 0)             // held on screen: no repeat
        // Held alerts never notify.
        var fresh = TrafficNotifyLimiter()
        var none = Set<String>()
        #expect(TrafficNotifier.toNotify([alert(.near, held: true)], active: &none, limiter: &fresh, nowMs: 0).isEmpty)
    }

    @Test func wordingLeadsWithTheAction() {
        let ac = TrafficAircraft(hex: "a1b2c3", callsign: "UAL123", type: "B738", lat: 0, lon: 0,
                                 altBaroM: 2650 * 0.3048, seenMs: 0)
        var near = alert(.near)
        near.action = "GIVE WAY: DESCEND AND LAND D9A03"
        near.resolution = "GIVE WAY: DESCEND AND LAND D9A03; AIRCRAFT 90 M ABOVE, 1.1 KM NE"
        #expect(TrafficNotifier.title(near) == "GIVE WAY: DESCEND AND LAND D9A03")
        let body = TrafficNotifier.body(near, aircraft: ac)
        #expect(body == "AIRCRAFT 90 M ABOVE, 1.1 KM NE · B738 UAL123 · 2,650 ft · reported 6 s ago")
        #expect(trafficTag(near) == "GIVE WAY")
        #expect(trafficGeometry(near) == "AIRCRAFT 90 M ABOVE, 1.1 KM NE")
        // No action from the rules: the words stand in.
        #expect(TrafficNotifier.title(alert(.near)) == "TRAFFIC NEAR DRONE D9A03")
        #expect(!forbidden(body))
        #expect(TrafficNotifier.feet(12_000 * 0.3048) == "12,000")
    }
}

@Suite struct TFRShapeTests {
    private func circle(lat: Double, lon: Double, radiusM: Double, n: Int) -> [CLLocationCoordinate2D] {
        (0...n).map { i in   // closed, as GeoJSON rings are
            let a = Double(i % n) / Double(n) * 2 * .pi
            return CLLocationCoordinate2D(latitude: lat + radiusM * cos(a) / 110_540,
                                          longitude: lon + radiusM * sin(a) / (111_320 * cos(lat * .pi / 180)))
        }
    }

    @Test func thirtyNmCircleIsNeverCutInside() {
        let r = 30 * 1852.0
        let ring = circle(lat: 38.9, lon: -77.0, radiusM: r, n: 360)
        let out = TFRShape.enclosing(ring)
        #expect(out.count <= 24 && out.count >= 3)
        // Rounded as it is sent, every point of the real outline is inside.
        let sent = out.map { CLLocationCoordinate2D(latitude: (($0.latitude * 1e5).rounded()) / 1e5,
                                                    longitude: (($0.longitude * 1e5).rounded()) / 1e5) }
        #expect(ring.allSatisfy { TFRShape.contains(sent, $0) })
        // ... and even a point 1 m inside the old chord band is covered.
        let inner = circle(lat: 38.9, lon: -77.0, radiusM: r - 1, n: 1_440)
        #expect(inner.allSatisfy { TFRShape.contains(sent, $0) })
        // It errs outward by little: no vertex more than ~2 % out.
        let far = out.map { hypot(($0.latitude - 38.9) * 110_540,
                                  ($0.longitude + 77.0) * 111_320 * cos(38.9 * .pi / 180)) }.max() ?? 0
        #expect(far < r * 1.02)
    }

    @Test func smallRingsAreSentAsTheyAre() {
        let sq = [CLLocationCoordinate2D(latitude: 1, longitude: 1), CLLocationCoordinate2D(latitude: 1, longitude: 2),
                  CLLocationCoordinate2D(latitude: 2, longitude: 2), CLLocationCoordinate2D(latitude: 2, longitude: 1),
                  CLLocationCoordinate2D(latitude: 1, longitude: 1)]
        let out = TFRShape.enclosing(sq)
        #expect(out.count == 4 && out[0].latitude == 1 && out[3].longitude == 1)
    }

    @Test func concaveOutlineIsFilledNotCut() {
        // An L of 60 points: its hull (and so the polygon sent) covers it.
        var ring: [CLLocationCoordinate2D] = []
        for i in 0..<20 { ring.append(.init(latitude: 40, longitude: -100 + Double(i) * 0.01)) }
        for i in 0..<20 { ring.append(.init(latitude: 40 + Double(i) * 0.005, longitude: -99.8)) }
        for i in 0..<20 { ring.append(.init(latitude: 40.1, longitude: -99.8 - Double(i) * 0.01)) }
        let out = TFRShape.enclosing(ring, maxPoints: 24)
        #expect(out.count <= 24)
        #expect(ring.allSatisfy { TFRShape.contains(out, $0) })
    }

    @Test func tfrLinesNearestFirstAndBounded() throws {
        func zone(_ id: String, _ lat: Double) -> TFRZone {
            let ring = circle(lat: lat, lon: -122.4, radiusM: 5_000, n: 100)
            return TFRZone(id: id, notam: id, title: id, legal: "HAZARDS", state: "CA", outerRing: ring,
                           centroid: .init(latitude: lat, longitude: -122.4))
        }
        let lines = AppModel.tfrLines(zones: [zone("FAR", 38.5), zone("NEAR", 37.9), zone("GONE", 45)],
                                      reference: .init(latitude: 37.8, longitude: -122.4))
        #expect(lines.first == #"{"cmd":"tfr_clear"}"#)
        #expect(lines.count == 3)                                            // GONE is > 200 km away
        #expect(lines[1].contains(#""id":"NEAR""#) && lines[2].contains(#""id":"FAR""#))
        for l in lines.dropFirst() {
            let o = try #require(JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])
            let pts = try #require(o["pts"] as? [[Double]])
            #expect(pts.count >= 3 && pts.count <= 24)
        }
    }
}

@Suite struct DeviceLogSyncTests {
    static func rec(_ seq: Int) -> String {
        #"{"type":"log","seq":\#(seq),"i":\#(seq),"active":false,"uas":"U\#(seq)","mac":"60:60:1F:AA:BB:0\#(seq % 10)","srcs":4,"fmts":1,"ua_type":2,"first":1790000000,"last":1790000010,"dur":10,"peak_rssi":-60,"auth_state":"test_key","tfr":false,"emerg":false,"msgs":5}"#
    }
    static let live = #"{"type":"log","seq":null,"i":null,"active":true,"uas":"LIVE","mac":"02:00:5E:7E:57:01","srcs":4,"fmts":1,"ua_type":0,"first":0,"last":0,"dur":3,"peak_rssi":-70,"auth_state":"none","tfr":false,"emerg":false,"msgs":4}"#

    private func decode(_ s: String) throws -> RidMessage {
        try JSONDecoder().decode(RidMessage.self, from: Data(s.utf8))
    }

    @MainActor @Test func incrementalReadsAskOnlyForNewRecords() throws {
        let log = DeviceLog()
        var sent: [String] = []
        log.send = { sent.append($0) }
        log.isConnected = { true }

        log.fetch()
        #expect(sent.last == #"{"cmd":"log_get"}"#)
        for s in [2, 3] { log.handle(try decode(Self.rec(s))) }
        log.handle(try decode(Self.live))
        log.handle(try decode(#"{"type":"log_done","n":2,"live":1,"total":4,"clock":true,"next":4,"oldest":2}"#))
        #expect(log.phase == .done && log.cursor == 4 && log.missed == 2)
        #expect(log.entries.map(\.index) == [nil, 3, 2])
        #expect(log.entries.first?.id == "live:02:00:5E:7E:57:01")

        // Next read: only records from seq 4; the live contact ended as 4.
        log.fetch()
        #expect(sent.last == #"{"cmd":"log_get","since":4}"#)
        log.handle(try decode(Self.rec(4)))
        log.handle(try decode(#"{"type":"log_done","n":3,"live":0,"total":5,"clock":true,"next":5,"oldest":2}"#))
        #expect(log.entries.map(\.index) == [4, 3, 2])     // kept, merged, no live left
        #expect(log.cursor == 5 && log.missed == 2)
        #expect(RidNames.authLabel(log.entries[0].authState) == "TEST KEY")
    }

    @MainActor @Test func aCursorAboveTotalRestartsFromOldest() throws {
        let log = DeviceLog()
        var sent: [String] = []
        log.send = { sent.append($0) }
        log.isConnected = { true }
        log.fetch()
        for s in 0..<3 { log.handle(try decode(Self.rec(s))) }
        log.handle(try decode(#"{"type":"log_done","n":3,"live":0,"total":3,"clock":true,"next":3,"oldest":0}"#))
        #expect(log.cursor == 3)

        // Cleared on the device (by another app) and one new contact since.
        log.fetch()
        #expect(sent.last == #"{"cmd":"log_get","since":3}"#)
        log.handle(try decode(#"{"type":"log_done","n":1,"live":0,"total":1,"clock":true,"next":1,"oldest":0}"#))
        #expect(log.phase == .fetching)
        #expect(sent.last == #"{"cmd":"log_get","since":0}"#)
        log.handle(try decode(Self.rec(0)))
        log.handle(try decode(#"{"type":"log_done","n":1,"live":0,"total":1,"clock":true,"next":1,"oldest":0}"#))
        #expect(log.phase == .done && log.entries.map(\.index) == [0] && log.cursor == 1)
        #expect(log.entries[0].uasId == "U0")
    }

    @MainActor @Test func clearingResetsTheCursor() throws {
        let log = DeviceLog()
        log.send = { _ in }
        log.isConnected = { true }
        log.fetch()
        log.handle(try decode(Self.rec(0)))
        log.handle(try decode(#"{"type":"log_done","n":1,"live":0,"total":1,"clock":true,"next":1,"oldest":0}"#))
        log.handle(try decode(#"{"type":"log_cleared"}"#))
        #expect(log.cursor == 0 && log.entries.isEmpty)
    }

    @Test func csvDefusesFormulas() throws {
        let line = Self.rec(1).replacingOccurrences(of: #""uas":"U1""#, with: #""uas":"=HYPERLINK(\"http://x\")""#)
        let e = try #require(DeviceLogEntry(try decode(line)))
        let row = DeviceLog.csv([e]).split(separator: "\n")[1]
        #expect(row.hasPrefix(#"ended,"'=HYPERLINK(""http://x"")","60:60:1F:AA:BB:01""#))
        for bad in ["+1", "-1", "@SUM(A1)", "\tx", "\rx"] {
            let l2 = Self.rec(1).replacingOccurrences(of: #""uas":"U1""#, with: "\"uas\":\"\(bad.replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\r", with: "\\r"))\"")
            let e2 = try #require(DeviceLogEntry(try decode(l2)))
            #expect(DeviceLog.csv([e2]).contains("\"'\(bad)"))
        }
    }
}

@Suite struct AdsbAreaTests {
    private let mac = CLLocationCoordinate2D(latitude: 37.8, longitude: -122.4)
    private func north(_ m: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 37.8 + m / 111_195, longitude: -122.4)
    }

    @Test func defaultIsTenKmOnThisMac() {
        let a = AdsbArea.make(mac: mac, liveDrones: [north(2_900)], baseKm: 10)
        #expect(a == AdsbArea(lat: 37.8, lon: -122.4, radiusM: 10_000))
        #expect(a?.radiusNM == 6)
        #expect(AdsbArea.make(mac: mac, liveDrones: [], baseKm: 2)?.radiusM == 5_000)    // 5 km at least
        #expect(AdsbArea.make(mac: mac, liveDrones: [], baseKm: 99)?.radiusM == 30_000)  // 30 km at most
        #expect(AdsbArea.make(mac: nil, liveDrones: [], baseKm: 10) == nil)             // nowhere to look
    }

    @Test func aMovedCentreStaysWithinPlusMinus180() throws {
        // A Mac just west of the antimeridian and a drone 8 km east of it:
        // the centre moves across and must read as about -179.99, not 180.01.
        let west = CLLocationCoordinate2D(latitude: 52, longitude: 179.99)
        let east = CLLocationCoordinate2D(latitude: 52, longitude: -179.9)
        let a = try #require(AdsbArea.make(mac: west, liveDrones: [east], baseKm: 10))
        #expect(a.lon >= -180 && a.lon <= 180)
        #expect(a.lon < 0)
    }

    @Test func aFarDroneMovesTheCentreAndGetsNineKm() throws {
        let d = north(8_000)
        let a = try #require(AdsbArea.make(mac: mac, liveDrones: [d], baseKm: 10))
        let toDrone = TrafficRules.distanceM(a.lat, a.lon, d.latitude, d.longitude)
        #expect(abs(toDrone - 4_000) < 5)                      // centre between Mac and drone
        #expect(a.radiusM - toDrone >= 9_000 - 1e-6)           // 9 km around the drone
        #expect(abs(a.radiusM - 13_000) < 5)
        // Far apart drones: capped at 30 km.
        let b = try #require(AdsbArea.make(mac: mac, liveDrones: [north(60_000)], baseKm: 10))
        #expect(b.radiusM == 30_000)
        // No Mac position: around the drones.
        let c = try #require(AdsbArea.make(mac: nil, liveDrones: [d], baseKm: 10))
        #expect(abs(c.lat - d.latitude) < 1e-9 && c.radiusM == 10_000)
    }
}

@Suite struct DronesFirstTests {
    @MainActor @Test func onlyAlertedAircraftAreDrawn() throws {
        let model = AppModel(startServices: false)
        model.ingest(line: #"{"type":"rid","src":"ble","mac":"02:00:5E:7E:57:31","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F20000D9A03"}],"loc":{"status":2,"lat":37.8,"lon":-122.4,"alt_geo":100,"alt_baro":95,"height":50,"height_ref":0,"speed":0,"dir":0,"ts":100}}"#)
        let now = TrafficRules.nowMs()
        model.now = Date(timeIntervalSince1970: Double(now) / 1000)
        let close = TrafficAircraft(hex: "a1b2c3", callsign: "UAL123", lat: 37.805, lon: -122.4,
                                    altGeomM: 150, seenMs: now - 2_000)
        let far = TrafficAircraft(hex: "ffffff", callsign: "SWA1", lat: 37.9, lon: -122.4,
                                  altGeomM: 3_000, seenMs: now - 2_000)
        model.traffic.updateAircraft([close, far], dataMs: now - 2_000)
        model.trafficTick()
        #expect(model.alertedAircraft.map(\.hex) == ["a1b2c3"])   // the far one is never drawn
        let t = try #require(model.tracks["uas:1581F20000D9A03"])
        let al = try #require(model.trafficAlert(forTrack: t))
        #expect(al.action.hasPrefix("GIVE WAY"))
        model.select(alert: al)
        #expect(model.selection == t.id)                          // an alert opens its drone
        model.showTraffic = false
        #expect(model.alertedAircraft.isEmpty && model.trafficAlert(forTrack: t) == nil)
    }
}

@Suite struct TilePlanTests {
    // Numbers from firmware/common/tile_plan.h itself (a C harness over the
    // same calls), so the Swift port is checked against the reference.
    @Test func circleCountsMatchTheFirmware() {
        let want: [(Double, Double, Double, [UInt32])] = [
            (37.8, -122.4, 3000, [3, 7, 14, 42]), (37.8, -122.4, 10000, [11, 31, 105, 377]),
            (0.5, 10.0, 6000, [4, 9, 31, 98]), (69.6, 18.9, 10000, [37, 131, 481, 1826]),
            (-33.9, 151.2, 3000, [2, 6, 14, 41]),
        ]
        for (lat, lon, r, counts) in want {
            let got = (12...15).map { TilePlanner.circleCount(lat: lat, lon: lon, r: r, z: $0) }
            #expect(got == counts, "\(lat),\(lon) r \(r)")
        }
        #expect(TilePlanner.tileOf(lat: 37.7749, lon: -122.4194, z: 15) == (5241, 12665))
        let k = TilePlanner.key(15, 5241, 12665)
        #expect(TilePlanner.split(k) == (15, 5241, 12665))
        #expect(TilePlanner.key(path: "/tiles/15/5241/12665.png") == k)
        #expect(TilePlanner.key(path: "/tiles/15/5241/12665.jpg") == k)
        #expect(TilePlanner.key(path: "/tiles/../log/x") == nil)
        #expect(TilePlanner.key(path: "/tiles/.src") == nil)
        #expect(TilePlanner.path(15, 5241, 12665) == "/tiles/15/5241/12665.jpg")
    }

    @Test func esriSourceZYXAndJPEGOnly() throws {
        // tile_path.h's TILE_BASE_URL: Esri World Dark Gray, row before column.
        let u = try #require(TileSync.url(z: 15, x: 5241, y: 12665))
        #expect(u.absoluteString ==
                "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/15/12665/5241")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])
        let placeholder = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])   // CARTO's "API KEY REQUIRED" is a PNG
        #expect(TileSync.isTile(jpeg, contentType: "image/jpeg"))
        #expect(TileSync.isTile(jpeg, contentType: nil))
        #expect(!TileSync.isTile(placeholder, contentType: "image/png"))
        #expect(!TileSync.isTile(Data("<html>".utf8), contentType: "text/html"))
        #expect(!TileSync.isTile(jpeg, contentType: "text/html"))
        #expect(TileSync.attribution.contains("Esri") && TileSync.attribution.contains("OpenStreetMap"))
    }

    @Test func diskListMergesFormatsAndSkipsTheMark() {
        let (disk, paths) = TileSync.diskList([
            "/tiles/14/2623/6329.png": 9000, "/tiles/14/2623/6329.jpg": 7000,
            "/tiles/.src": 8, "/tiles/15/5241/12665.jpg": 12000,
        ])
        #expect(disk.count == 2)
        let k = TilePlanner.key(14, 2623, 6329)
        #expect(disk.first { $0.key == k }?.bytes == 16000)
        #expect(paths[k] == ["/tiles/14/2623/6329.jpg", "/tiles/14/2623/6329.png"])
        #expect(disk == disk.sorted { $0.key < $1.key })
    }

    @Test func budgetsAndShrinkingMatchTheFirmware() {
        let t5: UInt64 = 0xCF0000, sensecap: UInt64 = 0x5E0000
        let p = TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 3000, fsTotal: t5, fsUsed: 64 * 1024, disk: [])
        #expect(p.total == 66 && p.needBytes == 811_008 && p.capacity == 12_451_840 && p.fits && !p.shrunk)
        #expect(TilePlanner.describe(p) == "Map: 3 km z12–15 · 0.8 MB of 11.9 MB")
        #expect(p.allTiles.count == 66)
        let s10 = TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 10000, fsTotal: sensecap, fsUsed: 200 * 1024, disk: [])
        #expect(s10.radiusM == [10000, 10000, 10000, 8000] && s10.total == 397 && s10.fits && s10.shrunk)
        #expect(TilePlanner.describe(s10) == "Map: 10 km z12–14, 8 km z15 · 4.7 MB of 4.7 MB")
        let s30 = TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 30000, fsTotal: sensecap, fsUsed: 200 * 1024, disk: [])
        #expect(s30.radiusM == [30000, 30000, 10250, -1] && s30.total == 399)   // z15 dropped, then z14 shrinks
        #expect(TilePlanner.maxRadiusM(lat: 37.8, lon: -122.4, capacity: t5 - TilePlanner.reserve, avgBytes: 11 * 1024) == 14750)
        #expect(TilePlanner.maxRadiusM(lat: 37.8, lon: -122.4, capacity: sensecap - TilePlanner.reserve, avgBytes: 11 * 1024) == 9000)
        // The estimate: the board's own average from 20 tiles on.
        let d30 = (0..<30).map { TilePlanner.OnDisk(key: TilePlanner.key(15, 5241 + Int32($0), 12665), bytes: 9000) }
        #expect(TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 3000, fsTotal: t5, fsUsed: 30 * 10_000, disk: d30).avgBytes == 10_000)
        #expect(TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 3000, fsTotal: t5, fsUsed: 90_000,
                                 disk: Array(d30.prefix(10))).avgBytes == 12_288)
    }

    @Test func evictionNeverTouchesThePlan() {
        var d: [TilePlanner.OnDisk] = []
        for z in 12...15 {
            let t = TilePlanner.tileOf(lat: 39.5, lon: -122.4, z: z)
            for i in 0..<60 { d.append(.init(key: TilePlanner.key(z, t.x + Int32(i % 10), t.y + Int32(i / 10)), bytes: 11 * 1024)) }
        }
        let c = TilePlanner.tileOf(lat: 37.8, lon: -122.4, z: 15)
        for k in [TilePlanner.key(15, c.x, c.y), TilePlanner.key(15, c.x + 1, c.y), TilePlanner.key(14, c.x / 2, c.y / 2)] {
            d.append(.init(key: k, bytes: 11 * 1024))
        }
        d.sort { $0.key < $1.key }
        let used = UInt64(d.count) * 11 * 1024
        let p = TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 3000, fsTotal: used + TilePlanner.reserve + 200 * 1024,
                                 fsUsed: used, disk: d)
        #expect(p.present == 3 && p.evictable == UInt64(d.count - 3) * 11 * 1024 && p.avgBytes == 11_264)
        #expect(p.fits && !p.shrunk)
        let v = TilePlanner.victims(p, d, need: 50 * 1024)
        #expect(v.indices == [237, 231, 225, 219, 213] && v.freed == 56_320)       // as the C code picks
        let all = TilePlanner.victims(p, d, need: .max)
        #expect(all.indices.count == d.count - 3)
        #expect(all.indices.allSatisfy { let (z, x, y) = TilePlanner.split(d[$0].key); return !p.contains(z: z, x: x, y: y) })
    }
}

@Suite struct TileSyncPlanTests {
    @MainActor @Test func asksTheBoardThenShowsThePlan() throws {
        let ts = TileSync()
        var sent: [String] = []
        ts.sendLine = { sent.append($0) }
        ts.isConnected = { true }
        ts.plan(around: (37.8, -122.4))
        #expect(ts.phase == .planning)
        #expect(sent.last == #"{"cmd":"fs_stat","lat":37.80000,"lon":-122.40000}"#)
        let dec = JSONDecoder()
        func line(_ s: String) throws -> RidMessage { try dec.decode(RidMessage.self, from: Data(s.utf8)) }
        ts.handle(try line(#"{"type":"fs_stat","total":13565952,"used":65536,"free":13500416,"reserve":1048576,"tiles":0,"tile_bytes":0,"avg_tile":12288,"capacity":12451840,"max_radius_km":14.75}"#))
        #expect(sent.last == #"{"cmd":"fs_ls"}"#)
        ts.handle(try line(#"{"type":"fs_ls_done","n":0}"#))
        #expect(ts.phase == .planned("Map: 3 km z12–15 · 0.8 MB of 11.9 MB"))
        #expect(!ts.running && ts.currentPlan?.total == 66 && ts.storageKnown)
    }

    @MainActor @Test func oldFirmwareWithoutFsStatStillPlans() throws {
        let ts = TileSync()
        ts.sendLine = { _ in }
        ts.isConnected = { true }
        ts.plan(around: (37.8, -122.4))
        ts.statUnanswered()
        ts.handle(try JSONDecoder().decode(RidMessage.self, from: Data(#"{"type":"fs_ls_done","n":0}"#.utf8)))
        #expect(ts.phase == .planned("Map: 3 km z12–15 · 0.8 MB, receiver storage unknown"))
        #expect(!ts.storageKnown)
    }

    @MainActor @Test func queueEvictsOnlyTheShortfallOutsideThePlan() throws {
        let ts = TileSync()
        ts.sendLine = { _ in }
        ts.isConnected = { true }
        ts.plan(around: (37.8, -122.4))
        let dec = JSONDecoder()
        func line(_ s: String) throws -> RidMessage { try dec.decode(RidMessage.self, from: Data(s.utf8)) }
        // 100 old tiles 190 km away fill the board to 200 KB past the reserve.
        var old: [String] = []
        for i in 0..<100 { old.append("/tiles/15/\(5241 + i % 10)/\(12500 + i / 10).png") }
        let used = 100 * 12_288
        ts.handle(try line(#"{"type":"fs_stat","total":\#(used + 1_048_576 + 200 * 1024),"used":\#(used)}"#))
        for p in old { ts.handle(try line(#"{"type":"fs_f","p":"\#(p)","s":12288}"#)) }
        ts.handle(try line(#"{"type":"fs_ls_done","n":100}"#))
        let plan = try #require(ts.currentPlan)
        #expect(plan.fits && !plan.shrunk)
        ts.buildQueue(plan, localSize: { _ in 8_000 })              // every plan tile cached at 8 KB
        let q = ts.queuedForTest
        #expect(q.send.count == 66)
        // 66 new tiles at 8 KB (8 KB on flash) = 528 KB, 200 KB of room: 328 KB to evict.
        #expect(q.delete.count == Int((328.0 * 1024 / 12_288).rounded(.up)))
        #expect(Set(q.delete).isSubset(of: Set(old)))
    }

    @MainActor @Test func queueUnderTheReserveEvictsTheDeficitToo() throws {
        let ts = TileSync()
        ts.sendLine = { _ in }
        ts.isConnected = { true }
        ts.plan(around: (37.8, -122.4))
        let dec = JSONDecoder()
        func line(_ s: String) throws -> RidMessage { try dec.decode(RidMessage.self, from: Data(s.utf8)) }
        // The same 100 old tiles, but the board is 300 KB under the reserve.
        var old: [String] = []
        for i in 0..<100 { old.append("/tiles/15/\(5241 + i % 10)/\(12500 + i / 10).png") }
        let used = 100 * 12_288
        ts.handle(try line(#"{"type":"fs_stat","total":\#(used + 1_048_576 - 300 * 1024),"used":\#(used)}"#))
        for p in old { ts.handle(try line(#"{"type":"fs_f","p":"\#(p)","s":12288}"#)) }
        ts.handle(try line(#"{"type":"fs_ls_done","n":100}"#))
        let plan = try #require(ts.currentPlan)
        #expect(plan.budget == plan.evictable - 300 * 1024)
        #expect(plan.fits && !plan.shrunk)
        ts.buildQueue(plan, localSize: { _ in 8_000 })
        let q = ts.queuedForTest
        // 66 x 8 KB = 528 KB, plus the 300 KB owed to the reserve: 828 KB to evict.
        #expect(q.send.count == 66)
        #expect(q.delete.count == Int((828.0 * 1024 / 12_288).rounded(.up)))
        #expect(Set(q.delete).isSubset(of: Set(old)))
    }

    @MainActor @Test func pngTilesInThePlanAreReplacedNotDuplicated() throws {
        let ts = TileSync()
        ts.sendLine = { _ in }
        ts.isConnected = { true }
        ts.plan(around: (37.8, -122.4))
        let dec = JSONDecoder()
        func line(_ s: String) throws -> RidMessage { try dec.decode(RidMessage.self, from: Data(s.utf8)) }
        ts.handle(try line(#"{"type":"fs_stat","total":13565952,"used":65536}"#))
        // Three plan tiles held as CARTO .png only; a fourth as a current
        // .jpg with a stale .png beside it.
        let first = Array(TilePlanner.make(lat: 37.8, lon: -122.4, wantM: 3000, fsTotal: 13565952,
                                           fsUsed: 65536, disk: []).allTiles.prefix(4))
        let png = first.map { "/tiles/\($0.z)/\($0.x)/\($0.y).png" }
        let jpg4 = "/tiles/\(first[3].z)/\(first[3].x)/\(first[3].y).jpg"
        for p in png { ts.handle(try line(#"{"type":"fs_f","p":"\#(p)","s":12288}"#)) }
        ts.handle(try line(#"{"type":"fs_f","p":"\#(jpg4)","s":8000}"#))
        ts.handle(try line(#"{"type":"fs_ls_done","n":5}"#))
        let p = try #require(ts.currentPlan)
        ts.buildQueue(p, localSize: { _ in 8_000 })
        let q = ts.queuedForTest
        #expect(q.send.count == 65)                       // every plan tile but the current .jpg
        #expect(ts.replacedForTest == Array(png.prefix(3)))   // each .png goes after its .jpg lands
        #expect(q.delete == [png[3]])                     // the stale one beside a current .jpg goes first
    }
}
