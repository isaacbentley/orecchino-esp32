import Foundation
import CoreLocation
import Observation
import SwiftUI

struct DroneTrack: Identifiable {
    var id: String
    var uasId: String?
    var idType: Int?
    var uaType: Int?
    var macs: Set<String> = []
    var sources: Set<String> = []
    var rssi: Int = -127
    var channel: Int?
    var firstSeen: Date
    var lastSeen: Date
    var coordinate: CLLocationCoordinate2D?
    var altGeo: Double?
    var altBaro: Double?
    var height: Double?
    var speed: Double?
    var vspeed: Double?
    var heading: Double?
    var status: Int?
    var operatorCoord: CLLocationCoordinate2D?
    var operatorAlt: Double?
    var selfDesc: String?
    var operatorId: String?
    var trail: [CLLocationCoordinate2D] = []
    var msgCount: Int = 0
    var colorIndex: Int = 0
    var isDemo: Bool = false
    var phy: String?
    /// Which ODID message types have been received (evidence string).
    var seenBasic = false, seenLoc = false, seenSelf = false
    var seenSys = false, seenOp = false

    var title: String {
        if let u = uasId, !u.isEmpty { return u }
        return macs.sorted().first ?? id
    }
    var color: Color { Theme.tracks[colorIndex % Theme.tracks.count] }

    /// "BL·Y·" — uppercase letter per message type actually decoded
    /// (Basic, Location, Self ID, sYstem, Operator), dot when absent.
    var evidence: String {
        String([seenBasic ? "B" : "·", seenLoc ? "L" : "·", seenSelf ? "S" : "·",
                seenSys ? "Y" : "·", seenOp ? "O" : "·"])
    }

    var operatorDistance: Double? {
        guard let c = coordinate, let o = operatorCoord else { return nil }
        return CLLocation(latitude: c.latitude, longitude: c.longitude)
            .distance(from: CLLocation(latitude: o.latitude, longitude: o.longitude))
    }
}

struct FeedStats {
    var uptimeMs = 0
    var wifiFrames = 0
    var bleAdvs = 0
    var ridCount = 0
    var dropped = 0
    var channel = 0
    var bleOk = false
    var bleExt = false
    var lastHeartbeat: Date?
    var firmware: String?
}

@MainActor
@Observable
final class AppModel {
    var tracks: [String: DroneTrack] = [:]
    var selection: String?
    var stats = FeedStats()
    var serialStatus: SerialStatus = .searching
    var followAll = true
    var demoMode = false {
        didSet {
            if demoMode { demo.start(model: self) } else {
                demo.stop()
                tracks = tracks.filter { !$0.value.isDemo }
                if let s = selection, tracks[s] == nil { selection = nil }
            }
        }
    }
    /// Shared clock for ages / recency bars / staleness, ticked at 2 Hz so
    /// every time-derived value in the UI refreshes together.
    var now = Date()
    /// Bumped whenever a drone/operator position changes; the map's
    /// follow-all logic refits on it.
    var updateTick = 0
    let tfr = TFRService()
    var showTFR = true
    var selectedTFR: String?

    @ObservationIgnored private var macIndex: [String: String] = [:]
    @ObservationIgnored private var nextColor = 0
    @ObservationIgnored let serial = SerialManager()
    @ObservationIgnored private let demo = DemoFeed()
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private let decoder = JSONDecoder()

    /// Tracks older than this are dropped from the list entirely.
    static let expiry: TimeInterval = 600
    /// Tracks older than this render dimmed ("stale").
    static let staleAfter: TimeInterval = 30

    static let shared = AppModel()

    init() {
        serial.onLine = { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(line: line) }
            }
        }
        serial.onStatus = { [weak self] st in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.serialStatus = st }
            }
        }
        serial.start(preferred: nil)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.expireOld() }
            }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.now = Date() }
            }
        }
        tfr.start()
    }

    var trackList: [DroneTrack] {
        tracks.values.sorted { $0.firstSeen < $1.firstSeen }
    }

    func selectPort(_ path: String?) {
        serial.start(preferred: path)
    }

    func ingest(line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? decoder.decode(RidMessage.self, from: data) else { return }
        ingest(msg)
    }

    func ingest(_ msg: RidMessage, demo: Bool = false) {
        switch msg.type {
        case "hb":
            stats.uptimeMs = msg.up ?? stats.uptimeMs
            stats.wifiFrames = msg.wifi_frames ?? stats.wifiFrames
            stats.bleAdvs = msg.ble_advs ?? stats.bleAdvs
            stats.ridCount = msg.rid ?? stats.ridCount
            stats.dropped = msg.dropped ?? stats.dropped
            stats.channel = msg.ch ?? stats.channel
            stats.bleOk = msg.ble ?? stats.bleOk
            stats.bleExt = msg.ble_ext ?? stats.bleExt
            stats.lastHeartbeat = Date()
        case "boot":
            stats.firmware = "\(msg.fw ?? "?") \(msg.ver ?? "")"
            stats.lastHeartbeat = Date()
        case "rid":
            ingestRid(msg, demo: demo)
        default:
            break
        }
    }

    private func ingestRid(_ msg: RidMessage, demo: Bool) {
        guard let mac = msg.mac else { return }
        let now = Date()
        let uasId = msg.basic_id?.first(where: { !$0.uas_id.isEmpty })?.uas_id

        // Key by UAS ID when known so WiFi + BLE from one drone merge;
        // fall back to a per-MAC track until an ID shows up.
        let uasKey = uasId.map { "uas:\($0)" }
        let existingKey = macIndex[mac]
        let key = uasKey ?? existingKey ?? "mac:\(mac)"
        if let ek = existingKey, ek != key, let old = tracks.removeValue(forKey: ek) {
            if var dst = tracks[key] {
                // The MAC-keyed track turned out to be this UAS: merge, don't drop.
                dst.macs.formUnion(old.macs)
                dst.sources.formUnion(old.sources)
                dst.trail = old.trail + dst.trail
                if dst.trail.count > 600 { dst.trail.removeFirst(dst.trail.count - 600) }
                dst.firstSeen = min(dst.firstSeen, old.firstSeen)
                dst.msgCount += old.msgCount
                tracks[key] = dst
            } else {
                var moved = old
                moved.id = key
                tracks[key] = moved
            }
            if selection == ek { selection = key }
        }
        macIndex[mac] = key

        var t = tracks[key] ?? {
            defer { nextColor += 1 }
            return DroneTrack(id: key, firstSeen: now, lastSeen: now,
                              colorIndex: nextColor, isDemo: demo)
        }()
        t.lastSeen = now
        t.msgCount += 1
        t.macs.insert(mac)
        if let s = msg.src { t.sources.insert(s) }
        if let r = msg.rssi { t.rssi = r }
        if let c = msg.ch { t.channel = c }
        if let p = msg.phy { t.phy = p }
        if let b = msg.basic_id?.first {
            if let u = uasId { t.uasId = u }
            t.idType = b.id_type
            t.uaType = b.ua_type
            t.seenBasic = true
        }
        if let l = msg.loc {
            t.status = l.status
            t.seenLoc = true
            if Self.validCoord(l.lat, l.lon) {
                let c = CLLocationCoordinate2D(latitude: l.lat, longitude: l.lon)
                t.coordinate = c
                updateTick &+= 1
                if t.trail.last.map({ Self.moved($0, c) }) ?? true {
                    t.trail.append(c)
                    if t.trail.count > 600 { t.trail.removeFirst(t.trail.count - 600) }
                }
            }
            t.altGeo = l.alt_geo > -999 ? l.alt_geo : nil
            t.altBaro = l.alt_baro > -999 ? l.alt_baro : nil
            t.height = l.height > -999 ? l.height : nil
            t.speed = l.speed >= 0 ? l.speed : nil
            t.vspeed = l.vspeed
            t.heading = (l.dir >= 0 && l.dir <= 360) ? l.dir : nil
        }
        if let s = msg.self_id {
            t.selfDesc = s.desc
            t.seenSelf = true
        }
        if let s = msg.system {
            if Self.validCoord(s.op_lat, s.op_lon) {
                t.operatorCoord = CLLocationCoordinate2D(latitude: s.op_lat,
                                                         longitude: s.op_lon)
            }
            t.operatorAlt = s.op_alt > -999 ? s.op_alt : nil
            t.seenSys = true
        }
        if let o = msg.op_id, !o.id.isEmpty {
            t.operatorId = o.id
            t.seenOp = true
        }
        tracks[key] = t
    }

    private func expireOld() {
        let cutoff = Date().addingTimeInterval(-Self.expiry)
        let removed = tracks.filter { $0.value.lastSeen < cutoff && !$0.value.isDemo }
        guard !removed.isEmpty else { return }
        for k in removed.keys {
            tracks.removeValue(forKey: k)
            if selection == k { selection = nil }
        }
        macIndex = macIndex.filter { tracks[$0.value] != nil }
    }

    static func validCoord(_ lat: Double, _ lon: Double) -> Bool {
        if lat == 0 && lon == 0 { return false }
        return abs(lat) <= 90 && abs(lon) <= 180
    }
    static func moved(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) > 1.0
    }
}
