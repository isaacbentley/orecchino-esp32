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

    // heartbeat / boot fields
    var up: Int? = nil
    var wifi_frames: Int? = nil
    var ble_advs: Int? = nil
    var rid: Int? = nil
    var dropped: Int? = nil
    var ble: Bool? = nil
    var ble_ext: Bool? = nil
    var heap: Int? = nil
    var fw: String? = nil
    var ver: String? = nil
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
    var vspeed: Double
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
    static let statuses = ["Undeclared", "On ground", "Airborne", "Emergency", "RID failure"]

    static func uaType(_ i: Int?) -> String {
        guard let i, i >= 0, i < uaTypes.count else { return "Unknown" }
        return uaTypes[i]
    }
    static func idType(_ i: Int?) -> String {
        guard let i, i >= 0, i < idTypes.count else { return "?" }
        return idTypes[i]
    }
    static func status(_ i: Int?) -> String {
        guard let i, i >= 0, i < statuses.count else { return "Unknown" }
        return statuses[i]
    }
}
