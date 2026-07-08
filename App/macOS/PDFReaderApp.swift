import AppKit
import ReaderUI
import SwiftUI

@main
struct PDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Persisted (not `register`): NSToolTipManager on macOS 26 ignored
        // the registered default — the owner still saw ~1s tooltips. App
        // init also runs before any window exists, so nothing caches the
        // stale value.
        UserDefaults.standard.set(150, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        WindowGroup(id: "reader", for: UUID.self) { $windowID in
            ReaderWindowView(
                windowID: windowID ?? SessionCoordinator.shared.claimLaunchWindowID()
            )
        }
        .restorationBehavior(.disabled)  // session restore is ours, not the system's
        .commands { ReaderCommands() }

        Window("Library", id: "library") {
            LibraryView()
        }
        .restorationBehavior(.disabled)
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush the session before windows tear down, and stop window-close
        // events from erasing windows out of it.
        SessionCoordinator.shared.prepareForTermination()
        return .terminateNow
    }

    /// pdfreader:// deep links (Info.plist registers the scheme). At launch
    /// these can arrive before any scene exists; the router queues them.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DeepLinkRouter.shared.handle(url)
        }
    }
}
