import Observation
import ReaderCore
import ReaderUI
import SwiftUI
import UIKit

/// iOS theme state: persists the same `BluefoldTheme` UserDefaults key as
/// macOS and writes the shared `PageFilterStore` so `ThemedPDFPage` filters
/// page content (dark = difference-invert, sepia = multiply Claude tan).
///
/// Chrome theming works differently from macOS: instead of an NSWindow
/// registry, the root view applies `preferredColorScheme(_:)`. `.auto`
/// forces nothing, so the environment's color scheme *is* the system's and
/// `noteSystemColorScheme` keeps `systemIsDark` honest; while a theme is
/// forced, the environment reports the forced value and is ignored.
@MainActor
@Observable
final class ThemeStore {
    private static let defaultsKey = "BluefoldTheme"  // shared with macOS

    var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            PageFilterStore.current = resolvedTheme.pageRenderFilter
        }
    }

    /// Whether the SYSTEM appearance is dark, as last observed while no
    /// scheme was forced. `.auto` resolves against this.
    private(set) var systemIsDark: Bool

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let theme = stored.flatMap(AppTheme.init(rawValue:)) ?? .light
        current = theme
        systemIsDark = UITraitCollection.current.userInterfaceStyle == .dark
        PageFilterStore.current = theme.resolved(
            systemIsDark: UITraitCollection.current.userInterfaceStyle == .dark
        ).pageRenderFilter
    }

    /// `current` with `.auto` resolved; never `.auto`. Everything that
    /// renders (page filter, PDF background, the `.id()` keying that
    /// rebuilds PDFViews) keys off this.
    var resolvedTheme: AppTheme {
        current.resolved(systemIsDark: systemIsDark)
    }

    /// Fed by the root view's `colorScheme` environment. Only trusted while
    /// nothing is forced — a forced scheme echoes itself back.
    func noteSystemColorScheme(isDark: Bool) {
        guard current == .auto, systemIsDark != isDark else { return }
        systemIsDark = isDark
        PageFilterStore.current = resolvedTheme.pageRenderFilter
    }

    /// What the root view forces; nil for `.auto` (follow the system).
    var preferredColorScheme: ColorScheme? {
        switch current {
        case .auto: nil
        case .dark: .dark
        case .light, .sepia: .light
        }
    }

    /// PDFView letterbox background per theme.
    var pdfBackground: UIColor {
        switch resolvedTheme {
        case .light, .auto: .systemBackground
        case .dark: UIColor(white: 0.12, alpha: 1)
        case .sepia: UIColor(cgColor: Theme.sepiaPaper)
        }
    }

    static func label(for theme: AppTheme) -> String {
        switch theme {
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        case .auto: "Auto"
        }
    }
}
