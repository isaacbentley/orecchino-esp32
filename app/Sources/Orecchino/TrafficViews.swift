// TrafficViews.swift — ADS-B traffic on the Mac (plan §8.5): the sidebar's
// alert strip, aircraft rows, the map marker, the separation bridge, the
// aircraft card and the feed status. Every level has its own symbol, so no
// state is told by colour alone; every alert shows its data age.
// Words: never "collision", "conflict", "safe", "clear" or "TCAS".
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
    case .advisory: return Theme.accent
    case .none:     return Theme.muted
    }
}

/// A distinct symbol per level, so the level reads without colour.
func trafficSymbol(_ level: TrafficLevel?) -> String {
    switch level ?? .none {
    case .warning:  return "exclamationmark.triangle.fill"
    case .caution:  return "exclamationmark.circle.fill"
    case .advisory: return "info.circle.fill"
    case .none:     return "airplane"
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

/// "UAL123 B738 · 1.1 km · Δ +90 m" — the second line of an alert.
func trafficAlertDetail(_ a: TrafficAlert, aircraft: TrafficAircraft?) -> String {
    var parts = [[a.callsign.isEmpty ? a.hex.uppercased() : a.callsign, aircraft?.type ?? ""]
        .filter { !$0.isEmpty }.joined(separator: " ")]
    parts.append(trafficKm(a.horizM) + (a.kind.isPair ? "" : " from here"))
    if a.kind.isPair { parts.append(a.vertM.map { "Δ " + trafficVert($0) } ?? "height unknown") }
    return parts.joined(separator: " · ")
}

// MARK: - Sidebar: traffic alerts (above the drones)

/// One traffic alert: the rule's words, the pair's numbers, the data age and
/// "Show", which centres the map on the drone and the aircraft.
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
                Text(alert.text)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(color)
            Text(trafficAlertDetail(alert, aircraft: ac))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
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
        .onTapGesture { model.selectedTraffic = alert.hex }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.level.name) traffic alert: \(alert.text). "
                            + "\(trafficAlertDetail(alert, aircraft: ac)). \(TrafficRules.ageWords(alert.ageS))")
        .accessibilityAction(named: "Show on map") { model.focus(on: model.coordinates(of: alert)) }
    }
}

// MARK: - Sidebar: aircraft rows

struct TrafficRow: View {
    @Environment(AppModel.self) private var model
    let aircraft: TrafficAircraft
    let alert: TrafficAlert?

    var body: some View {
        let color = trafficColor(alert?.level)
        let age = aircraft.ageS(nowMs: TrafficRules.nowMs(model.now))
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.6), lineWidth: 1)
                    .frame(width: 30, height: 30)
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees((aircraft.trackDeg ?? 90) - 90))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(aircraft.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    if !aircraft.type.isEmpty {
                        Text(aircraft.type)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if let alert {
                        Label(alert.kind.name.uppercased(), systemImage: trafficSymbol(alert.level))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color)
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    if let ft = trafficFeet(aircraft.altBaroM) {
                        Text(ft + trafficTrend(aircraft.vsMps))
                    } else {
                        Text("altitude —").foregroundStyle(Theme.unknown)
                    }
                    if let r = model.location.current {
                        Text("· \(trafficKm(TrafficRules.distanceM(r.latitude, r.longitude, aircraft.lat, aircraft.lon)))")
                    }
                    Spacer(minLength: 4)
                    Text(TrafficRules.ageWords(age))
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 2)
        .opacity(age >= TrafficRules.freshS ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Aircraft \(aircraft.name)"
                            + (aircraft.type.isEmpty ? "" : ", \(aircraft.type)")
                            + (trafficFeet(aircraft.altBaroM).map { ", \($0)" } ?? "")
                            + (alert.map { ", \($0.text)" } ?? "")
                            + ", \(TrafficRules.ageWords(age))")
    }
}

// MARK: - Map marker

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
                            + (alert.map { ", \($0.text)" } ?? ""))
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

/// Labels one drone-aircraft pair alert with that pair's own numbers.
struct SeparationBridge: View {
    let alert: TrafficAlert

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trafficSymbol(alert.level))
                .font(.system(size: 9, weight: .bold))
            Text(trafficKm(alert.horizM))
            Text("·")
            Text(alert.vertM.map { "Δ " + trafficVert($0) } ?? "height unknown")
        }
        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(trafficColor(alert.level), in: Capsule())
        .foregroundStyle(.white)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Separation between drone \(TrafficRules.droneLabel(alert.droneId)) and "
                            + "\(alert.callsign.isEmpty ? alert.hex.uppercased() : alert.callsign): "
                            + "\(trafficKm(alert.horizM)), "
                            + (alert.vertM.map { "vertical \(trafficVert($0))" } ?? "height unknown"))
    }
}

// MARK: - Feed status (top of the map)

/// What the feed says, with its age; never "no traffic". Warns when stale,
/// failing or without a position to look around.
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
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "airplane")
            Text(model.demoMode ? "SIMULATED · " + r.summary : r.summary)
            if let problem { Text("· \(problem)") }
        }
        .font(.system(size: 11, weight: warn ? .semibold : .regular, design: .monospaced))
        .foregroundStyle(warn ? Theme.warn : Theme.muted)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .help("Aircraft positions from adsb.lol, as reported. Not every aircraft broadcasts ADS-B, "
              + "and the feed has gaps and delay.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Aircraft card

struct TrafficCard: View {
    @Environment(AppModel.self) private var model
    let aircraft: TrafficAircraft
    let alert: TrafficAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: the rule's words and the data age
            HStack(spacing: 8) {
                Image(systemName: alert.map { trafficSymbol($0.level) } ?? "airplane")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(trafficColor(alert?.level))
                Text(alert?.text ?? "ADS-B AIRCRAFT")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(alert == nil ? Color.primary : trafficColor(alert?.level))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(TrafficRules.ageWords(aircraft.ageS(nowMs: TrafficRules.nowMs(model.now))))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
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

            // Callsign, type and address
            HStack(alignment: .firstTextBaseline) {
                Text(aircraft.name)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                Text([aircraft.type, aircraft.hex.uppercased()].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if aircraft.squawk > 0 {
                    let emergency = [7500, 7600, 7700].contains(aircraft.squawk)
                    Text(String(format: "SQ %04d", aircraft.squawk))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(emergency ? Theme.danger.opacity(0.2) : Theme.inset)
                        .foregroundStyle(emergency ? Theme.danger : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Divider()

            // Separation: from the drone for a pair, else from here
            if let alert {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.kind.isPair ? "FROM DRONE \(TrafficRules.droneLabel(alert.droneId))" : "FROM HERE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(trafficKm(alert.horizM))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                    }
                    if alert.kind.isPair {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VERTICAL")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(trafficVert(alert.vertM))
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .foregroundStyle(alert.vertM == nil ? Theme.unknown : .primary)
                        }
                    }
                    if let cpa = alert.cpaS {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CLOSEST IN")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(Int(floor(cpa + 0.5))) s")
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                        }
                    }
                }
            }

            // Altitude, speed, vertical rate as reported
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ALTITUDE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(trafficFeet(aircraft.altBaroM) ?? "--")
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
