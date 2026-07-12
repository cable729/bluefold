#if os(macOS)
import AppKit
import ReaderCore
import SwiftUI

/// The "Cloth & Paper" design language (Bluefold final mockup, 2026-07):
/// warm paper chrome in light/sepia, a deep-navy chrome band in dark, one
/// blue accent, serif display headings, and per-book tint colors that carry
/// through tab lozenges and generated covers.
///
/// Everything here is keyed off the RESOLVED theme (auto already collapsed
/// to light/dark), so views ask `DesignPalette.current` (or
/// `palette(for:)`) and re-evaluate through ThemeManager's observability.
struct DesignPalette {
    // Chrome (titlebar, tab strip band, status bar)
    let chromeTop: NSColor
    let chromeBottom: NSColor
    let chromeBorder: NSColor
    /// Tab strip band background (slightly deeper than the titlebar).
    let stripBackground: NSColor
    /// Ink used for chrome text/icons (deep navy on paper, warm gray on dark).
    let ink: NSColor

    // Content
    let contentBackground: NSColor
    let sidebarBackground: NSColor
    let sidebarBorder: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    /// Muted section-label color (uppercase sidebar headers, counts).
    let textMuted: NSColor

    // Accent
    let accent: NSColor
    /// Soft accent fill for selected rows / active singleton lozenges.
    let accentSoft: NSColor

    /// Fill of the ACTIVE chapter cell inside a tab lozenge — "the
    /// divider's ink" per the mockup: translucent ink, not accent.
    let activeCellFill: NSColor
    /// Hairline divider inside a lozenge.
    let lozengeDivider: NSColor

    static let light = DesignPalette(
        chromeTop: NSColor(hex: 0xF2EBE2),
        chromeBottom: NSColor(hex: 0xE8E0D5),
        chromeBorder: NSColor(hex: 0xD9D0C4),
        stripBackground: NSColor(hex: 0xEDE6DC),
        ink: NSColor(hex: 0x0E2849),
        contentBackground: NSColor(hex: 0xFEFEFD),
        sidebarBackground: NSColor(hex: 0xF2EBE2),
        sidebarBorder: NSColor(hex: 0xE2D9CD),
        textPrimary: NSColor(hex: 0x2A2620),
        textSecondary: NSColor(hex: 0x4A4034),
        textMuted: NSColor(hex: 0xA89A86),
        accent: NSColor(hex: 0x2E7FE5),
        accentSoft: NSColor(hex: 0x2E7FE5, alpha: 0.13),
        activeCellFill: NSColor(hex: 0x0E2849, alpha: 0.14),
        lozengeDivider: NSColor(hex: 0x0E2849, alpha: 0.14)
    )

    static let dark = DesignPalette(
        chromeTop: NSColor(hex: 0x1A2C47),
        chromeBottom: NSColor(hex: 0x132037),
        chromeBorder: NSColor(hex: 0x0A1626),
        stripBackground: NSColor(hex: 0x15233B),
        ink: NSColor(hex: 0xE3DEDA),
        contentBackground: NSColor(hex: 0x1B1A18),
        sidebarBackground: NSColor(hex: 0x201E1B),
        sidebarBorder: NSColor(hex: 0x2C2926),
        textPrimary: NSColor(hex: 0xD8D2C8),
        textSecondary: NSColor(hex: 0xCBC3B8),
        textMuted: NSColor(hex: 0x7D7364),
        accent: NSColor(hex: 0x7FB0F2),
        accentSoft: NSColor(hex: 0x2E7FE5, alpha: 0.22),
        activeCellFill: NSColor(white: 1, alpha: 0.14),
        lozengeDivider: NSColor(white: 1, alpha: 0.16)
    )

    static let sepia = DesignPalette(
        chromeTop: NSColor(hex: 0xEEE1CE),
        chromeBottom: NSColor(hex: 0xE5D6BD),
        chromeBorder: NSColor(hex: 0xDBC9AC),
        stripBackground: NSColor(hex: 0xEBDDC8),
        ink: NSColor(hex: 0x4A3A24),
        contentBackground: NSColor(hex: 0xF5EDE1),
        sidebarBackground: NSColor(hex: 0xEEE1CE),
        sidebarBorder: NSColor(hex: 0xDBC9AC),
        textPrimary: NSColor(hex: 0x3A2F24),
        textSecondary: NSColor(hex: 0x4A3A24),
        textMuted: NSColor(hex: 0xA08A6A),
        accent: NSColor(hex: 0x2E7FE5),
        accentSoft: NSColor(hex: 0x2E7FE5, alpha: 0.15),
        activeCellFill: NSColor(hex: 0x5A3C1E, alpha: 0.2),
        lozengeDivider: NSColor(hex: 0x5A3C1E, alpha: 0.24)
    )

    static func palette(for theme: AppTheme) -> DesignPalette {
        switch theme {
        case .dark: .dark
        case .sepia: .sepia
        case .light, .auto: .light
        }
    }

    /// Palette of the live resolved theme. Reading this inside a SwiftUI
    /// body (or anything observing ThemeManager) tracks theme changes.
    @MainActor
    static var current: DesignPalette {
        palette(for: ThemeManager.shared.resolvedTheme)
    }
}

/// Stable per-book tint colors — the mockup's generated-cover palette. The
/// same book always hashes to the same swatch, so its tab lozenge and
/// library cover agree across windows and launches.
enum BookTint {
    /// (cover fill, works-on-it text is light?) — cover palette from the
    /// BookGrid mockup: navy, kraft, blue, brick, paper-white, warm paper.
    static let covers: [(NSColor, lightText: Bool)] = [
        (NSColor(hex: 0x0E2849), true),   // navy
        (NSColor(hex: 0xD2B090), false),  // kraft
        (NSColor(hex: 0x2E7FE5), true),   // blue
        (NSColor(hex: 0x8C2F27), true),   // brick
        (NSColor(hex: 0x4E6E58), true),   // moss
        (NSColor(hex: 0xB58A3C), false),  // ochre
    ]

    /// Deterministic tint for a book path (FNV-1a; Hasher is seeded per
    /// process, which would reshuffle colors every launch).
    static func color(forPath path: String) -> NSColor {
        cover(forPath: path).0
    }

    /// Tint plus whether light text reads on it (generated covers).
    static func cover(forPath path: String) -> (NSColor, lightText: Bool) {
        covers[Int(mix(fnv1a(path)) % UInt64(covers.count))]
    }

    /// splitmix64 finalizer. Raw FNV-1a's LOW bits are dominated by the
    /// last bytes hashed — every path ends ".pdf", so `% count` was
    /// funneling whole libraries into one bucket (observed: three fixture
    /// books, one color). The avalanche spreads the tail through all bits.
    static func mix(_ value: UInt64) -> UInt64 {
        var hash = value
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        return hash ^ (hash >> 31)
    }

    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

extension NSColor {
    /// sRGB color from 0xRRGGBB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - SwiftUI bridge

extension DesignPalette {
    var chromeTopColor: Color { Color(nsColor: chromeTop) }
    var chromeBottomColor: Color { Color(nsColor: chromeBottom) }
    var chromeBorderColor: Color { Color(nsColor: chromeBorder) }
    var stripBackgroundColor: Color { Color(nsColor: stripBackground) }
    var inkColor: Color { Color(nsColor: ink) }
    var contentBackgroundColor: Color { Color(nsColor: contentBackground) }
    var sidebarBackgroundColor: Color { Color(nsColor: sidebarBackground) }
    var sidebarBorderColor: Color { Color(nsColor: sidebarBorder) }
    var textPrimaryColor: Color { Color(nsColor: textPrimary) }
    var textSecondaryColor: Color { Color(nsColor: textSecondary) }
    var textMutedColor: Color { Color(nsColor: textMuted) }
    var accentColor: Color { Color(nsColor: accent) }
    var accentSoftColor: Color { Color(nsColor: accentSoft) }

    /// Chrome band (titlebar/status bar) vertical gradient.
    var chromeGradient: LinearGradient {
        LinearGradient(
            colors: [chromeTopColor, chromeBottomColor],
            startPoint: .top, endPoint: .bottom
        )
    }
}
#endif
