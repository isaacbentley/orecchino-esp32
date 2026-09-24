import SwiftUI
import AppKit

@main
struct OrecchinoApp: App {
    // The CommandLineTools SDK lacks the SwiftUIMacros plugin, so the @State
    // macro can't expand; a singleton model avoids per-view state here.
    private var model: AppModel { AppModel.shared }

    static let mainWindowId = "main"

    init() {
        // When run bare (swift run) rather than from the .app bundle, make
        // sure we behave like a foreground app with a window.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        // A single window: "Open Window" in the menu bar extra brings it back
        // after it has been closed (openWindow), rather than making a second.
        Window("Orecchino", id: Self.mainWindowId) {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            TrafficMenu().environment(model)
        } label: {
            TrafficMenuLabel()
        }
    }
}

/// The menu bar item is about drones: an antenna glyph with the number of
/// drones heard in the last minute. An ADS-B alert about them swaps the
/// glyph for a filled warning triangle and adds "!" and the number of
/// alerts (the shape carries it, the menu bar may render one colour);
/// stale ADS-B data adds "STALE". Aircraft are never counted.
struct TrafficMenuLabel: View {
    // Read inside the view's body, so Observation redraws the label.
    private var model: AppModel { AppModel.shared }

    nonisolated static func text(drones: Int, _ r: TrafficResult, showTraffic: Bool) -> String {
        var parts: [String] = drones > 0 ? ["\(drones)"] : []
        if showTraffic && r.haveData {
            if !r.alerts.isEmpty { parts.append("!\(r.alerts.count)") }
            if r.stale { parts.append("STALE") }
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        let result = model.traffic.result
        let showTraffic = model.showTraffic
        let live = model.tracks.values.filter { !model.isStale($0) }.count
        let alerting = showTraffic && !result.alerts.isEmpty
        HStack(spacing: 3) {
            Image(systemName: alerting ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(alerting ? trafficColor(result.highest) : Color.primary)
            let t = Self.text(drones: live, result, showTraffic: showTraffic)
            if !t.isEmpty {
                Text(t).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orecchino: \(live) drone\(live == 1 ? "" : "s") heard"
            + (alerting ? ". " + result.alerts.map(trafficAction).joined(separator: ". ") : "")
            + (showTraffic ? ". " + result.summary : ""))
    }
}

/// The menu: the drones heard (each with its ADS-B action, if any), the
/// conflict watch's status, and the window and quit commands.
struct TrafficMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let live = model.trackList.filter { !model.isStale($0) }
        Text(live.isEmpty ? "No drones heard in the last minute"
                          : "\(live.count) drone\(live.count == 1 ? "" : "s") heard")
        ForEach(live) { t in
            Button {
                open()
                model.selection = t.id
            } label: {
                if let al = model.trafficAlert(forTrack: t) {
                    Label("\(t.title) · \(trafficAction(al))", systemImage: trafficSymbol(al.level))
                } else {
                    Text(t.title + (model.range(to: t).map { " · \(fmtDist($0))" } ?? ""))
                }
            }
        }
        if model.showTraffic {
            Divider()
            Text(model.traffic.result.summary)
            // Alerts with no drone of their own (traffic near the user).
            ForEach(model.traffic.result.alerts.filter { $0.droneId.isEmpty }) { al in
                Button {
                    open()
                    model.select(alert: al)
                } label: {
                    Label("\(trafficAction(al)) · \(TrafficRules.ageWords(al.ageS))", systemImage: trafficSymbol(al.level))
                }
            }
        }
        Divider()
        Button("Open Window") { open() }
            .keyboardShortcut("0", modifiers: [.command])
        Button("Quit Orecchino") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open() {
        openWindow(id: OrecchinoApp.mainWindowId)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings: how far the conflict watch looks, and the receiver's map.
struct SettingsView: View {
    @AppStorage(AdsbArea.radiusKey) private var adsbKm = AdsbArea.defaultKm
    @AppStorage(TileSync.radiusKey) private var tileKm = 3.0

    var body: some View {
        Form {
            Section("ADS-B conflict watch") {
                Stepper(value: $adsbKm, in: AdsbArea.minKm...AdsbArea.maxKm, step: 1) {
                    Text("Look for aircraft within \(Int(adsbKm)) km of this Mac")
                }
                Text("Grows by itself (up to 30 km) so that a drone more than 3 km away still has 9 km "
                     + "around it covered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Receiver map") {
                Stepper(value: $tileKm, in: 1...30, step: 1) {
                    Text("Map tiles within \(Int(tileKm)) km (zooms 12–15)")
                }
                Text("Planned against the receiver's storage before anything is sent; if it does not "
                     + "fit, the closest zoom shrinks first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
