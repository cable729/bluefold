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
                url.lastPathComponent == "PDFReader.app",
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
            .appendingPathComponent("pdfreader-rendersmoke-\(UUID().uuidString)")
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
        app.launchEnvironment["PDFREADER_SESSION_DIR"] = sessionDir.path
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testTwoRowStripShowsBreadcrumbsAndGroupHeader() {
        let axler = makePDF(named: "Axler")
        let other = makePDF(named: "Other")
        // Same book twice (adjacent) + another book: expect ONE group header.
        let app = launch(arguments: [
            "--open", axler.path, "--open", axler.path, "--open", other.path,
        ])
        let strip = app.windows.firstMatch.groups["tab-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))

        let header = strip.groups["tab-group-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5),
                      "adjacent same-book tabs should get a spanning header")
        XCTAssertEqual(header.title, "Axler")

        // Every tab carries a second-row breadcrumb (page label for
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

        // Two live PDF panes + the split header's close button.
        XCTAssertTrue(
            window.buttons["close-split"].waitForExistence(timeout: 10),
            "split pane header should render its close button"
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
}
