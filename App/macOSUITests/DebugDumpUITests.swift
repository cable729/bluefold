import XCTest

/// Temporary diagnostic: dumps the app's accessibility tree so we can see
/// how the AppKit tab strip is (or isn't) exposed. Not part of the smoke
/// suite; delete once element queries are settled.
@MainActor
final class DebugDumpUITests: XCTestCase {
    func testDumpHierarchy() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfreader-uidebug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let pdf = base.appendingPathComponent("Alpha.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(pdf as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()

        let app = XCUIApplication()
        app.launchEnvironment["PDFREADER_SESSION_DIR"] = base.path
        app.launchArguments = ["--open", pdf.path]
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        sleep(2)

        var windowReport = "=== CGWindowList (onscreen) ===\n"
        if let wins = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] {
            for w in wins {
                let owner = w["kCGWindowOwnerName"] as? String ?? "?"
                let pid = w["kCGWindowOwnerPID"] as? Int ?? 0
                let layer = w["kCGWindowLayer"] as? Int ?? 0
                let bounds = w["kCGWindowBounds"] as? [String: Any] ?? [:]
                if layer == 0 {
                    windowReport += "\(owner) pid=\(pid) bounds=\(bounds)\n"
                }
            }
        }
        windowReport += "\n=== app pid=\(app.debugDescription.contains("pid:") ? "see tree" : "?") ===\n"
        windowReport += "=== all PDFReader windows incl. offscreen ===\n"
        if let wins = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] {
            for w in wins where (w["kCGWindowOwnerName"] as? String)?.contains("PDFReader") == true {
                windowReport += "pid=\(w["kCGWindowOwnerPID"] ?? 0) onscreen=\(w["kCGWindowIsOnscreen"] ?? false) layer=\(w["kCGWindowLayer"] ?? 0) bounds=\(w["kCGWindowBounds"] as? [String: Any] ?? [:])\n"
            }
        }

        let attachment = XCTAttachment(string: windowReport + "\n\n" + app.debugDescription)
        attachment.name = "ui-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
