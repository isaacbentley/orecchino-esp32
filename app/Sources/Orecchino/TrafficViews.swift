// TrafficViews.swift — ADS-B conflict watch on the Mac (plan §8.5). The app
// is about drones: ADS-B is only for spotting and resolving conflicts with
// them, so an aircraft is drawn only while it is in an alert, and every
// alert leads with what to do with the drone (the rules' `action`), then the
// geometry (`resolution`). Every level has its own symbol, so no state is
// told by colour alone; every alert shows its data age.
// Words: never "collision", "safe", "clear" (other than the instruction
// "KEEP CLEAR OF"), "conflict resolved" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MapKit
import CoreLocation

/// Alert colour by level.
func trafficColor(_ level: TrafficLevel?) -> Color {
    switch level ?? .none {
    case .warning:  return Theme.danger
    case .caution:  return Theme.warn
    default:        return Theme.muted
    }
}

/// A distinct symbol per level, so the level reads without colour.
func trafficSymbol(_ level: TrafficLevel?) -> String {
    switch level ?? .none {
    case .warning:  return "exclamationmark.triangle.fill"
    case .caution:  return "exclamationmark.circle.fill"
    default:        return "airplane"
    }
}

/// "1.1 km"
func trafficKm(_ m: Double?) -> String { m.map { "\(TrafficRules.kmText($0)) km" } ?? "--" }
/// "+90 m", or "height unknown"
func trafficVert(_ m: Double?) -> String {
    guard let m else { return "height unknown" }
    let v = Int(floor(m + 0.5))
    return v >= 0 ? "+\(v) m" : "\(v) m"
}
/// "2,650 ft" from a pressure altitude in metres.
func trafficFeet(_ m: Double?) -> String? {
    m.map { "\(TrafficNotifier.feet($0)) ft" }
}
/// ▲ / ▼ beyond ±200 ft/min, else nothing.
func trafficTrend(_ vs: Double?) -> String {
    guard let vs, abs(vs) >= 1.0 else { return "" }
    return vs > 0 ? " ▲" : " ▼"
}

/// What to do, first: "GIVE WAY: DESCEND AND LAND D9A03" (the rule's words
/// when an alert carries no action).
func trafficAction(_ a: TrafficAlert) -> String { a.action.isEmpty ? a.text : a.action }

/// The geometry after the action: "AIRCRAFT 90 M ABOVE, 640 M NE, CLOSING IN 12 S".
func trafficGeometry(_ a: TrafficAlert) -> String {
    if !a.action.isEmpty, a.resolution.hasPrefix(a.action + "; ") {
        return String(a.resolution.dropFirst(a.action.count + 2))
    }
    if !a.resolution.isEmpty, a.resolution != a.action { return a.resolution }
    var parts = [trafficKm(a.horizM)]
    if a.kind.isPair { parts.append(a.vertM.map { "Δ " + trafficVert($0) } ?? "height unknown") }
    return parts.joined(separator: " · ")
}

/// The short tag on a drone's row: "GIVE WAY", "KEEP CLEAR", "BE READY".
func trafficTag(_ a: TrafficAlert) -> String {
    let act = trafficAction(a)
    if let c = act.firstIndex(of: ":") { return String(act[..<c]) }
    return act.split(separator: " ").prefix(2).joined(separator: " ")
}

/// "UAL123 B738"
func trafficAircraftName(_ a: TrafficAlert, _ ac: TrafficAircraft?) -> String {
    [a.callsign.isEmpty ? a.hex.uppercased() : a.callsign, ac?.type ?? ""]
        .filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - Alert strip (sidebar, drone card)

/// One alert, action first: what to do with the drone, then where the
/// aircraft is, then the rule's words, the aircraft, the data age and "Show"
/// (frames the drone and the aircraft).
struct TrafficAlertRow: View {
    @Environment(AppModel.self) private var model
    let alert: TrafficAlert

    var body: some View {
        let color = trafficColor(alert.level)
        let ac = model.traffic.aircraft.first { $0.hex == alert.hex }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: trafficSymbol(alert.level))
                    .font(.system(size: 11, weight: .bold))
                Text(trafficAction(alert))
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(color)
            Text(trafficGeometry(alert))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(alert.text) · \(trafficAircraftName(alert, ac))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(TrafficRules.ageWords(alert.ageS) + (alert.held ? " · held" : ""))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .help(alert.held ? "Kept until the pair is beyond 1.3 km or 200 m for 20 s" : "")
                Spacer(minLength: 4)
                Button("Show") { model.focus(on: model.coordinates(of: alert)) }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .semibold))
                    .help("Centre the map on the drone and the aircraft")
            }
        }
        .padding(8)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.select(alert: alert) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.level.name): \(trafficAction(alert)). \(trafficGeometry(alert)). "
                            + "\(alert.text), \(trafficAircraftName(alert, ac)). \(TrafficRules.ageWords(alert.ageS))")
        .accessibilityAction(named: "Show on map") { model.focus(on: model.coordinates(of: alert)) }
    }
}

/// The drone row's tag while the drone is in an alert ("GIVE WAY"). Shape
/// and words carry the level, not only the colour.
struct TrafficDroneTag: View {
    let alert: TrafficAlert
    var body: some View {
        let color = trafficColor(alert.level)
        HStack(spacing: 3) {
            Image(systemName: trafficSymbol(alert.level)).font(.system(size: 8, weight: .bold))
            Text(trafficTag(alert)).font(.system(size: 9, weight: .bold))
        }
        .lineLimit(1)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(color.opacity(0.20), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 0.8))
        .foregroundStyle(color)
        .help(trafficAction(alert))
        .accessibilityLabel("ADS-B alert: \(trafficAction(alert))")
    }
}

// MARK: - Map marker (only for aircraft in an alert)

/// The system airplane glyph rotated to the track, outlined only: a drone's
/// marker is a filled disc, an aircraft never is. Label: callsign, pressure
/// altitude and a climb/descent arrow.
struct TrafficMarker: View {
    let aircraft: TrafficAircraft
    let alert: TrafficAlert?
    let selected: Bool

    var body: some View {
        let color = alert == nil ? Theme.muted : trafficColor(alert?.level)
        VStack(spacing: 1) {
            ZStack {
                if let alert {
                    Circle()
                        .stroke(color, style: StrokeStyle(lineWidth: alert.level == .warning ? 2 : 1.5,
                                                          dash: alert.level == .warning ? [] : [3, 3]))
                        .frame(width: 30, height: 30)
                }
                if selected {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: 36, height: 36)
                }
                Image(systemName: "airplane")
                    .font(.system(size: selected ? 19 : 16, weight: .semibold))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.9), radius: 1.5)
                    .rotationEffect(.degrees((aircraft.trackDeg ?? 90) - 90))
            }
            .frame(width: 36, height: 36)
            Text("\(aircraft.name)\(trafficFeet(aircraft.altBaroM).map { " " + $0 } ?? "")\(trafficTrend(aircraft.vsMps))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(color)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aircraft \(aircraft.name)"
                            + (trafficFeet(aircraft.altBaroM).map { ", \($0)" } ?? "")
                            + (aircraft.trackDeg.map { ", track \(Int($0)) degrees" } ?? "")
                            + (alert.map { ", \(trafficAction($0))" } ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

/// Where the aircraft will be in `seconds` on its reported track and speed
/// (the dashed projection); nil without both.
func trafficProjection(_ a: TrafficAircraft, seconds: Double = 60) -> CLLocationCoordinate2D? {
    guard let gs = a.gsMps, gs.isFinite, gs > 0.5, let trk = a.trackDeg, trk.isFinite else { return nil }
    let d = gs * seconds
    let dn = d * cos(trk * TrafficRules.deg), de = d * sin(trk * TrafficRules.deg)
    let lat = a.lat + dn / TrafficRules.earthRM / TrafficRules.deg
    let lon = a.lon + de / (TrafficRules.earthRM * cos(a.lat * TrafficRules.deg)) / TrafficRules.deg
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

// MARK: - Separation bridge

/// Labels the line from a drone (or, for traffic near the user, this Mac)
/// to the aircraft of an alert, with that alert's own numbers.
struct SeparationBridge: View {
    let alert: TrafficAlert

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trafficSymbol(alert.level))
                .font(.system(size: 9, weight: .bold))
            Text(trafficKm(alert.horizM))
            if alert.kind.isPair {
                Text("·")
                Text(alert.vertM.map { "Δ " + trafficVert($0) } ?? "height unknown")
            }
        }
        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(trafficColor(alert.level), in: Capsule())
        .foregroundStyle(.white)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((alert.droneId.isEmpty ? "Distance" : "Separation from drone \(TrafficRules.droneLabel(alert.droneId))")
                            + " to \(alert.callsign.isEmpty ? alert.hex.uppercased() : alert.callsign): "
                            + "\(trafficKm(alert.horizM))"
                            + (alert.kind.isPair ? ", " + (alert.vertM.map { "vertical \(trafficVert($0))" } ?? "height unknown") : ""))
    }
}

// MARK: - Conflict watch status (top of the map)

/// Whether the conflict watch is running, and how old its data is (the
/// rules' summary); warns when stale, failing or without a position.
struct TrafficStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let r = model.traffic.result
        let status = model.traffic.status
        let problem: String? = {
            switch status {
            case .noPosition:
                return "no position to look around"
            case .failed(let why, let retry):
                let s = max(0, Int((retry - TrafficRules.nowMs(model.now) + 999) / 1000))
                return "ADS-B fetch failed (\(why)), retry in \(s) s"
            default:
                return nil
            }
        }()
        let warn = r.stale || problem != nil
        HStack(spacing: 6) {
            Image(systemName: warn ? "exclamationmark.triangle.fill"
                  : r.alerts.isEmpty ? "eye" : trafficSymbol(r.highest))
            Text(model.demoMode ? "SIMULATED · " + r.summary : r.summary)
            if let problem { Text("· \(problem)") }
        }
        .font(.system(size: 11, weight: warn ? .semibold : .regular, design: .monospaced))
        .foregroundStyle(warn ? Theme.warn : r.alerts.isEmpty ? Theme.muted : trafficColor(r.highest))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .help("Manned aircraft from adsb.lol within "
              + "\(model.traffic.area.map { String(format: "%.0f km", $0.radiusM / 1000) } ?? "the set radius"), "
              + "checked against the drones. Not every aircraft broadcasts ADS-B, and the feed "
              + "has gaps and delay.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Aircraft card (from a marker)

struct TrafficCard: View {
    @Environment(AppModel.self) private var model
    let aircraft: TrafficAircraft
    let alert: TrafficAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: the action, then the geometry.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: alert.map { trafficSymbol($0.level) } ?? "airplane")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(trafficColor(alert?.level))
                Text(alert.map(trafficAction) ?? "ADS-B AIRCRAFT")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(alert == nil ? Color.primary : trafficColor(alert?.level))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    model.selectedTraffic = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            if let alert {
                Text(trafficGeometry(alert))
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                Text(alert.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }

            Divider()

            // Callsign, type and address
            HStack(alignment: .firstTextBaseline) {
                Text(aircraft.name)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                Text([aircraft.type, aircraft.hex.uppercased()].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(TrafficRules.ageWords(aircraft.ageS(nowMs: TrafficRules.nowMs(model.now))))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ALTITUDE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(aircraft.onGround ? "on ground" : (trafficFeet(aircraft.altBaroM) ?? "--"))
                        .font(.system(size: 13, design: .monospaced))
                }
                .help("Pressure altitude as reported; never compared with drone heights")
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPEED / TRACK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    let spd = aircraft.gsMps.map { "\(Int(floor($0 / TrafficRules.ktToMps + 0.5))) kt" } ?? "--"
                    let trk = aircraft.trackDeg.map { String(format: "%03.0f°", $0) } ?? "--"
                    Text("\(spd) / \(trk)")
                        .font(.system(size: 13, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("VERTICAL RATE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let vs = aircraft.vsMps {
                        HStack(spacing: 3) {
                            Image(systemName: vs < 0 ? "arrow.down" : "arrow.up")
                            Text("\(Int(floor(abs(vs) * 60 / TrafficRules.ftToM + 0.5))) fpm")
                        }
                        .font(.system(size: 13, design: .monospaced))
                    } else {
                        Text("--")
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Positions as reported, not a prediction.")
                Text("Not every aircraft broadcasts ADS-B.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: MapPane.cardWidth, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(alert == nil ? Color.secondary.opacity(0.2) : trafficColor(alert?.level), lineWidth: 1.5)
        )
    }
}
