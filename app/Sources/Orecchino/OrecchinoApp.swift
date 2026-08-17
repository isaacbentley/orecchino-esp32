import SwiftUI
import AppKit

@main
struct OrecchinoApp: App {
    // The CommandLineTools SDK lacks the SwiftUIMacros plugin, so the @State
    // macro can't expand; a singleton model avoids per-view state here.
    private var model: AppModel { AppModel.shared }

    init() {
        // When run bare (swift run) rather than from the .app bundle, make
        // sure we behave like a foreground app with a window.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
    }
}
