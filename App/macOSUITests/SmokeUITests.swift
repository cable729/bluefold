import AppKit
import XCTest

/// M17 smoke suite: drives the real app through the flows unit tests cannot
/// see (window management, tab dragging, relaunch restore). Fixtures are
/// generated on the fly; every launch gets a private session directory via
/// the PDFREADER_SESSION_DIR hook so runs never touch a real session.
@MainActor
final class SmokeUITests: XCTestCase {

    private var sessionDir: URL!
    private var fixtureDir: URL!

    /// A second instance of the same bundle ID never opens its window, so a
    /// failed test's leftover instance would poison every run after it.
    /// Killing all instances before AND after each test keeps runs hermetic.
    /// Matching by bundle *path* (the products dir this runner sits in)
    /// avoids hardcoding the bundle ID and never touches other builds of the
    /// app that may be running (e.g. the developer's own copy).
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
        // Give the window server a beat to release the dying instance.
        usleep(300_000)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        Self.terminateStrayInstances()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfreader-uitests-\(UUID().uuidString)")
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

    // MARK: - Fixtures

    /// Writes a minimal multi-page PDF; the title becomes the tab label.
    private func makePDF(named name: String, pages: Int = 3) -> URL {
        let url = fixtureDir.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let text = "\(name) — page \(page)" as CFString
            let attrs = [
                kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            ] as CFDictionary
            let attributed = CFAttributedStringCreate(nil, text, attrs)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func launchApp(opening files: [URL], freshSession: Bool = false) -> XCUIApplication {
        if freshSession {
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        }
        let app = XCUIApplication()
        app.launchEnvironment["PDFREADER_SESSION_DIR"] = sessionDir.path
        app.launchArguments = files.flatMap { ["--open", $0.path] }
        app.launch()
        return app
    }

    /// Quits via ⌘Q (the graceful path that flushes session.json) and waits.
    private func quitGracefully(_ app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "app should quit within 10s"
        )
    }

    /// Tab buttons of a window's strip, left-to-right as the user sees them.
    /// (The strip is an AppKit group: query .groups, not .otherElements.)
    private func tabTitles(in window: XCUIElement) -> [String] {
        let strip = window.groups["tab-strip"]
        let tabs = strip.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'tab-' AND identifier != 'tab-close'")
        )
        return tabs.allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.title }
    }

    private func tab(_ name: String, in window: XCUIElement) -> XCUIElement {
        window.groups["tab-strip"].buttons["tab-\(name)"]
    }

    // MARK: - Session restore

    func testQuitAndRelaunchRestoresTabs() {
        let alpha = makePDF(named: "Alpha")
        let beta = makePDF(named: "Beta")

        let app = launchApp(opening: [alpha, beta], freshSession: true)
        let found = tab("Alpha", in: app.windows.firstMatch).waitForExistence(timeout: 10)
        if !found {
            let dump = XCTAttachment(string: """
            windows.count=\(app.windows.count)
            strip.exists=\(app.windows.firstMatch.groups["tab-strip"].exists)
            buttons=\(app.windows.firstMatch.groups["tab-strip"].buttons.allElementsBoundByIndex.map(\.identifier))
            ---
            \(app.debugDescription)
            """)
            dump.name = "failure-dump"
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(found)
        XCTAssertTrue(tab("Beta", in: app.windows.firstMatch).exists)
        quitGracefully(app)

        // Relaunch bare: the session file alone must bring both tabs back.
        let relaunched = launchApp(opening: [])
        XCTAssertTrue(
            tab("Alpha", in: relaunched.windows.firstMatch).waitForExistence(timeout: 10),
            "restored session should reopen Alpha"
        )
        XCTAssertTrue(tab("Beta", in: relaunched.windows.firstMatch).exists)
        quitGracefully(relaunched)
    }

    // MARK: - Tab dragging

    func testDragReordersTabsWithinWindow() {
        let files = ["Alpha", "Beta", "Gamma"].map { makePDF(named: $0) }
        let app = launchApp(opening: files, freshSession: true)
        let window = app.windows.firstMatch
        XCTAssertTrue(tab("Gamma", in: window).waitForExistence(timeout: 10))
        XCTAssertEqual(tabTitles(in: window), ["Alpha", "Beta", "Gamma"])

        // Drag Gamma onto Alpha's slot: horizontal, stays inside the strip.
        tab("Gamma", in: window).click(forDuration: 0.3, thenDragTo: tab("Alpha", in: window))

        XCTAssertEqual(
            tabTitles(in: window), ["Gamma", "Alpha", "Beta"],
            "dragging Gamma to the left edge should make it first"
        )
        quitGracefully(app)
    }

    func testDragTabToDesktopOpensNewWindow() {
        let files = ["Alpha", "Beta"].map { makePDF(named: $0) }
        let app = launchApp(opening: files, freshSession: true)
        let window = app.windows.firstMatch
        XCTAssertTrue(tab("Beta", in: window).waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)

        // Tear Beta off: drop far below the strip, outside every window.
        let start = tab("Beta", in: window).coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let desktop = window.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 1.0))
            .withOffset(CGVector(dx: 120, dy: 120))
        start.click(forDuration: 0.3, thenDragTo: desktop)

        XCTAssertTrue(
            app.windows.element(boundBy: 1).waitForExistence(timeout: 10),
            "tearing off a tab should open a second window"
        )
        XCTAssertEqual(app.windows.count, 2)

        // Beta lives in exactly one window; Alpha stayed put.
        let titles = (0..<2).map { tabTitles(in: app.windows.element(boundBy: $0)) }
        XCTAssertEqual(titles.flatMap(\.self).sorted(), ["Alpha", "Beta"])
        quitGracefully(app)
    }

    func testDragTabBetweenWindows() {
        let files = ["Alpha", "Beta", "Gamma"].map { makePDF(named: $0) }
        let app = launchApp(opening: files, freshSession: true)
        let first = app.windows.firstMatch
        XCTAssertTrue(tab("Gamma", in: first).waitForExistence(timeout: 10))

        // Tear Gamma into its own window first.
        let start = tab("Gamma", in: first).coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let desktop = first.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 1.0))
            .withOffset(CGVector(dx: 120, dy: 120))
        start.click(forDuration: 0.3, thenDragTo: desktop)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 10))

        // Identify which window now holds Gamma alone.
        let windows = (0..<2).map { app.windows.element(boundBy: $0) }
        let gammaWindow = windows.first { tabTitles(in: $0) == ["Gamma"] }
        let mainWindow = windows.first { tabTitles(in: $0).contains("Alpha") }
        guard let gammaWindow, let mainWindow else {
            return XCTFail("expected one window with Gamma and one with Alpha+Beta")
        }

        // Drag Beta from the main window onto the Gamma window's strip.
        tab("Beta", in: mainWindow).click(
            forDuration: 0.3,
            thenDragTo: gammaWindow.groups["tab-strip"]
        )

        XCTAssertTrue(
            tab("Beta", in: gammaWindow).waitForExistence(timeout: 5),
            "Beta should have moved to the second window"
        )
        XCTAssertEqual(tabTitles(in: mainWindow), ["Alpha"])
        XCTAssertEqual(Set(tabTitles(in: gammaWindow)), Set(["Gamma", "Beta"]))
        quitGracefully(app)
    }
}
