// TrafficNotifier.swift — traffic alerts as macOS notifications (plan §8.5).
//
// At most one notification per drone-aircraft pair (per aircraft for LOW and
// EMERGENCY) every 5 minutes (§8.2); time-sensitive for warnings. Only alerts
// the rules have just raised notify, never ones held by hysteresis. The
// wording follows §8.4: the rule's words as the title, then type, callsign,
// altitude, where it is and how old the report is.
// Words: never "collision", "conflict", "safe", "clear" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UserNotifications

/// Pure rate limiter, keyed per pair (or per aircraft + kind).
struct TrafficNotifyLimiter {
    static let windowMs: Int64 = 5 * 60 * 1000
    private(set) var lastMs: [String: Int64] = [:]

    static func key(_ a: TrafficAlert) -> String {
        a.kind.isPair ? "pair|\(a.droneId)|\(a.hex)" : "\(a.kind.name)|\(a.hex)"
    }

    /// True (and remembered) when this alert may notify now.
    mutating func allow(_ a: TrafficAlert, nowMs: Int64) -> Bool {
        let k = Self.key(a)
        if let last = lastMs[k], nowMs - last < Self.windowMs { return false }
        lastMs[k] = nowMs
        if lastMs.count > 256 { lastMs = lastMs.filter { nowMs - $0.value < Self.windowMs } }
        return true
    }
}

@MainActor
final class TrafficNotifier {
    private var limiter = TrafficNotifyLimiter()
    private var active = Set<String>()
    private var authorized = false
    private var asked = false

    /// UNUserNotificationCenter needs a bundle: `swift run` has none and would
    /// throw, so notifications only work from Orecchino.app.
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func requestAuthorization() {
        guard Self.available, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.authorized = ok } }
        }
    }

    /// Alerts to notify for now: newly raised (absent at the last call, not
    /// held), rate limit permitting. `active` carries the keys between calls.
    nonisolated static func toNotify(_ alerts: [TrafficAlert], active: inout Set<String>,
                                     limiter: inout TrafficNotifyLimiter, nowMs: Int64) -> [TrafficAlert] {
        let now = Set(alerts.map(TrafficNotifyLimiter.key))
        defer { active = now }
        var seen = Set<String>()
        return alerts.filter { a in
            let k = TrafficNotifyLimiter.key(a)
            guard !a.held, !active.contains(k), seen.insert(k).inserted else { return false }
            return limiter.allow(a, nowMs: nowMs)
        }
    }

    func consider(_ r: TrafficResult, aircraft: [TrafficAircraft], nowMs: Int64, simulated: Bool) {
        let due = Self.toNotify(r.alerts, active: &active, limiter: &limiter, nowMs: nowMs)
        guard Self.available, authorized, !due.isEmpty else { return }
        for a in due {
            let c = UNMutableNotificationContent()
            c.title = (simulated ? "SIMULATED: " : "") + Self.title(a)
            c.subtitle = a.text
            c.body = Self.body(a, aircraft: aircraft.first { $0.hex == a.hex })
            c.threadIdentifier = "traffic"
            c.interruptionLevel = a.level == .warning ? .timeSensitive : .active
            if a.level == .warning { c.sound = .default }
            let req = UNNotificationRequest(identifier: "traffic|" + TrafficNotifyLimiter.key(a),
                                            content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    /// What to do with the drone, first ("GIVE WAY: DESCEND AND LAND D9A03");
    /// the rule's words go in the subtitle.
    nonisolated static func title(_ a: TrafficAlert) -> String {
        let t = trafficAction(a)
        return t.isEmpty ? "TRAFFIC" : t
    }

    /// Metres as whole feet with a comma every three digits ("2,650").
    nonisolated static func feet(_ m: Double) -> String {
        let v = Int(floor(m / TrafficRules.ftToM + 0.5))
        var digits = String(abs(v)), out = ""
        while digits.count > 3 { out = "," + digits.suffix(3) + out; digits = String(digits.dropLast(3)) }
        return (v < 0 ? "-" : "") + digits + out
    }

    /// The geometry, then the aircraft and the data age: "AIRCRAFT 90 M
    /// ABOVE, 1.1 KM NE · B738 UAL123 · 2,650 ft · reported 6 s ago".
    nonisolated static func body(_ a: TrafficAlert, aircraft ac: TrafficAircraft?) -> String {
        var parts = [trafficGeometry(a)]
        let name = [ac?.type ?? "", ac?.callsign.isEmpty == false ? ac!.callsign : a.hex.uppercased()]
            .filter { !$0.isEmpty }.joined(separator: " ")
        parts.append(name)
        if ac?.onGround == true {
            parts.append("on the ground")
        } else if let b = ac?.altBaroM {
            parts.append("\(feet(b)) ft")
        } else if let g = ac?.altGeomM {
            parts.append("\(feet(g)) ft geometric")
        }
        parts.append("reported \(Int(floor(a.ageS + 0.5))) s ago")
        return parts.joined(separator: " · ")
    }
}
