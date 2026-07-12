import ReaderUI
import SwiftUI

@main
struct BluefoldApp: App {
    @State private var model = ReaderSessionModel()
    @State private var theme = ThemeStore()
    @State private var library = LibraryModel()
    @State private var chrome = ReaderChromeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ReaderView(model: model, theme: theme, library: library, chrome: chrome)
        }
        // iPadOS menu bar / hold-⌘ HUD. NOTE: app state is App-level
        // @State, so a second scene would share it — keep the app
        // single-scene (UIApplicationSupportsMultipleScenes stays off)
        // until per-scene models exist.
        .commands {
            ReaderCommandsIOS(model: model, theme: theme, chrome: chrome)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // iOS has no clean "will terminate" hook. `.background` is the
            // classic flush point, but a suspended app can be killed without
            // ever leaving `.inactive` (app switcher, interruptions), so
            // save on BOTH — the write is atomic and cheap (same session.json
            // format as macOS, single window).
            if newPhase == .inactive || newPhase == .background {
                model.save()
            }
        }
    }
}
