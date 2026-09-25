// TrafficService.swift — the Mac's ADS-B source (plan §8.1, §8.5).
//
// Fetches adsb.lol around a reference point (this Mac's position, else the
// drones') every 10 s, backs off on errors, keeps each aircraft for 60 s,
// runs TrafficRules against the drones, and hands the `traffic` host lines
// (TrafficWire.hostLines) to AppModel to push to a receiver that takes them.
// The network fetch and the clock are injected, so the tests drive it with a
// recorded answer and a fake clock.
// Words: never "collision", "conflict", "safe", "clear" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreLocation
import Observation

// MARK: - Fetching

/// One HTTP GET. The app uses URLSessionAdsbFetcher; the tests a fake.
public protocol AdsbFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public enum AdsbError: Error, Equatable, LocalizedError {
    case http(Int)
    case badAnswer
    public var errorDescription: String? {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .badAnswer:   return "unreadable answer"
        }
    }
}

public struct URLSessionAdsbFetcher: AdsbFetching {
    public var timeout: TimeInterval
    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Named, as TileSync's session is: adsb.lol asks that clients identify
        // themselves. (Outside the .app bundle, say under swift test, there is
        // no version string; 1.0 then.)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        cfg.httpAdditionalHeaders =
            ["User-Agent": "Orecchino/\(version) (macOS; manned traffic near an Orecchino receiver; 1 request/10 s)"]
        session = URLSession(configuration: cfg)
    }

    public func data(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw AdsbError.http(h.statusCode)
        }
        return d
    }
}

// MARK: - adsb.lol answers

/// The adsb.lol v2 API (readsb JSON). `/v2/point/{lat}/{lon}/{radius}`, radius
/// in nautical miles (checked 2026-09-23: 8 returned aircraft out to 7.1 NM).
public enum AdsbLol {
    /// Overridable with `defaults write dev.bentley.orecchino adsbURL <template>`
    /// ({lat} {lon} {radius} are substituted), plan §7 "keep it configurable".
    public static let defaultTemplate = "https://api.adsb.lol/v2/point/{lat}/{lon}/{radius}"
    /// 6 NM = 11.1 km, covering the default 10 km area (AdsbArea).
    public static let radiusNM = 6

    /// A radius in metres as whole nautical miles, rounded up (>= 1).
    public static func nm(forM m: Double) -> Int { max(1, Int(ceil(m / 1852.0 - 1e-9))) }

    public static var template: String {
        let t = UserDefaults.standard.string(forKey: "adsbURL") ?? ""
        return t.contains("{lat}") && t.contains("{lon}") ? t : defaultTemplate
    }

    public static func url(template: String = defaultTemplate, lat: Double, lon: Double,
                           radiusNM: Int = radiusNM) -> URL? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        // Two decimals (about 1 km) are plenty against a 6 NM radius, and the
        // request then says less about where this Mac is.
        let s = template
            .replacingOccurrences(of: "{lat}", with: String(format: "%.2f", lat))
            .replacingOccurrences(of: "{lon}", with: String(format: "%.2f", lon))
            .replacingOccurrences(of: "{radius}", with: String(radiusNM))
        return URL(string: s)
    }

    /// Every usable aircraft in an answer, stamped against `receivedMs` (the
    /// local receive time, never the server's clock): seenMs = receivedMs -
    /// seen_pos. Each entry is mapped onto the `traffic` wire object and read
    /// by TrafficWire.aircraft, so the Mac accepts exactly what a receiver
    /// would (no position, no hex, or a position older than 60 s: dropped).
    public static func parse(_ data: Data, receivedMs: Int64) throws -> [TrafficAircraft] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AdsbError.badAnswer
        }
        guard let list = o["ac"] as? [Any] else {
            // readsb answers {"ac":[]} or omits "ac" when nothing is in range.
            if o["now"] != nil || o["total"] != nil { return [] }
            throw AdsbError.badAnswer
        }
        var out: [TrafficAircraft] = []
        for item in list {
            guard let raw = item as? [String: Any] else { continue }
            let a = raw.filter { !($0.value is NSNull) }   // null reads as absent
            var w: [String: Any] = [:]
            w["hex"] = a["hex"]
            w["cs"] = a["flight"]
            w["ty"] = a["t"]
            w["lat"] = a["lat"]
            w["lon"] = a["lon"]
            if let g = a["alt_geom"] as? NSNumber { w["altg_m"] = g.doubleValue * TrafficRules.ftToM }
            // "ground" (or anything not a number) is no pressure altitude.
            if let b = a["alt_baro"] as? NSNumber, !TrafficWire.isBool(b) { w["altb_ft"] = b }
            if (a["alt_baro"] as? String) == "ground" { w["gnd"] = 1 }   // taxiing / parked
            w["gs_kt"] = a["gs"]
            w["trk"] = a["track"]
            w["vr_fpm"] = a["geom_rate"] ?? a["baro_rate"]
            w["sq"] = a["squawk"]
            w["em"] = a["emergency"]
            w["age_s"] = a["seen_pos"] ?? a["seen"]
            if let ac = TrafficWire.aircraft(from: w, nowMs: receivedMs) { out.append(ac) }
        }
        return out
    }
}

// MARK: - Where to look

/// The circle the ADS-B query covers (plan §8.5, conflict watch): this Mac
/// and the user's radius (5-30 km, 10 by default); when a live drone is more
/// than 3 km from the Mac, the centre moves and the radius grows so every
/// live drone has at least 9 km around it covered, up to 30 km. Aircraft
/// parsed beyond the radius are dropped.
public struct AdsbArea: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var radiusM: Double
    public var radiusNM: Int { AdsbLol.nm(forM: radiusM) }

    public static let radiusKey = "adsbRadiusKm"
    public static let defaultKm = 10.0, minKm = 5.0, maxKm = 30.0
    public static let droneFarM = 3000.0, droneCoverM = 9000.0

    /// The user's setting, clamped to 5-30 km.
    public static var settingKm: Double {
        let v = UserDefaults.standard.double(forKey: radiusKey)
        return v > 0 ? min(max(v, minKm), maxKm) : defaultKm
    }

    public static func make(mac: CLLocationCoordinate2D?, liveDrones: [CLLocationCoordinate2D],
                            baseKm: Double = settingKm) -> AdsbArea? {
        let base = min(max(baseKm, minKm), maxKm) * 1000
        let cap = maxKm * 1000
        if let m = mac, !liveDrones.contains(where: {
            TrafficRules.distanceM(m.latitude, m.longitude, $0.latitude, $0.longitude) > droneFarM }) {
            return AdsbArea(lat: m.latitude, lon: m.longitude, radiusM: base)
        }
        // Centre: the middle of the box around the Mac (when known) and the
        // live drones, in local metres; radius: each drone plus 9 km.
        let pts = (mac.map { [$0] } ?? []) + liveDrones
        guard let o = pts.first else { return nil }
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        for p in pts {
            let d = TrafficRules.offsetM(o.latitude, o.longitude, p.latitude, p.longitude)
            minX = min(minX, d.dx); maxX = max(maxX, d.dx); minY = min(minY, d.dy); maxY = max(maxY, d.dy)
        }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let lat = o.latitude + cy / TrafficRules.earthRM / TrafficRules.deg
        var lon = o.longitude + cx / (TrafficRules.earthRM * cos(o.latitude * TrafficRules.deg)) / TrafficRules.deg
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }   // as the Dart port does
        var r = base
        for d in liveDrones {
            r = max(r, TrafficRules.distanceM(lat, lon, d.latitude, d.longitude) + droneCoverM)
        }
        return AdsbArea(lat: lat, lon: lon, radiusM: min(r, cap))
    }
}

// MARK: - The service

@MainActor
@Observable
public final class TrafficService {
    public enum FeedStatus: Equatable {
        /// Not polling: the layer is off, or demo mode supplies the aircraft.
        case off
        /// Polling, but neither this Mac nor any drone has a position yet.
        case noPosition
        case waiting
        case ok
        /// The last fetch failed; the next try is at `retryMs` (backed off).
        case failed(String, retryMs: Int64)
    }

    /// The current set, nearest the reference first (<= 32, <= 30 km).
    public private(set) var aircraft: [TrafficAircraft] = []
    /// When the set was received (TrafficRules.nowMs clock); nil: no source.
    public private(set) var dataMs: Int64? = nil
    /// The last evaluation, ages rounded to whole seconds so that a tick that
    /// changes nothing on screen publishes nothing.
    public private(set) var result = TrafficResult.empty
    public private(set) var status: FeedStatus = .off

    public nonisolated static let intervalMs: Int64 = 10_000
    public nonisolated static let maxBackoffMs: Int64 = 160_000
    public nonisolated static let pushIntervalMs: Int64 = 10_000

    @ObservationIgnored private var state = TrafficState()
    @ObservationIgnored private let fetcher: any AdsbFetching
    @ObservationIgnored private let clock: @Sendable () -> Int64
    @ObservationIgnored public private(set) var failures = 0
    @ObservationIgnored public private(set) var nextFetchMs: Int64 = 0
    @ObservationIgnored public private(set) var inFlight = false
    @ObservationIgnored private var lastPushMs: Int64? = nil
    @ObservationIgnored private var pushedDataMs: Int64? = nil
    /// Bumped by clear() and pause(): a fetch that started before must not
    /// install its answer (e.g. real aircraft into a demo set).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var publishedSecond: Int64 = .min

    public init(fetcher: any AdsbFetching = URLSessionAdsbFetcher(),
                clock: @escaping @Sendable () -> Int64 = { TrafficRules.nowMs() }) {
        self.fetcher = fetcher
        self.clock = clock
    }

    /// The most urgent alert naming this aircraft.
    public func alert(forHex hex: String) -> TrafficAlert? { result.alert(forHex: hex) }

    public func clear() {
        generation += 1
        aircraft = []
        dataMs = nil
        result = .empty
        publishedSecond = .min
        state = TrafficState()
        failures = 0
        nextFetchMs = 0
        lastPushMs = nil
        pushedDataMs = nil
        if status != .off { status = .off }
    }

    /// Install a complete set (demo mode); dataMs is when it was received.
    public func updateAircraft(_ list: [TrafficAircraft], dataMs: Int64) {
        if list != aircraft { aircraft = list }
        self.dataMs = dataMs
    }

    /// Backed-off delay after `failures` consecutive failures: 20, 40, 80,
    /// 160, 160 ... s (10 s when there were none).
    public nonisolated static func backoffMs(failures: Int) -> Int64 {
        guard failures > 0 else { return intervalMs }
        let shift = min(failures, 5)
        return min(intervalMs << Int64(shift), maxBackoffMs)
    }

    /// The area of the last fetch.
    public private(set) var area: AdsbArea?

    /// Start a fetch when one is due. `area`: where to look; nil (no
    /// position anywhere) fetches nothing.
    public func pollIfDue(nowMs: Int64, area: AdsbArea?) {
        guard let ref = area else {
            if status != .noPosition { status = .noPosition }
            return
        }
        if status == .off || status == .noPosition { status = .waiting }
        guard !inFlight, nowMs >= nextFetchMs else { return }
        inFlight = true
        Task { @MainActor [weak self] in
            await self?.fetchNow(area: ref)
        }
    }

    /// Stop polling (layer off, or demo mode): data already held ages out.
    public func pause() {
        guard status != .off || failures != 0 || nextFetchMs != 0 else { return }
        generation += 1
        if status != .off { status = .off }
        nextFetchMs = 0
        failures = 0
    }

    /// One fetch, now. Success installs the set (merged with aircraft still
    /// under 60 s old that the answer left out) and schedules the next fetch
    /// 10 s on; a failure keeps the set and backs off.
    public func fetchNow(area ref: AdsbArea) async {
        inFlight = true
        defer { inFlight = false }
        let gen = generation
        let started = clock()
        guard let url = AdsbLol.url(template: AdsbLol.template, lat: ref.lat, lon: ref.lon,
                                    radiusNM: ref.radiusNM) else {
            status = .noPosition
            return
        }
        do {
            let data = try await fetcher.data(from: url)
            guard gen == generation else { return }
            let rx = clock()
            let fresh = try AdsbLol.parse(data, receivedMs: rx)
            install(fresh, receivedMs: rx, area: ref)
            failures = 0
            nextFetchMs = rx + Self.intervalMs
            status = .ok
        } catch {
            guard gen == generation else { return }
            failures += 1
            let now = max(clock(), started)
            nextFetchMs = now + Self.backoffMs(failures: failures)
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(why, retryMs: nextFetchMs)
        }
    }

    /// Keep the fresh answer, plus earlier aircraft it no longer lists while
    /// their positions are under 60 s old; then the 32 nearest within the
    /// area's radius (anything beyond it is dropped).
    func install(_ fresh: [TrafficAircraft], receivedMs rx: Int64, area ref: AdsbArea) {
        area = ref
        var byHex: [String: TrafficAircraft] = [:]
        for a in aircraft where a.ageS(nowMs: rx) <= TrafficRules.presentS { byHex[a.hex] = a }
        for a in fresh {
            if let old = byHex[a.hex], old.seenMs > a.seenMs { continue }   // keep the newer position
            byHex[a.hex] = a
        }
        var ranked: [(d: Double, a: TrafficAircraft)] = []
        for a in byHex.values {
            let d = TrafficRules.distanceM(ref.lat, ref.lon, a.lat, a.lon)
            if d <= ref.radiusM { ranked.append((d, a)) }
        }
        ranked.sort { l, r in l.d != r.d ? l.d < r.d : l.a.hex < r.a.hex }
        let list: [TrafficAircraft] = ranked.prefix(TrafficRules.maxAircraft).map { $0.a }
        if list != aircraft { aircraft = list }
        dataMs = rx
    }

    /// Evaluate the rules; publishes only when something shown has changed.
    public func tick(nowMs: Int64, observer: TrafficObserver, drones: [TrafficDrone]) {
        // Retention: a position older than 60 s is gone.
        if aircraft.contains(where: { $0.ageS(nowMs: nowMs) > TrafficRules.presentS }) {
            aircraft.removeAll { $0.ageS(nowMs: nowMs) > TrafficRules.presentS }
        }
        // (the observer feeds LOW: aircraft in UAS airspace)
        let r = TrafficRules.evaluate(drones: drones, aircraft: aircraft, observer: observer,
                                      dataMs: dataMs, nowMs: nowMs, state: &state)
        // Publish when an alert, the stale flag or a count changes, and
        // otherwise once per second for the ages: a 2 Hz clock must not
        // redraw every traffic view twice a second (D14).
        let second = Int64(floor(Double(nowMs) / 1000))
        if second != publishedSecond || Self.shape(r) != Self.shape(result) {
            var q = r
            q.dataAgeS = q.dataAgeS.map { floor($0 + 0.5) }
            for i in q.alerts.indices { q.alerts[i].ageS = floor(q.alerts[i].ageS + 0.5) }
            publishedSecond = second
            if q != result { result = q }
        }
    }

    /// What an evaluation says, less the ages and distances that move every tick.
    private static func shape(_ r: TrafficResult) -> [String] {
        [r.haveData ? "d" : "-", r.stale ? "s" : "-", "\(r.aircraftCount)"]
            + r.alerts.map { "\($0.id)|\($0.level.rawValue)|\($0.held)|\($0.text)|\($0.action)" }
    }

    /// The `traffic` / `traffic_done` lines for a receiver, when a push is due:
    /// at once for a set not yet pushed, else every 10 s while the set is
    /// under 60 s old (plan §8.1). nil: nothing to send now.
    public func hostLinesIfDue(nowMs: Int64, unixS: Int64) -> [String]? {
        guard let d = dataMs else { return nil }
        let age = TrafficRules.ageS(seenMs: d, nowMs: nowMs)
        guard age <= TrafficRules.presentS else { return nil }
        let newSet = pushedDataMs != d
        if !newSet, let last = lastPushMs, nowMs - last < Self.pushIntervalMs { return nil }
        lastPushMs = nowMs
        pushedDataMs = d
        let present = aircraft.filter { $0.ageS(nowMs: nowMs) <= TrafficRules.presentS }
        return TrafficWire.hostLines(aircraft: present, nowMs: nowMs, unixS: unixS, dataAgeS: age)
    }

    /// Forget what was pushed (new receiver): the next due check sends at once.
    public func resetPush() {
        lastPushMs = nil
        pushedDataMs = nil
    }
}

// MARK: - Nearest traffic for a drone (the detail card's row)

public struct NearestTraffic: Equatable, Sendable {
    public var aircraft: TrafficAircraft
    public var horizM: Double
    /// Aircraft minus drone, both geometric (WGS-84); nil when either is unknown.
    public var vertM: Double?
    /// true closing, false opening, nil when no velocity is known.
    public var closing: Bool?

    /// "UAL123 B738 · 1.1 km · +90 m · closing"
    public var text: String {
        var parts = [[aircraft.name, aircraft.type].filter { !$0.isEmpty }.joined(separator: " "),
                     "\(TrafficRules.kmText(horizM)) km",
                     vertM.map { v in let i = Int(floor(v + 0.5)); return i >= 0 ? "+\(i) m" : "\(i) m" }
                         ?? "height unknown"]
        if let c = closing { parts.append(c ? "closing" : "opening") }
        return parts.joined(separator: " · ")
    }

    /// The nearest aircraft present (<= 60 s) to a drone position.
    public static func find(lat: Double, lon: Double, altGeoM: Double?, speedMps: Double?,
                            headingDeg: Double?, aircraft: [TrafficAircraft],
                            nowMs: Int64) -> NearestTraffic? {
        var best: NearestTraffic?
        for a in aircraft where a.ageS(nowMs: nowMs) <= TrafficRules.presentS {
            let o = TrafficRules.offsetM(lat, lon, a.lat, a.lon)
            let h = (o.dx * o.dx + o.dy * o.dy).squareRoot()
            if let b = best, b.horizM <= h { continue }
            var vert: Double?
            if let ag = a.altGeomM, ag.isFinite, let dg = altGeoM, dg.isFinite, dg > -999 { vert = ag - dg }
            var closing: Bool?
            if let gs = a.gsMps, gs.isFinite, let trk = a.trackDeg, trk.isFinite {
                let dsp = (speedMps ?? 0).isFinite ? (speedMps ?? 0) : 0
                let dhd = (headingDeg ?? 0).isFinite ? (headingDeg ?? 0) : 0
                let wx = gs * sin(trk * TrafficRules.deg) - dsp * sin(dhd * TrafficRules.deg)
                let wy = gs * cos(trk * TrafficRules.deg) - dsp * cos(dhd * TrafficRules.deg)
                let rr = o.dx * wx + o.dy * wy          // range rate x range
                if abs(rr) > 1e-6 { closing = rr < 0 }
            }
            best = NearestTraffic(aircraft: a, horizM: h, vertM: vert, closing: closing)
        }
        return best
    }
}
