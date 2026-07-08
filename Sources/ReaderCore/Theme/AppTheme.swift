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

    /// Concrete themes resolve to themselves; `.auto` delegates to the
    /// system appearance. The result is never `.auto`.
    public func resolved(systemIsDark: Bool) -> AppTheme {
        self == .auto ? (systemIsDark ? .dark : .light) : self
    }

    /// How PDF page content should be filtered when rendering under this
    /// theme. `.auto` must be resolved first via `resolved(systemIsDark:)`;
    /// unresolved it falls back to rendering as authored.
    public var pageRenderFilter: PageRenderFilter {
        switch self {
        case .light, .auto: .none
        case .dark: .invert
        case .sepia: .warmPaper
        }
    }
}

/// Rendering treatment applied to PDF page content (not just UI chrome).
public enum PageRenderFilter: String, Codable, Equatable, Sendable {
    /// Render as authored.
    case none
    /// Difference-blend inversion for dark reading.
    case invert
    /// Multiply-blend warm paper tone (sepia / "Claude tan").
    case warmPaper
}
