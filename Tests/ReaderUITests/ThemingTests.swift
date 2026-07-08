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
        PageFilterStore.current = .warmPaper
        let color = meanColor(of: page)
        // The Claude-tan paper: warm, red > green > blue, still light.
        #expect(abs(color.red - 0.961) < 0.05)
        #expect(abs(color.blue - 0.882) < 0.05)
        #expect(color.red > color.blue)
    }
}

/// ThemeManager resolution + window-chrome application. Serialized: the
/// manager writes the process-global PageFilterStore and UserDefaults key.
@Suite("Theme manager", .serialized)
@MainActor
struct ThemeManagerTests {
    /// Fresh manager with the persisted key and page filter cleared afterwards.
    private func withManager(_ body: (ThemeManager) throws -> Void) rethrows {
        defer {
            UserDefaults.standard.removeObject(forKey: "PDFReaderTheme")
            PageFilterStore.current = .none
        }
        UserDefaults.standard.removeObject(forKey: "PDFReaderTheme")
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

    @Test func concreteThemeIgnoresSystemFlips() {
        withManager { manager in
            manager.current = .sepia
            manager.overrideSystemAppearance(isDark: true)
            #expect(manager.resolvedTheme == .sepia)
            #expect(PageFilterStore.current == .warmPaper)
        }
    }

    @Test func autoPersistsAndRestores() {
        defer {
            UserDefaults.standard.removeObject(forKey: "PDFReaderTheme")
            PageFilterStore.current = .none
        }
        UserDefaults.standard.removeObject(forKey: "PDFReaderTheme")
        ThemeManager().current = .auto
        #expect(UserDefaults.standard.string(forKey: "PDFReaderTheme") == "auto")
        #expect(ThemeManager().current == .auto)
    }

    @Test func registeredWindowChromeFollowsTheme() {
        withManager { manager in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            manager.register(window)

            manager.current = .dark
            #expect(window.appearance?.name == .darkAqua)
            #expect(window.titlebarAppearsTransparent == false)

            manager.current = .sepia
            #expect(window.appearance?.name == .aqua)
            #expect(window.titlebarAppearsTransparent == true)
            let tan = window.backgroundColor.usingColorSpace(.sRGB)
            #expect(tan != nil && tan!.redComponent > tan!.blueComponent)

            // Auto: inherit (nil appearance) so the window follows the system.
            manager.current = .auto
            #expect(window.appearance == nil)
            #expect(window.titlebarAppearsTransparent == false)
        }
    }
}
#endif
