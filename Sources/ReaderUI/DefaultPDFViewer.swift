#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// "Make Bluefold the default PDF viewer": a launch prompt (AppDelegate)
/// plus a Settings section for anyone who said Not Now. The Info.plist
/// CFBundleDocumentTypes claim (com.adobe.pdf, role Viewer) is what makes
/// Launch Services accept the app as a handler at all — without it,
/// `setDefaultApplication` fails and Finder never offers Bluefold.
@MainActor
public enum DefaultPDFViewer {
    /// Set when the user checks "Don't ask again" — the launch prompt never
    /// returns after that; Settings stays as the way back in.
    static let promptSuppressedKey = "DefaultPDFViewerPromptSuppressed"

    /// Whether this app (any build variant — comparison is by the running
    /// bundle's identifier, so the dev-suffix bundle counts for itself) is
    /// the system-wide default handler for PDF files.
    public static var isDefault: Bool {
        guard
            let bundleID = Bundle.main.bundleIdentifier,
            let handler = NSWorkspace.shared.urlForApplication(toOpen: UTType.pdf)
        else { return false }
        return Bundle(url: handler)?.bundleIdentifier == bundleID
    }

    /// Pure decision for the launch prompt, kept separate for tests.
    /// `hasBundleID` is false for bare test/CLI processes, which must never
    /// prompt (they aren't a registerable handler anyway).
    static func shouldPrompt(
        isDefault: Bool, suppressed: Bool, hasBundleID: Bool
    ) -> Bool {
        hasBundleID && !isDefault && !suppressed
    }

    /// The launch prompt. Asks again on later launches after a plain
    /// "Not Now"; the suppression checkbox is the durable opt-out.
    public static func promptIfNeeded(defaults: UserDefaults = .standard) {
        // Never during harnessed launches (verify.sh smoke, XCUITest
        // fixtures): a modal alert would wedge the automated quit.
        guard ProcessInfo.processInfo.environment["BLUEFOLD_SESSION_DIR"] == nil
        else { return }
        guard
            shouldPrompt(
                isDefault: isDefault,
                suppressed: defaults.bool(forKey: promptSuppressedKey),
                hasBundleID: Bundle.main.bundleIdentifier != nil
            )
        else { return }

        let alert = NSAlert()
        alert.messageText = "Make Bluefold your default PDF viewer?"
        alert.informativeText =
            "PDFs opened from Finder and other apps will open in Bluefold. "
            + "You can change this anytime in Settings or in Finder's Get Info panel."
        alert.addButton(withTitle: "Set as Default")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: promptSuppressedKey)
        }
        guard response == .alertFirstButtonReturn else { return }
        Task { await makeDefault() }
    }

    /// Registers this bundle as the system default for PDFs. Returns whether
    /// it took (callers refresh their "is default" display from the result).
    @discardableResult
    public static func makeDefault() async -> Bool {
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpen: .pdf
            )
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't Set Default PDF Viewer"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }
}
#endif
