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
    /// ODID height reference: 0 = above takeoff, 1 = above ground level.
    /// Kept so the height can be labelled with what it is measured from.
    var heightRef: Int?
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
    var authState: String?
    /// Wire format the receiver decoded: "ASTM F3411 v2" or "GB 46750-2025".
    var format: String?
    /// Wi-Fi beacon SSID, when the frame had one (DJI puts "RID-" + serial there).
    var ssid: String?
    /// The SSID named a serial that disagrees with the Basic ID message.
    var ssidMismatch = false
    /// Which ODID message types have been received (evidence string).
    var seenBasic = false, seenLoc = false, seenSelf = false
    var seenSys = false, seenOp = false

    var title: String {
        if let u = uasId, !u.isEmpty { return u }
        return macs.sorted().first ?? id
    }
    /// CTA-2063-A manufacturer decode, for serial-number IDs only.
    var manufacturer: String? {
        guard idType == 1, let u = uasId else { return nil }
        return MfrLookup.manufacturer(serial: u)
    }
    /// Model from the serial's first eight characters (DJI), when known.
    var model: String? {
        guard idType == 1, let u = uasId else { return nil }
        return UasModels.model(serial: u)
    }
    var color: Color { Theme.tracks[colorIndex % Theme.tracks.count] }

    /// "BL·Y·" — uppercase letter per message type actually decoded
    /// (Basic, Location, Self ID, sYstem, Operator), dot when absent.
    var evidence: String {
        String([seenBasic ? "B" : "·", seenLoc ? "L" : "·", seenSelf ? "S" : "·",
                seenSys ? "Y" : "·", seenOp ? "O" : "·"])
    }

    /// Aircraft-to-reported-operator distance. This is NOT the range from
    /// the receiver; see `range(from:)` for that.
    var operatorDistance: Double? {
        guard let c = coordinate, let o = operatorCoord else { return nil }
        return CLLocation(latitude: c.latitude, longitude: c.longitude)
            .distance(from: CLLocation(latitude: o.latitude, longitude: o.longitude))
    }

    /// Great-circle distance from `origin` (this Mac) to the aircraft.
    func range(from origin: CLLocationCoordinate2D?) -> Double? {
        guard let c = coordinate, let o = origin else { return nil }
        return CLLocation(latitude: o.latitude, longitude: o.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    /// Vital-cell label that says what the height is measured from.
    var heightLabel: String {
        switch heightRef {
        case 0:  return "HEIGHT ABOVE T/O"
        case 1:  return "HEIGHT AGL"
        default: return "REPORTED HEIGHT"
        }
    }
    /// Compact suffix for the sidebar row ("60 m AGL"); nil when unknown.
    var heightRefShort: String? {
        switch heightRef {
        case 0:  return "above T/O"
        case 1:  return "AGL"
        default: return nil
        }
    }

    var isEmergency: Bool { status == 3 }
    var isAuthInvalid: Bool { authState == "invalid" }
    /// True for states that must stay visible on every surface. Simulation
    /// is a badge, not an alert, so it is deliberately not included.
    var isAlerting: Bool { isEmergency || isAuthInvalid }
    /// Badges in display order: alerts first, then the simulation marker.
    var alerts: [TrackAlert] {
        var out: [TrackAlert] = []
        if isEmergency { out.append(.emergency) }
        if isAuthInvalid { out.append(.authInvalid) }
        if isDemo { out.append(.simulated) }
        return out
    }
}

/// Row / marker / card badges that are never allowed to truncate. The two
/// alert kinds carry distinct symbols so neither depends on colour alone.
enum TrackAlert: Hashable {
    case emergency, authInvalid, simulated

    var label: String {
        switch self {
        case .emergency:   return "EMERGENCY REPORTED"
        case .authInvalid: return "ID SIGNATURE INVALID"
        case .simulated:   return "SIMULATED"
        }
    }
    var symbol: String {
        switch self {
        case .emergency:   return "exclamationmark.triangle.fill"
        case .authInvalid: return "xmark.shield.fill"
        case .simulated:   return "sparkles"
        }
    }
    var help: String {
        switch self {
        case .emergency:
            return "The aircraft is broadcasting an emergency status"
        case .authInvalid:
            return "The ID signature failed verification; the identity cannot be trusted"
        case .simulated:
            return "Generated by demo mode, not a real broadcast"
        }
    }
}

/// One derived receiver-health state that every surface (toolbar badge,
/// status strip, sidebar empty state) reads, so they can never disagree.
enum ReceiverHealth: Equatable {
    /// No serial port is open.
    case searching
    /// A port is open but nothing has arrived on it yet.
    case waitingForData
    /// Heartbeats are arriving on time.
    case receiving
    /// A port is open but the heartbeat is overdue.
    case stalled

    /// Short form for the status strip and toolbar.
    var label: String {
        switch self {
        case .searching:      return "no receiver"
        case .waitingForData: return "waiting for data"
        case .receiving:      return "receiving"
        case .stalled:        return "no heartbeat"
        }
    }
    /// Sidebar empty-state title.
    var title: String {
        switch self {
        case .searching:      return "No receiver"
        case .waitingForData: return "Port open, waiting for data"
        case .receiving:      return "Listening for Remote ID"
        case .stalled:        return "Receiver went quiet"
        }
    }
    /// One line of guidance for the sidebar empty state.
    var explanation: String {
        switch self {
        case .searching:
            return "Plug the receiver in over USB; it shows up as /dev/cu.usbmodem…"
        case .waitingForData:
            return "The port is open but no heartbeat has arrived yet. "
                + "Auto-detect moves to the next port after a few seconds of silence."
        case .receiving:
            return "The receiver is streaming; no aircraft have been heard yet."
        case .stalled:
            return "The port is open but heartbeats stopped. "
                + "Reconnect the USB cable or pick another port."
        }
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
    /// The drone card and the TFR card are mutually exclusive: picking one
    /// closes the other, so at most one card ever covers the map.
    var selection: String? {
        didSet { if selection != nil { selectedTFR = nil } }
    }
    var stats = FeedStats()
    var serialStatus: SerialStatus = .searching
    /// Port the user picked explicitly; nil means auto-detect.
    var preferredPort: String?
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
    let tileSync = TileSync()
    let location = LocationService()
    /// False whenever the device needs a fresh home/TFR context push (on
    /// connect, first location fix, TFR refresh, and daily).
    var deviceCtxPushed = false
    var showTFR = true
    var selectedTFR: String? {
        didSet { if selectedTFR != nil { selection = nil } }
    }

    @ObservationIgnored private var macIndex: [String: String] = [:]
    @ObservationIgnored private var nextColor = 0
    @ObservationIgnored let serial = SerialManager()
    @ObservationIgnored private let demo = DemoFeed()
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private let decoder = JSONDecoder()

    /// Tracks older than this are dropped from the list entirely.
    static let expiry: TimeInterval = 600
    /// The single freshness policy: a track unheard for longer than this is
    /// "stale" on every surface (row, marker, card). 60 s matches the
    /// firmware's "active within the last minute".
    nonisolated static let staleAfter: TimeInterval = 60
    /// A heartbeat older than this means the receiver has gone quiet.
    nonisolated static let heartbeatTimeout: TimeInterval = 6

    static let shared = AppModel()

    // MARK: - Derived state shared by every surface

    /// Seconds since the track was last heard, against the shared clock.
    func age(of t: DroneTrack) -> TimeInterval {
        now.timeIntervalSince(t.lastSeen)
    }
    func isStale(_ t: DroneTrack) -> Bool {
        age(of: t) > Self.staleAfter
    }
    /// Range from this Mac's location to the aircraft, when both are known.
    func range(to t: DroneTrack) -> Double? {
        t.range(from: location.current)
    }

    nonisolated static func receiverHealth(serial: SerialStatus, lastHeartbeat: Date?,
                                           now: Date) -> ReceiverHealth {
        guard serial.isConnected else { return .searching }
        guard let hb = lastHeartbeat else { return .waitingForData }
        return now.timeIntervalSince(hb) < heartbeatTimeout ? .receiving : .stalled
    }
    var receiverHealth: ReceiverHealth {
        Self.receiverHealth(serial: serialStatus, lastHeartbeat: stats.lastHeartbeat,
                            now: now)
    }
    /// Toolbar wording: the port when it is healthy, port + problem otherwise.
    var receiverStatusText: String {
        switch receiverHealth {
        case .searching, .receiving:
            return serialStatus.label
        case .waitingForData, .stalled:
            return "\(serialStatus.label) · \(receiverHealth.label)"
        }
    }

    var simulatedCount: Int { tracks.values.filter(\.isDemo).count }
    nonisolated static func droneCountHeader(total: Int, simulated: Int) -> String {
        simulated > 0 ? "Drones — \(total) (\(simulated) simulated)"
                      : "Drones — \(total)"
    }
    var droneCountHeader: String {
        Self.droneCountHeader(total: tracks.count, simulated: simulatedCount)
    }
    nonisolated static func simulationBanner(count: Int) -> String {
        "SIMULATION ACTIVE — \(count) simulated aircraft"
    }

    /// `startServices: false` builds a model that opens no serial port and
    /// touches neither the network nor Core Location -- for unit tests that
    /// only exercise message ingestion.
    init(startServices: Bool = true) {
        serial.onLine = { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(line: line) }
            }
        }
        serial.onStatus = { [weak self] st in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A different port (or none) starts from "waiting for
                    // data"; a heartbeat from the old port must not vouch
                    // for the new one.
                    if st != self.serialStatus { self.stats.lastHeartbeat = nil }
                    self.serialStatus = st
                    if !st.isConnected {
                        self.deviceCtxPushed = false
                        if self.tileSync.running {
                            self.tileSync.cancel()
                        }
                    }
                }
            }
        }
        // A fresh TFR snapshot (first load, 15-minute refresh) goes straight
        // to a connected receiver; otherwise the next heartbeat pushes it.
        tfr.onUpdate = { [weak self] in
            guard let self else { return }
            self.deviceCtxPushed = true
            if self.serialStatus.isConnected {
                self.pushDeviceContext()
            } else {
                self.deviceCtxPushed = false
            }
        }
        guard startServices else { return }
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
        serial.start(preferred: nil)
        tfr.start()
        location.start()
        // Daily context refresh (TFRs age out; home may move).
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.deviceCtxPushed = false }
            }
        }
        // Test hook: ORECCHINO_AUTOSYNC=1 starts a tile sync once the port
        // rotation has had time to settle on the JSON feed.
        if ProcessInfo.processInfo.environment["ORECCHINO_AUTOSYNC"] != nil {
            Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppModel.shared.tileSync.start() }
                }
            }
        }
    }

    var trackList: [DroneTrack] {
        tracks.values.sorted { $0.firstSeen < $1.firstSeen }
    }

    func selectPort(_ path: String?) {
        preferredPort = path
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
            if !deviceCtxPushed {
                deviceCtxPushed = true
                pushDeviceContext()
            }
        case "boot":
            stats.firmware = "\(msg.fw ?? "?") \(msg.ver ?? "")"
            stats.lastHeartbeat = Date()
        case "rid":
            ingestRid(msg, demo: demo)
        case "ack", "fs_ok", "fs_err", "fs_f", "fs_ls_done", "fs_info":
            tileSync.handle(msg)
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
        if let ek = existingKey, ek != key, ek.hasPrefix("mac:"), let old = tracks.removeValue(forKey: ek) {
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
        let sinceLast = now.timeIntervalSince(t.lastSeen)
        t.lastSeen = now
        t.msgCount += 1
        t.macs.insert(mac)
        if let s = msg.src { t.sources.insert(s) }
        if let r = msg.rssi { t.rssi = r }
        if let c = msg.ch { t.channel = c }
        if let p = msg.phy { t.phy = p }
        // Strings from the feed are capped at what the receivers can send.
        if let f = msg.fmt { t.format = f == "gb46750" ? "GB 46750-2025" : String(f.prefix(16)) }
        else if let v = msg.proto { t.format = "ASTM F3411 v\(v)" }
        if let s = msg.ssid, !s.isEmpty { t.ssid = String(s.prefix(32)) }
        if let m = msg.ssid_id_match { t.ssidMismatch = !m }
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
                if let last = t.trail.last, !Self.plausibleStep(last, c, elapsed: sinceLast) {
                    // A jump no aircraft makes between two broadcasts: a bad
                    // fix or a spoofed frame. Start the trail over rather
                    // than drawing a line across the map.
                    t.trail = [c]
                } else if t.trail.last.map({ Self.moved($0, c) }) ?? true {
                    t.trail.append(c)
                    if t.trail.count > 600 { t.trail.removeFirst(t.trail.count - 600) }
                }
            }
            t.altGeo = l.alt_geo > -999 ? l.alt_geo : nil
            t.altBaro = l.alt_baro > -999 ? l.alt_baro : nil
            t.height = l.height > -999 ? l.height : nil
            t.heightRef = (0...1).contains(l.height_ref) ? l.height_ref : nil
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
        if let a = msg.auth { t.authState = a.state }
        if let o = msg.op_id, !o.id.isEmpty {
            t.operatorId = o.id
            t.seenOp = true
        }
        tracks[key] = t
    }

    /// The clock command a receiver understands: whole UTC seconds. The
    /// boards have no network, so this and the flash script are how a
    /// receiver's clock gets set; the T5 writes it to its RTC chip.
    nonisolated static func setTimeCommand(now: Date) -> String {
        #"{"cmd":"set_time","utc":\#(Int(now.timeIntervalSince1970))}"#
    }

    /// Push the time, operator location and nearby TFR polygons to the
    /// receiver so it can keep its clock, range contacts and buzz on TFR
    /// incursions. Boards without a clock command ignore set_time.
    private func pushDeviceContext() {
        serial.send(Self.setTimeCommand(now: Date()))
        let home = location.current
        if let h = home {
            serial.send(String(format: #"{"cmd":"set_home","lat":%.6f,"lon":%.6f}"#,
                               h.latitude, h.longitude))
        }
        if tfr.zones.isEmpty {
            // A fetched-but-empty snapshot means the restrictions the device
            // holds have ended; only a fetch that never completed says nothing.
            if case .loaded = tfr.status {
                serial.send(#"{"cmd":"tfr_clear"}"#)
            }
            return
        }
        let ref = home ?? CLLocationCoordinate2D(latitude: 37.7749,
                                                 longitude: -122.4194)
        let refLoc = CLLocation(latitude: ref.latitude, longitude: ref.longitude)
        serial.send(#"{"cmd":"tfr_clear"}"#)
        var sent = 0
        for z in tfr.zones {
            guard sent < 16 else { break }
            let d = refLoc.distance(from: CLLocation(latitude: z.centroid.latitude,
                                                     longitude: z.centroid.longitude))
            guard d < 200_000 else { continue }
            let ring = z.outerRing
            let step = max(1, Int(ceil(Double(ring.count) / 24.0)))
            let pts = stride(from: 0, to: ring.count, by: step).map { ring[$0] }
            guard pts.count >= 3 else { continue }
            let ptsStr = pts
                .map { String(format: "[%.5f,%.5f]", $0.latitude, $0.longitude) }
                .joined(separator: ",")
            let id = String(z.notam.prefix(14))
            serial.send(#"{"cmd":"tfr_add","id":"\#(id)","pts":[\#(ptsStr)]}"#)
            sent += 1
        }
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

    /// The band around 0,0 that DJI encoders emit for "no fix" (small
    /// non-zero values, open ocean in the Gulf of Guinea) is no position;
    /// the receivers apply the same rule.
    nonisolated static func validCoord(_ lat: Double, _ lon: Double) -> Bool {
        if abs(lat) < 5 && abs(lon) < 5 { return false }
        return abs(lat) <= 90 && abs(lon) <= 180
    }
    /// Farthest an aircraft can plausibly move in `elapsed` seconds: fix
    /// noise plus a speed no UAS reaches, so a long dropout still allows
    /// the repositioning leg while a teleport between two broadcasts does
    /// not.
    nonisolated static func stepAllowance(elapsed: TimeInterval) -> Double {
        300 + 120 * max(0, elapsed)
    }
    nonisolated static func plausibleStep(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                          elapsed: TimeInterval) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            <= stepAllowance(elapsed: elapsed)
    }
    nonisolated static func moved(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) > 1.0
    }
}
