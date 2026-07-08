import AppKit
import ReaderUI
import SwiftUI

@main
struct PDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // System tooltips (.help) take well over a second to appear; the
        // owner wants EVERY hover hint near-instant. This global default is
        // read by NSToolTipManager and covers all .help tooltips app-wide
        // (custom .instantHint bubbles are already at 150ms).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush the session before windows tear down, and stop window-close
        // events from erasing windows out of it.
        SessionCoordinator.shared.prepareForTermination()
        return .terminateNow
    }
}
