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
                .onOpenURL { url in
                    // A PDF handed to us from Files, the share sheet, or
                    // another app (we register as a PDF viewer + open-in-place
                    // handler in Info.plist). Open it in a tab.
                    guard url.isFileURL else { return }
                    model.open(urls: [url])
                    chrome.chromeHidden = false
                }
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
