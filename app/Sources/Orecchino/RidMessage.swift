import Foundation

// JSON line schema emitted by orecchino_fw over USB serial.

struct RidMessage: Decodable {
    var type: String
    var src: String? = nil
    var mac: String? = nil
    var rssi: Int? = nil
    var ch: Int? = nil
    var phy: String? = nil   // BLE: "1m" | "2m" | "coded" (BT5 long range)
    var basic_id: [BasicId]? = nil
    var loc: Loc? = nil
    var self_id: SelfId? = nil
    var system: SystemMsg? = nil
    var op_id: OpId? = nil
    var auth: AuthInfo? = nil
    var fmt: String? = nil        // "gb46750" when the frame was GB 46750-2025; absent for ODID
    var proto: Int? = nil         // ODID protocol version from the message header
    var ssid: String? = nil       // Wi-Fi beacon SSID, when the frame had one
    var ssid_id_match: Bool? = nil   // the SSID's "RID-" serial agrees with the Basic ID
    // rid and log: inside a TFR the host pushed (rid: only once TFRs have been
    // pushed and there is a position; log: at the end), and which one.
    var in_tfr: Bool? = nil
    var tfr_id: String? = nil

    // tile-sync replies (fs_f / fs_ls_done / ack / fs_ok / fs_err)
    var q: Int? = nil
    var p: String? = nil
    var s: Int? = nil
    var n: Int? = nil
    var msg: String? = nil
    var total: Int? = nil
    // fs_stat (tile_store.h): bytes, and the board's own plan limits
    var used: Int? = nil
    var free: Int? = nil
    var reserve: Int? = nil
    var tiles: Int? = nil
    var tile_bytes: Int? = nil
    var avg_tile: Int? = nil
    var capacity: Int? = nil
    var max_radius_km: Double? = nil

    // match log records (log / log_done), see DeviceLog. `seq`/`i` are null
    // for a contact still live; log_done's `next` is the cursor for the next
    // {"cmd":"log_get","since":next}, `oldest` the lowest seq still held.
    var seq: Int? = nil
    var i: Int? = nil
    var next: Int? = nil
    var oldest: Int? = nil
    var active: Bool? = nil
    var uas: String? = nil
    var srcs: Int? = nil
    var fmts: Int? = nil
    var ua_type: Int? = nil
    var first: Int? = nil
    var last: Int? = nil
    var dur: Int? = nil
    var lat: Double? = nil
    var lon: Double? = nil
    var max_h: Int? = nil
    var peak_rssi: Int? = nil
    var auth_state: String? = nil
    var tfr: Bool? = nil
    var emerg: Bool? = nil
    // log v3: the last System message's classification, as SystemMsg has it
    // on a rid line (class_type 1 = EU, and only then cat_eu / class_eu).
    var class_type: Int? = nil
    var cat_eu: Int? = nil
    var class_eu: Int? = nil
    var msgs: Int? = nil
    var live: Int? = nil
    var clock: Bool? = nil
    /// log_done: "dropped" when the receiver lost lines of this dump (a BLE
    /// or USB drop) and `next` is the `since` that was asked for: read
    /// again later from the same cursor.
    var err: String? = nil
    /// log_done / log_cleared: which log this is; kept on the board and
    /// bumped by a clear, so a cursor from another log is known for stale.
    var log_id: Int? = nil

    // heartbeat / boot fields
    var up: Int? = nil
    var wifi_frames: Int? = nil
    var ble_advs: Int? = nil
    var rid: Int? = nil
    var dropped: Int? = nil
    var ble: Bool? = nil
    var ble_ext: Bool? = nil
    var fw: String? = nil
    var ver: String? = nil
    var board: String? = nil
    var wifi: Bool? = nil          // boot: the Wi-Fi sniffer started
    var caps: [String]? = nil      // boot/hb, when the firmware sends it (see AppModel.receiverTakesTraffic)
    var ble_drop: Int? = nil       // hb, optional: BLE lines dropped
    var ble_rx_drop: Int? = nil    // hb, optional: BLE host lines dropped
    var usb_drop: Int? = nil       // hb, optional: lines dropped toward USB while the host did not read
    var rx_stack: Int? = nil       // hb, optional: decode task's least free stack (bytes)
}

struct BasicId: Decodable {
    var id_type: Int
    var ua_type: Int
    var uas_id: String
}

struct Loc: Decodable {
    var status: Int
    var lat: Double
    var lon: Double
    var alt_geo: Double
    var alt_baro: Double
    var height: Double
    var height_ref: Int
    var speed: Double
    var vspeed: Double?   // omitted when the broadcast marks it unknown
    var dir: Double
    var ts: Double
    // Accuracy codes, raw ASTM F3411 enums (see RidNames); omitted when unknown.
    var h_acc: Int? = nil
    var v_acc: Int? = nil
    var baro_acc: Int? = nil
    var spd_acc: Int? = nil
    var ts_acc: Int? = nil
}

struct SelfId: Decodable {
    var desc_type: Int
    var desc: String
}

struct SystemMsg: Decodable {
    var op_lat: Double
    var op_lon: Double
    var op_alt: Double
    var op_loc_type: Int
    var area_count: Int
    var ts: Int
    // ODID only (not GB 46750). Radius in m; ceiling and floor in m,
    // omitted when unknown. Classification raw: class_type 1 = EU, and only
    // then cat_eu / class_eu; each omitted when undeclared.
    var area_radius: Double? = nil
    var area_ceiling: Double? = nil
    var area_floor: Double? = nil
    var class_type: Int? = nil
    var cat_eu: Int? = nil
    var class_eu: Int? = nil
}

/// Authentication (ODID message type 2) as reported by the receiver.
/// `state` is one of id_valid / invalid / partial / unknown_key / test_key /
/// none. test_key: signed with the public test key (the bench beacon), shown
/// neutrally as "TEST KEY", never as a verified identity.
struct AuthInfo: Decodable {
    var type: Int
    var len: Int
    var pages: Int
    var state: String
    /// Page 0's timestamp, seconds since 2019-01-01 00:00 UTC; omitted until page 0 arrives.
    var auth_ts: Int? = nil
}

struct OpId: Decodable {
    var id_type: Int
    var id: String
}

enum RidNames {
    static let uaTypes = [
        "Unknown", "Aeroplane", "Multirotor", "Gyroplane", "Hybrid lift",
        "Ornithopter", "Glider", "Kite", "Free balloon", "Captive balloon",
        "Airship", "Parachute", "Rocket", "Tethered", "Ground obstacle", "Other",
    ]
    static let idTypes = ["None", "Serial", "CAA Reg.", "UTM UUID", "Session ID"]
    /// Status 3 is always "Emergency reported": it is what the aircraft
    /// broadcast, never a verified fact, and it must not collapse to one word.
    static let statuses = ["Undeclared", "On ground", "Airborne", "Emergency reported",
                           "RID failure"]

    static func uaType(_ i: Int?) -> String {
        guard let i, i >= 0, i < uaTypes.count else { return "Unknown" }
        return uaTypes[i]
    }
    static func idType(_ i: Int?) -> String {
        guard let i, i >= 0, i < idTypes.count else { return "?" }
        return idTypes[i]
    }
    /// Human label for an authentication state, phrased so it cannot be
    /// read as "this drone is where it says it is".
    static func authLabel(_ s: String?) -> String? {
        switch s {
        case "id_valid":    return "ID signature valid"
        case "invalid":     return "ID signature INVALID"
        case "partial":     return "pages incomplete"
        case "unknown_key": return "signed, key not trusted"
        case "test_key":    return "TEST KEY"
        case "none", nil:   return nil
        default:            return s
        }
    }

    static func status(_ i: Int?) -> String {
        guard let i, i >= 0, i < statuses.count else { return "Unknown" }
        return statuses[i]
    }

    // ASTM F3411 accuracy enums (index = code; 0 is unknown and never sent).
    static let hAccuracies = ["unknown", "< 18.5 km", "< 7.4 km", "< 3.7 km", "< 1.9 km",
                              "< 926 m", "< 556 m", "< 185 m", "< 93 m", "< 30 m",
                              "< 10 m", "< 3 m", "< 1 m"]
    static let vAccuracies = ["unknown", "< 150 m", "< 45 m", "< 25 m", "< 10 m", "< 3 m", "< 1 m"]
    static let speedAccuracies = ["unknown", "< 10 m/s", "< 3 m/s", "< 1 m/s", "< 0.3 m/s"]

    /// "< 3 m (11)": the meaning and the raw code; a reserved code says so.
    static func accuracy(_ code: Int?, _ table: [String]) -> String? {
        guard let code else { return nil }
        guard code > 0, code < table.count else { return "reserved (\(code))" }
        return "\(table[code]) (\(code))"
    }
    static func hAccuracy(_ c: Int?) -> String? { accuracy(c, hAccuracies) }
    static func vAccuracy(_ c: Int?) -> String? { accuracy(c, vAccuracies) }
    static func speedAccuracy(_ c: Int?) -> String? { accuracy(c, speedAccuracies) }
    /// Timestamp accuracy: code × 0.1 s (1...15).
    static func timeAccuracy(_ c: Int?) -> String? {
        guard let c else { return nil }
        guard (1...15).contains(c) else { return "reserved (\(c))" }
        return String(format: "%.1f s (%d)", Double(c) / 10, c)
    }

    static let euCategories = ["undeclared", "Open", "Specific", "Certified"]
    /// "EU · Specific · C2". EU class codes 1...7 are classes C0...C6.
    static func classification(type: Int?, category: Int?, cls: Int?) -> String? {
        guard let type else { return nil }
        guard type == 1 else { return "type \(type)" }
        var parts = ["EU"]
        if let c = category {
            parts.append(c < euCategories.count ? euCategories[c] : "category \(c)")
        }
        if let c = cls { parts.append((1...7).contains(c) ? "C\(c - 1)" : "class \(c)") }
        return parts.joined(separator: " · ")
    }

    /// Seconds since 2019-01-01 00:00 UTC (the ODID epoch) as a date.
    static func odidDate(_ s: Int) -> Date { Date(timeIntervalSince1970: 1_546_300_800 + Double(s)) }
}
