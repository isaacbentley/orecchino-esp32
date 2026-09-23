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

        MenuBarExtra {
            TrafficMenu().environment(model)
        } label: {
            TrafficMenuLabel()
        }
    }
}

/// The menu bar glyph: an airplane with the count of aircraft within 3 km.
/// A warning fills the glyph and adds a "!" (the menu bar may render it in
/// one colour, so the shape carries the state); stale data reads "STALE"
/// instead of a count; no source shows the glyph alone.
struct TrafficMenuLabel: View {
    // Read inside the view's body, so Observation redraws the label.
    private var model: AppModel { AppModel.shared }

    nonisolated static func text(_ r: TrafficResult, showTraffic: Bool) -> String {
        guard showTraffic, r.haveData else { return "" }
        if r.stale { return "STALE" }
        let warn = r.highest == .warning ? "!" : ""
        return warn + (r.nearCount > 0 ? "\(r.nearCount)" : "")
    }

    var body: some View {
        let result = model.traffic.result
        let showTraffic = model.showTraffic
        let warning = showTraffic && result.highest == .warning
        HStack(spacing: 3) {
            Image(systemName: warning ? "airplane.circle.fill" : "airplane")
                .foregroundStyle(warning ? Theme.danger : Color.primary)
            let t = Self.text(result, showTraffic: showTraffic)
            if !t.isEmpty {
                Text(t).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showTraffic
            ? "Orecchino traffic: " + (result.alerts.first.map { $0.text + ". " } ?? "") + result.summary
            : "Orecchino, traffic layer off")
    }
}

/// The menu: the feed summary, every alert with its level symbol, and the
/// window and quit commands.
struct TrafficMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let r = model.traffic.result
        Text(model.showTraffic ? r.summary : "Traffic layer off")
        if model.showTraffic {
            ForEach(r.alerts) { al in
                Button {
                    open()
                    model.selectedTraffic = al.hex
                } label: {
                    Label("\(al.text) · \(TrafficRules.ageWords(al.ageS))", systemImage: trafficSymbol(al.level))
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
