import Foundation

/// The app-wide visual theme. Concrete colors and PDF page render filters are
/// resolved in the UI layer; ReaderCore only defines the identity so it can be
/// persisted and synced.
public enum AppTheme: String, Codable, CaseIterable, Equatable, Sendable {
    case light
    case dark
    case sepia

    /// How PDF page content should be filtered when rendering under this theme.
    public var pageRenderFilter: PageRenderFilter {
        switch self {
        case .light: .none
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
