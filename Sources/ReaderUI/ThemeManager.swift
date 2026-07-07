#if os(macOS)
import AppKit
import Observation
import os
import PDFKit
import ReaderCore

/// App-wide theme state, persisted in UserDefaults.
@MainActor
@Observable
public final class ThemeManager {
    public static let shared = ThemeManager()

    private static let defaultsKey = "PDFReaderTheme"

    public var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            PageFilterStore.current = current.pageRenderFilter
        }
    }

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        current = stored.flatMap(AppTheme.init(rawValue:)) ?? .light
        PageFilterStore.current = current.pageRenderFilter
    }

    /// PDFView letterbox background per theme.
    public var pdfBackground: NSColor {
        switch current {
        case .light: .windowBackgroundColor
        case .dark: NSColor(calibratedWhite: 0.12, alpha: 1)
        case .sepia: NSColor(cgColor: Theme.sepiaPaper) ?? .white
        }
    }
}

/// Semantic theme colors. Sepia is the "Claude tan" reading palette.
public enum Theme {
    /// Warm paper tone multiplied onto PDF pages in sepia mode (#F5EDE1).
    public static let sepiaPaper = CGColor(red: 0.961, green: 0.929, blue: 0.882, alpha: 1)
}

/// The page render filter, readable from ANY thread — PDFKit draws page
/// tiles off the main thread, so this must not live on a MainActor type.
enum PageFilterStore {
    private static let lock = OSAllocatedUnfairLock(initialState: PageRenderFilter.none)

    static var current: PageRenderFilter {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Every page of every document the provider loads is this class
/// (via PDFDocumentDelegate.classForPage), so themes apply to page CONTENT:
/// sepia multiplies warm paper onto white; dark difference-inverts.
/// The same blend-mode approach works on iOS, unlike CALayer.filters.
final class ThemedPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)

        let filter = PageFilterStore.current
        guard filter != .none else { return }

        let rect = bounds(for: box)
        context.saveGState()
        switch filter {
        case .invert:
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
        case .warmPaper:
            context.setBlendMode(.multiply)
            context.setFillColor(Theme.sepiaPaper)
        case .none:
            break
        }
        context.fill(rect)
        context.restoreGState()
    }
}

/// PDFDocumentDelegate hook that swaps in ThemedPDFPage. PDFDocument holds
/// its delegate weakly, so the provider retains this.
final class PageClassProvider: NSObject, PDFDocumentDelegate {
    // Stateless; safe to share across isolation domains.
    nonisolated(unsafe) static let shared = PageClassProvider()

    func classForPage() -> AnyClass {
        ThemedPDFPage.self
    }
}
#endif
