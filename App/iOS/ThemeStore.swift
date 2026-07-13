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
    private static let lastLightKey = "BluefoldLastLightTheme"
    private static let lastDarkKey = "BluefoldLastDarkTheme"

    var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            rememberFamilyChoice(current)
            PageFilterStore.current = resolvedTheme.pageRenderFilter
        }
    }

    /// Remembered per-family choices — `.auto` resolves to the last light-
    /// family theme by day and the last dark-family theme by night (matches
    /// macOS `ThemeManager`). Persisted under keys shared with macOS.
    private(set) var lastLightTheme: AppTheme {
        didSet { UserDefaults.standard.set(lastLightTheme.rawValue, forKey: Self.lastLightKey) }
    }
    private(set) var lastDarkTheme: AppTheme {
        didSet { UserDefaults.standard.set(lastDarkTheme.rawValue, forKey: Self.lastDarkKey) }
    }

    /// Whether the SYSTEM appearance is dark, as last observed while no
    /// scheme was forced. `.auto` resolves against this.
    private(set) var systemIsDark: Bool

    init() {
        let defaults = UserDefaults.standard
        let theme = defaults.string(forKey: Self.defaultsKey).flatMap(AppTheme.init(rawValue:)) ?? .light
        current = theme
        let storedLight = defaults.string(forKey: Self.lastLightKey).flatMap(AppTheme.init(rawValue:))
        let storedDark = defaults.string(forKey: Self.lastDarkKey).flatMap(AppTheme.init(rawValue:))
        lastLightTheme = storedLight ?? (!theme.isDark && theme != .auto ? theme : .light)
        lastDarkTheme = storedDark ?? (theme.isDark ? theme : .dark)
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        systemIsDark = isDark
        PageFilterStore.current = theme.resolved(
            systemIsDark: isDark, lastLight: lastLightTheme, lastDark: lastDarkTheme
        ).pageRenderFilter
    }

    /// `current` with `.auto` resolved against the system appearance and the
    /// remembered per-family choices; never `.auto`. Everything that renders
    /// (page filter, PDF background, the `.id()` keying that rebuilds
    /// PDFViews) keys off this.
    var resolvedTheme: AppTheme {
        current.resolved(
            systemIsDark: systemIsDark, lastLight: lastLightTheme, lastDark: lastDarkTheme
        )
    }

    /// Secondary color for the current theme — recolors the PDF's own link
    /// boxes (see `LinkBoxColorizer`).
    var linkBox: UIColor {
        DesignPalette.palette(for: resolvedTheme).linkBox
    }

    private func rememberFamilyChoice(_ theme: AppTheme) {
        guard theme != .auto else { return }
        if theme.isDark {
            if lastDarkTheme != theme { lastDarkTheme = theme }
        } else if lastLightTheme != theme {
            lastLightTheme = theme
        }
    }

    /// Fed by the root view's `colorScheme` environment. Only trusted while
    /// nothing is forced — a forced scheme echoes itself back.
    func noteSystemColorScheme(isDark: Bool) {
        guard current == .auto, systemIsDark != isDark else { return }
        systemIsDark = isDark
        PageFilterStore.current = resolvedTheme.pageRenderFilter
    }

    /// What the root view forces; nil for `.auto` (follow the system). Every
    /// concrete theme forces its family's scheme (light-family → light,
    /// dark-family → dark).
    var preferredColorScheme: ColorScheme? {
        current == .auto ? nil : (current.isDark ? .dark : .light)
    }

    /// PDFView letterbox background — the theme's page paper, so the letterbox
    /// reads as the page's mat (matches macOS `ThemeManager.pdfBackground`).
    var pdfBackground: UIColor {
        DesignPalette.palette(for: resolvedTheme).contentBackground
    }

    static func label(for theme: AppTheme) -> String {
        theme.displayName
    }
}
