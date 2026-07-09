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
        .keyboardShortcut(Self.libraryShortcut)

        // ⌘, — the standard Settings scene (M18). All logic lives in
        // ReaderUI.SettingsView; this shell only declares the scene.
        Settings {
            SettingsView()
        }
    }

    /// Scene-level Library binding, read from the command table so a
    /// keybindings.json override of file.openLibrary lands here too.
    /// Scene shortcuts can't be absent, so unbinding falls back to ⌘⇧L.
    private static var libraryShortcut: KeyboardShortcut {
        CommandRegistry.command(id: "file.openLibrary")?.chords.first?.keyboardShortcut
            ?? KeyboardShortcut("l", modifiers: [.command, .shift])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        presentKeybindingsIssuesIfNeeded()
        // Materialize the (lazy) library model and run one library pass:
        // watched-folder sync and the source watchers must work from app
        // launch, not from the first time the Library window opens.
        let library = LibraryModel.shared
        Task { await library.reload() }
    }

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

    /// One alert listing every keybindings.json problem found at launch.
    /// Deferred a runloop turn so session-restored windows appear first.
    private func presentKeybindingsIssuesIfNeeded() {
        let issues = CommandRegistry.keybindingsIssues
        guard !issues.isEmpty else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Some keybindings could not be applied"
            alert.informativeText = "keybindings.json has problems — the valid entries "
                + "were applied, these were not:\n\n"
                + issues.map { "• \($0)" }.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Keybindings File")
            if alert.runModal() == .alertSecondButtonReturn {
                Keybindings.openFile()
            }
        }
    }
}
