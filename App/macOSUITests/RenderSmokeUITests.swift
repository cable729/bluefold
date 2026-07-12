import AppKit
import ReaderCore
import XCTest

/// Assert-only render smoke: launches the app once per test and checks that
/// the new chrome (two-row tabs, group headers, split view) actually appears
/// in the accessibility tree. No synthesized input — these stay reliable
/// even on machines where XCUITest click/drag synthesis is broken.
@MainActor
final class RenderSmokeUITests: XCTestCase {

    private var sessionDir: URL!
    private var fixtureDir: URL!

    private static func terminateStrayInstances() {
        let productsDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for running in NSWorkspace.shared.runningApplications {
            guard
                let url = running.bundleURL,
                url.lastPathComponent == "Bluefold.app",
                url.path.hasPrefix(productsDir.path)
            else { continue }
            running.forceTerminate()
        }
        usleep(300_000)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        Self.terminateStrayInstances()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bluefold-rendersmoke-\(UUID().uuidString)")
        sessionDir = base.appendingPathComponent("session")
        fixtureDir = base.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Self.terminateStrayInstances()
        if let dir = sessionDir?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    private func makePDF(named name: String) -> URL {
        let url = fixtureDir.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for _ in 1...2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLUEFOLD_SESSION_DIR"] = sessionDir.path
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testStripGroupsSameBookTabsIntoOneLozenge() {
        let axler = makePDF(named: "Axler")
        let other = makePDF(named: "Other")
        // Same book twice (adjacent) + another book: expect TWO lozenges —
        // the Axler pair shares one, Other gets its own.
        let app = launch(arguments: [
            "--open", axler.path, "--open", axler.path, "--open", other.path,
        ])
        let strip = app.windows.firstMatch.groups["tab-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))

        let lozenges = strip.groups.matching(
            NSPredicate(format: "identifier == 'tab-group-header'")
        )
        XCTAssertTrue(lozenges.firstMatch.waitForExistence(timeout: 5),
                      "tabs should render inside book lozenges")
        XCTAssertEqual(lozenges.count, 2,
                       "adjacent same-book tabs share one lozenge")
        let titles = lozenges.allElementsBoundByIndex.map(\.title)
        XCTAssertTrue(titles.contains("Axler"), "lozenge titles: \(titles)")

        // The lozenge must lie inside the strip band and be readable.
        let stripFrame = strip.frame
        let lozengeFrame = lozenges.firstMatch.frame
        XCTAssertTrue(
            stripFrame.insetBy(dx: -1, dy: -1).contains(lozengeFrame),
            "lozenge \(lozengeFrame) must render within the strip \(stripFrame)"
        )
        XCTAssertGreaterThanOrEqual(lozengeFrame.height, 20, "lozenge should be readable")

        dumpScreenshot(of: app.windows.firstMatch, named: "lozenge-strip")

        // Every tab carries its breadcrumb cell (page label for
        // outline-less fixtures).
        let breadcrumbs = strip.staticTexts.matching(
            NSPredicate(format: "identifier == 'tab-breadcrumb'")
        )
        XCTAssertGreaterThanOrEqual(breadcrumbs.count, 3)
        quit(app)
    }

    func testSplitViewRendersSecondPaneFromRestoredSession() throws {
        let a = makePDF(named: "Alpha")
        let b = makePDF(named: "Beta")
        let tabs = [TabState(pathHint: a.path), TabState(pathHint: b.path)]
        let snapshot = SessionSnapshot(windows: [
            WindowState(
                id: UUID(),
                frame: CGRect(x: 200, y: 200, width: 1100, height: 600),
                tabs: tabs,
                activeTabID: tabs[0].id,
                splitTabID: tabs[1].id
            )
        ])
        try SessionCodec.encode(snapshot)
            .write(to: sessionDir.appendingPathComponent("session.json"))

        let app = launch(arguments: [])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.groups["tab-strip"].waitForExistence(timeout: 10))

        // Each pane carries its OWN tab bar (per-pane strips redesign).
        XCTAssertTrue(
            window.groups["tab-strip-split"].waitForExistence(timeout: 10),
            "the split pane should render its own tab strip"
        )
        let documents = window.groups.matching(
            NSPredicate(format: "label == 'document'")
        )
        XCTAssertEqual(documents.count, 2, "both panes should hold a PDF view")
        quit(app)
    }

    private func quit(_ app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        _ = app.wait(for: .notRunning, timeout: 10)
    }

    /// Saves a window screenshot to $RENDERSMOKE_SHOT_DIR (when set) so a
    /// human — or an agent without screen-recording rights — can inspect the
    /// rendered chrome after a run.
    private func dumpScreenshot(of element: XCUIElement, named name: String) {
        guard let dir = ProcessInfo.processInfo.environment["RENDERSMOKE_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? element.screenshot().pngRepresentation.write(to: url)
    }
}
