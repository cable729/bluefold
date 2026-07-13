import Foundation

/// The app-wide visual theme. Concrete colors and PDF page render filters are
/// resolved in the UI layer; ReaderCore only defines the identity so it can be
/// persisted and synced.
public enum AppTheme: String, Codable, CaseIterable, Equatable, Sendable {
    case light
    case dark
    case sepia
    /// Follows the system appearance. Raw values are persisted (UserDefaults,
    /// session.json) — never rename the existing cases; only append.
    case auto
    // Coding-world reading palettes + the Bluefold signature. Appended after
    // `auto`; raw values are persisted, so these must never be renamed either.
    case solarizedLight
    case solarizedDark
    case nord
    case gruvbox
    case dracula
    /// Bluefold's own "blue-hour" theme: brand navy paper, blue accent.
    case bluefold
    /// Foldblue: Bluefold's LIGHT signature — warm aussie-brown paper (a
    /// browner sepia) with the icon's light blue as accent.
    case foldblue
    /// Gruvbox Light — the warm retro cream companion to Gruvbox (dark).
    case gruvboxLight

    /// Concrete themes resolve to themselves; `.auto` delegates to the
    /// system appearance (plain light/dark — the theme managers layer the
    /// remembered per-family choices on top via `resolved(systemIsDark:last…)`).
    public func resolved(systemIsDark: Bool) -> AppTheme {
        resolved(systemIsDark: systemIsDark, lastLight: .light, lastDark: .dark)
    }

    /// Resolves `.auto` against the user's remembered per-family choices: the
    /// last light-family theme picked (used while the system is light) and the
    /// last dark-family theme (used while the system is dark). Concrete themes
    /// resolve to themselves. The result is never `.auto`.
    public func resolved(
        systemIsDark: Bool, lastLight: AppTheme, lastDark: AppTheme
    ) -> AppTheme {
        guard self == .auto else { return self }
        return systemIsDark ? lastDark : lastLight
    }

    /// Concrete themes grouped by chrome family, for pickers that offer
    /// Light/Dark sections. `.auto` is offered separately (above the groups)
    /// as the recommended default, so it appears in neither list.
    public static let lightFamily: [AppTheme] = [
        .foldblue, .light, .gruvboxLight, .solarizedLight, .sepia,
    ]
    public static let darkFamily: [AppTheme] = [
        .bluefold, .dark, .gruvbox, .solarizedDark, .dracula, .nord,
    ]

    /// Human-facing label (raw values are camelCase for compound themes, so
    /// `rawValue.capitalized` won't do). Drives the Settings picker, the
    /// status-bar menu, and the generated View-menu commands.
    public var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        case .auto: "Auto"
        case .solarizedLight: "Solarized Light"
        case .solarizedDark: "Solarized Dark"
        case .nord: "Nord"
        case .gruvbox: "Gruvbox"
        case .dracula: "Dracula"
        case .bluefold: "Bluefold"
        case .foldblue: "Foldblue"
        case .gruvboxLight: "Gruvbox Light"
        }
    }

    /// Whether this theme reads as a dark surface — light-family themes force
    /// `.aqua` window chrome, dark-family force `.darkAqua`. `.auto` is neither
    /// (it inherits the system appearance); callers must resolve it first.
    public var isDark: Bool {
        switch self {
        case .light, .sepia, .foldblue, .solarizedLight, .gruvboxLight, .auto: false
        case .dark, .solarizedDark, .nord, .gruvbox, .dracula, .bluefold: true
        }
    }

    /// How PDF page content should be filtered when rendering under this
    /// theme. `.auto` must be resolved first via `resolved(systemIsDark:)`;
    /// unresolved it falls back to rendering as authored.
    public var pageRenderFilter: PageRenderFilter {
        switch self {
        case .light, .auto: .none
        case .dark: .invert
        case .sepia: .multiply(PageTint(hex: 0xF5EDE1))
        case .solarizedLight: .multiply(PageTint(hex: 0xFDF6E3))
        case .solarizedDark: .invertTinted(PageTint(hex: 0x002B36))
        case .nord: .invertTinted(PageTint(hex: 0x2E3440))
        case .gruvbox: .invertTinted(PageTint(hex: 0x282828))
        case .dracula: .invertTinted(PageTint(hex: 0x282A36))
        case .bluefold: .invertTinted(PageTint(hex: 0x0E2849))
        // Warm aussie-brown paper — browner/deeper than sepia's #F5EDE1.
        case .foldblue: .multiply(PageTint(hex: 0xF1E3CC))
        case .gruvboxLight: .multiply(PageTint(hex: 0xFBF1C7))
        }
    }
}

/// An sRGB tint (0…1 components) applied to PDF page content by a render
/// filter. Pure values — no CoreGraphics dependency, so it lives in ReaderCore.
public struct PageTint: Equatable, Sendable {
    public let red, green, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 0xRRGGBB.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Rendering treatment applied to PDF page content (not just UI chrome).
/// Runtime-derived from `AppTheme` (never persisted), so it is free to carry
/// associated tints rather than being a stable string-backed enum.
public enum PageRenderFilter: Equatable, Sendable {
    /// Render as authored.
    case none
    /// Multiply a warm/cool tint onto light pages (sepia, Solarized Light):
    /// white paper takes the tint, black ink stays black.
    case multiply(PageTint)
    /// Difference-blend inversion for neutral dark reading.
    case invert
    /// Invert, then lift the now-black background up to a tint (Solarized
    /// Dark, Nord, Gruvbox, Dracula, Bluefold): the page becomes tinted-dark
    /// paper with light text.
    case invertTinted(PageTint)
}
