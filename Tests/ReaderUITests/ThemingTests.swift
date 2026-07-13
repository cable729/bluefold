#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

/// Creates a one-page PDF with a solid white background.
private func makeWhitePDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ThemingTests-\(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard
        let consumer = CGDataConsumer(url: url as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { fatalError("cannot create PDF context") }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(mediaBox)
    context.endPDFPage()
    context.closePDF()
    return url
}

/// Mean RGB of the page rendered via `PDFPage.draw(with:to:)` — the same
/// entry point PDFView's tile pipeline uses (thumbnail APIs bypass it).
@MainActor
private func meanColor(of page: PDFPage) -> (red: Double, green: Double, blue: Double) {
    let size = 40
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return (0, 0, 0) }

    let bounds = page.bounds(for: .mediaBox)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.scaleBy(x: CGFloat(size) / bounds.width, y: CGFloat(size) / bounds.height)
    page.draw(with: .mediaBox, to: context)

    guard let data = context.data else { return (0, 0, 0) }
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var totals = (red: 0.0, green: 0.0, blue: 0.0)
    var count = 0.0
    for y in stride(from: 2, to: size - 2, by: 4) {
        for x in stride(from: 2, to: size - 2, by: 4) {
            let offset = (y * context.bytesPerRow) + x * 4
            totals.red += Double(pixels[offset]) / 255
            totals.green += Double(pixels[offset + 1]) / 255
            totals.blue += Double(pixels[offset + 2]) / 255
            count += 1
        }
    }
    return (totals.red / count, totals.green / count, totals.blue / count)
}

@Suite("Page theming", .serialized)
@MainActor
struct ThemingTests {
    /// Loads the fixture through DocumentProvider so classForPage applies.
    private func loadThemedPage() throws -> (PDFPage, cleanup: () -> Void) {
        let url = try makeWhitePDF()
        let provider = DocumentProvider()
        let document = try #require(provider.document(for: url))
        let page = try #require(document.page(at: 0))
        #expect(page is ThemedPDFPage)
        return (page, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func lightLeavesPageWhite() throws {
        let (page, cleanup) = try loadThemedPage()
        defer {
            cleanup()
            PageFilterStore.current = .none
        }
        PageFilterStore.current = .none
        let color = meanColor(of: page)
        #expect(color.red > 0.9 && color.green > 0.9 && color.blue > 0.9)
    }

    @Test func darkInvertsWhiteToBlack() throws {
        let (page, cleanup) = try loadThemedPage()
        defer {
            cleanup()
            PageFilterStore.current = .none
        }
        PageFilterStore.current = .invert
        let color = meanColor(of: page)
        #expect(color.red < 0.1 && color.green < 0.1 && color.blue < 0.1)
    }

    @Test func sepiaWarmsWhiteToTan() throws {
        let (page, cleanup) = try loadThemedPage()
        defer {
            cleanup()
            PageFilterStore.current = .none
        }
        PageFilterStore.current = AppTheme.sepia.pageRenderFilter
        let color = meanColor(of: page)
        // The Claude-tan paper: warm, red > green > blue, still light.
        #expect(abs(color.red - 0.961) < 0.05)
        #expect(abs(color.blue - 0.882) < 0.05)
        #expect(color.red > color.blue)
    }

    @Test func solarizedLightWarmsWhiteToCream() throws {
        let (page, cleanup) = try loadThemedPage()
        defer {
            cleanup()
            PageFilterStore.current = .none
        }
        PageFilterStore.current = AppTheme.solarizedLight.pageRenderFilter
        let color = meanColor(of: page)
        // base3 #FDF6E3: light warm cream, red > green > blue.
        #expect(color.red > 0.95 && color.blue > 0.85)
        #expect(color.red > color.green && color.green > color.blue)
    }

    @Test func foldblueWarmsWhiteToBrownPaper() throws {
        let (page, cleanup) = try loadThemedPage()
        defer {
            cleanup()
            PageFilterStore.current = .none
        }
        PageFilterStore.current = AppTheme.foldblue.pageRenderFilter
        let color = meanColor(of: page)
        // #F1E3CC: warm aussie-brown paper — browner than sepia (lower blue),
        // still a light readable surface, red > green > blue.
        #expect(color.red > 0.9 && color.blue > 0.75)
        #expect(color.red > color.green && color.green > color.blue)
        #expect(color.blue < 0.85, "browner than sepia's #F5EDE1 (blue ~0.88)")
    }

    /// invertTinted turns a white page into the theme's dark paper: low luma,
    /// with the tint's hue preserved. Spot-checks the three families.
    @Test func invertTintedProducesDarkTintedPaper() throws {
        let (page, cleanup) = try loadThemedPage()
        defer {
            cleanup()
            PageFilterStore.current = .none
        }

        // Solarized Dark #002B36 — deep teal: blue ≳ green ≫ red≈0, dark.
        PageFilterStore.current = AppTheme.solarizedDark.pageRenderFilter
        var color = meanColor(of: page)
        #expect(color.red < 0.15 && color.green < 0.3 && color.blue < 0.35)
        #expect(color.blue > color.red && color.green > color.red)

        // Nord #2E3440 — cool slate: blue > green > red, still dark.
        PageFilterStore.current = AppTheme.nord.pageRenderFilter
        color = meanColor(of: page)
        #expect(color.red < 0.3 && color.green < 0.3 && color.blue < 0.35)
        #expect(color.blue > color.red)

        // Bluefold #0E2849 — brand navy: blue clearly the strongest channel.
        PageFilterStore.current = AppTheme.bluefold.pageRenderFilter
        color = meanColor(of: page)
        #expect(color.blue < 0.4 && color.red < 0.2)
        #expect(color.blue > color.green && color.green > color.red)
    }
}

/// ThemeManager resolution + window-chrome application. Serialized: the
/// manager writes the process-global PageFilterStore and UserDefaults key.
@Suite("Theme manager", .serialized)
@MainActor
struct ThemeManagerTests {
    private static let themeKeys = [
        "BluefoldTheme", "BluefoldLastLightTheme", "BluefoldLastDarkTheme",
    ]

    /// Fresh manager with the persisted keys and page filter cleared afterwards.
    private func withManager(_ body: (ThemeManager) throws -> Void) rethrows {
        func clear() { Self.themeKeys.forEach(UserDefaults.standard.removeObject) }
        defer {
            clear()
            PageFilterStore.current = .none
        }
        clear()
        try body(ThemeManager())
    }

    @Test func autoResolvesAndTracksSystemAppearance() {
        withManager { manager in
            manager.current = .auto
            manager.overrideSystemAppearance(isDark: false)
            #expect(manager.resolvedTheme == .light)
            #expect(PageFilterStore.current == .none)

            manager.overrideSystemAppearance(isDark: true)
            #expect(manager.resolvedTheme == .dark)
            #expect(PageFilterStore.current == .invert)
        }
    }

    /// `.auto` follows the last light-family and dark-family picks: choose
    /// Sepia (light) then Nord (dark), switch to Auto, and day shows Sepia
    /// while night shows Nord — not the plain light/dark defaults.
    @Test func autoRemembersLastLightAndDarkPicks() {
        withManager { manager in
            manager.current = .sepia
            manager.current = .nord
            #expect(manager.lastLightTheme == .sepia)
            #expect(manager.lastDarkTheme == .nord)

            manager.current = .auto
            manager.overrideSystemAppearance(isDark: false)
            #expect(manager.resolvedTheme == .sepia)
            #expect(PageFilterStore.current == AppTheme.sepia.pageRenderFilter)

            manager.overrideSystemAppearance(isDark: true)
            #expect(manager.resolvedTheme == .nord)
            #expect(PageFilterStore.current == AppTheme.nord.pageRenderFilter)
        }
    }

    /// The remembered picks persist across manager instances (relaunch).
    @Test func rememberedPicksPersistAcrossInstances() {
        withManager { _ in
            ThemeManager().current = .foldblue
            ThemeManager().current = .dracula
            let fresh = ThemeManager()
            #expect(fresh.lastLightTheme == .foldblue)
            #expect(fresh.lastDarkTheme == .dracula)
        }
    }

    @Test func concreteThemeIgnoresSystemFlips() {
        withManager { manager in
            manager.current = .sepia
            manager.overrideSystemAppearance(isDark: true)
            #expect(manager.resolvedTheme == .sepia)
            #expect(PageFilterStore.current == AppTheme.sepia.pageRenderFilter)
        }
    }

    @Test func autoPersistsAndRestores() {
        defer {
            UserDefaults.standard.removeObject(forKey: "BluefoldTheme")
            PageFilterStore.current = .none
        }
        UserDefaults.standard.removeObject(forKey: "BluefoldTheme")
        ThemeManager().current = .auto
        #expect(UserDefaults.standard.string(forKey: "BluefoldTheme") == "auto")
        #expect(ThemeManager().current == .auto)
    }

    @Test func registeredWindowChromeFollowsTheme() {
        withManager { manager in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            manager.register(window)

            // Cloth & Paper chrome: EVERY theme paints the titlebar band
            // (transparent titlebar over the theme's chrome color).
            manager.current = .dark
            #expect(window.appearance?.name == .darkAqua)
            #expect(window.titlebarAppearsTransparent == true)
            let navy = window.backgroundColor.usingColorSpace(.sRGB)
            #expect(navy != nil && navy!.blueComponent > navy!.redComponent,
                    "dark chrome is the design system's navy band")

            manager.current = .sepia
            #expect(window.appearance?.name == .aqua)
            #expect(window.titlebarAppearsTransparent == true)
            let tan = window.backgroundColor.usingColorSpace(.sRGB)
            #expect(tan != nil && tan!.redComponent > tan!.blueComponent)

            // Auto: inherit (nil appearance) so the window follows the system.
            // Pin the tracked system appearance — the real one flips with
            // the time of day, and this test must not.
            manager.current = .auto
            manager.overrideSystemAppearance(isDark: false)
            #expect(window.appearance == nil)
            #expect(window.titlebarAppearsTransparent == true)
            let paper = window.backgroundColor.usingColorSpace(.sRGB)
            #expect(paper != nil && paper!.redComponent > paper!.blueComponent,
                    "auto over a light system is the warm-paper chrome")
        }
    }

    /// Regression: SwiftUI's scene machinery resets `window.appearance` to
    /// nil during its own update passes, un-forcing the theme — invisible
    /// while the system is light, dark chrome over sepia paper after an
    /// overnight system dark flip. The manager must re-assert immediately.
    @Test func reassertsForcedAppearanceAfterExternalReset() {
        withManager { manager in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            manager.register(window)
            manager.current = .sepia
            #expect(window.appearance?.name == .aqua)

            window.appearance = nil
            #expect(window.appearance?.name == .aqua)
            #expect(window.titlebarAppearsTransparent == true)

            window.appearance = NSAppearance(named: .darkAqua)
            #expect(window.appearance?.name == .aqua)

            // `.auto` demands inherit — external appearance is not fought,
            // and our own nil assignment doesn't recurse.
            manager.current = .auto
            #expect(window.appearance == nil)
        }
    }

    /// The system flip is tracked by KVO on NSApp.effectiveAppearance (the
    /// distributed notification can be dropped across sleep). Forcing
    /// NSApp.appearance is how a test flips the effective appearance.
    @Test func tracksSystemFlipViaEffectiveAppearanceKVO() {
        withManager { manager in
            let app = NSApplication.shared
            defer { app.appearance = nil }

            app.appearance = NSAppearance(named: .darkAqua)
            #expect(manager.systemIsDark == true)

            app.appearance = NSAppearance(named: .aqua)
            #expect(manager.systemIsDark == false)
        }
    }
}

/// Recoloring the PDF's own hyperref link boxes to the theme secondary.
@Suite("Link box colorizer")
@MainActor
struct LinkBoxColorizerTests {
    /// A one-page document with one bordered Link annotation (red) and one
    /// borderless Link annotation.
    private func makeDocument() -> (PDFDocument, bordered: PDFAnnotation, borderless: PDFAnnotation) {
        let page = PDFPage()

        let bordered = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 60, height: 16),
            forType: .link, withProperties: nil
        )
        let border = PDFBorder()
        border.lineWidth = 1
        bordered.border = border
        bordered.color = .red
        page.addAnnotation(bordered)

        let borderless = PDFAnnotation(
            bounds: CGRect(x: 10, y: 40, width: 60, height: 16),
            forType: .link, withProperties: nil
        )
        borderless.color = .red
        page.addAnnotation(borderless)

        let document = PDFDocument()
        document.insert(page, at: 0)
        return (document, bordered, borderless)
    }

    private func rgb(_ color: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color?.usingColorSpace(.sRGB) ?? .clear
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    @Test func recolorsBorderedLinksToThemeHighlight() {
        let (document, bordered, _) = makeDocument()
        LinkBoxColorizer.apply(DesignPalette.dracula.linkBox, to: document)
        // Dracula's highlight is its purple accent #BD93F9 — blue highest,
        // red mid, green lowest.
        let (r, g, b) = rgb(bordered.color)
        #expect(b > 0.9 && r > 0.6 && g < r && g < b)
    }

    @Test func leavesBorderlessLinksUntouched() {
        let (document, _, borderless) = makeDocument()
        LinkBoxColorizer.apply(DesignPalette.dracula.linkBox, to: document)
        // Still the original red (no border → not an author-drawn box).
        let (r, g, b) = rgb(borderless.color)
        #expect(r > 0.9 && g < 0.2 && b < 0.2)
    }

    /// The per-color marker makes a repeat apply a no-op, so a plain tab
    /// switch (same theme) never re-walks — but a new color does re-apply.
    @Test func idempotentPerColorButReappliesOnChange() {
        let (document, bordered, _) = makeDocument()
        LinkBoxColorizer.apply(DesignPalette.bluefold.linkBox, to: document)

        // Same color again is a no-op: our out-of-band change survives.
        bordered.color = .green
        LinkBoxColorizer.apply(DesignPalette.bluefold.linkBox, to: document)
        let (r, g, b) = rgb(bordered.color)
        #expect(g > 0.9 && r < 0.2 && b < 0.2)

        // A different theme color re-walks and recolors (Nord frost #88C0D0:
        // its accent/highlight — blue ≈ green, both above red).
        LinkBoxColorizer.apply(DesignPalette.nord.linkBox, to: document)
        let (r2, g2, b2) = rgb(bordered.color)
        #expect(b2 > 0.7 && g2 > 0.6 && r2 < g2, "recolored to Nord frost #88C0D0")
    }
}
#endif
