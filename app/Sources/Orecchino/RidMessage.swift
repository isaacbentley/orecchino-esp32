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

    // tile-sync replies (fs_f / fs_ls_done / ack / fs_ok / fs_err)
    var q: Int? = nil
    var p: String? = nil
    var s: Int? = nil
    var n: Int? = nil
    var msg: String? = nil
    var total: Int? = nil

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
    var msgs: Int? = nil
    var live: Int? = nil
    var clock: Bool? = nil

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
}
