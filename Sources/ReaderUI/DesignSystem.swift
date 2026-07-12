import ReaderCore
import SwiftUI

#if os(macOS)
import AppKit
/// AppKit/UIKit color, so one palette definition serves both platforms.
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

/// The "Cloth & Paper" design language (Bluefold final mockup, 2026-07):
/// warm paper chrome in light/sepia, a deep-navy chrome band in dark, one
/// blue accent, serif display headings, and per-book tint colors that carry
/// through tab lozenges and generated covers.
///
/// Everything here is keyed off the RESOLVED theme (auto already collapsed
/// to light/dark), so views ask `DesignPalette.current` (or
/// `palette(for:)`) and re-evaluate through ThemeManager's observability.
public struct DesignPalette: Sendable {
    // Chrome (titlebar, tab strip band, status bar)
    public let chromeTop: PlatformColor
    public let chromeBottom: PlatformColor
    public let chromeBorder: PlatformColor
    /// Tab strip band background (slightly deeper than the titlebar).
    public let stripBackground: PlatformColor
    /// Ink used for chrome text/icons (deep navy on paper, warm gray on dark).
    public let ink: PlatformColor

    // Content
    public let contentBackground: PlatformColor
    public let sidebarBackground: PlatformColor
    public let sidebarBorder: PlatformColor
    public let textPrimary: PlatformColor
    public let textSecondary: PlatformColor
    /// Muted section-label color (uppercase sidebar headers, counts).
    public let textMuted: PlatformColor

    // Accent
    public let accent: PlatformColor
    /// Soft accent fill for selected rows / active singleton lozenges.
    public let accentSoft: PlatformColor

    /// Fill of the ACTIVE chapter cell inside a tab lozenge — "the
    /// divider's ink" per the mockup: translucent ink, not accent.
    public let activeCellFill: PlatformColor
    /// Hairline divider inside a lozenge.
    public let lozengeDivider: PlatformColor

    public static let light = DesignPalette(
        chromeTop: PlatformColor(hex: 0xF2EBE2),
        chromeBottom: PlatformColor(hex: 0xE8E0D5),
        chromeBorder: PlatformColor(hex: 0xD9D0C4),
        stripBackground: PlatformColor(hex: 0xEDE6DC),
        ink: PlatformColor(hex: 0x0E2849),
        contentBackground: PlatformColor(hex: 0xFEFEFD),
        sidebarBackground: PlatformColor(hex: 0xF2EBE2),
        sidebarBorder: PlatformColor(hex: 0xE2D9CD),
        textPrimary: PlatformColor(hex: 0x2A2620),
        textSecondary: PlatformColor(hex: 0x4A4034),
        textMuted: PlatformColor(hex: 0xA89A86),
        accent: PlatformColor(hex: 0x2E7FE5),
        accentSoft: PlatformColor(hex: 0x2E7FE5, alpha: 0.13),
        activeCellFill: PlatformColor(hex: 0x0E2849, alpha: 0.14),
        lozengeDivider: PlatformColor(hex: 0x0E2849, alpha: 0.14)
    )

    public static let dark = DesignPalette(
        chromeTop: PlatformColor(hex: 0x1A2C47),
        chromeBottom: PlatformColor(hex: 0x132037),
        chromeBorder: PlatformColor(hex: 0x0A1626),
        stripBackground: PlatformColor(hex: 0x15233B),
        ink: PlatformColor(hex: 0xE3DEDA),
        contentBackground: PlatformColor(hex: 0x1B1A18),
        sidebarBackground: PlatformColor(hex: 0x201E1B),
        sidebarBorder: PlatformColor(hex: 0x2C2926),
        textPrimary: PlatformColor(hex: 0xD8D2C8),
        textSecondary: PlatformColor(hex: 0xCBC3B8),
        textMuted: PlatformColor(hex: 0x7D7364),
        accent: PlatformColor(hex: 0x7FB0F2),
        accentSoft: PlatformColor(hex: 0x2E7FE5, alpha: 0.22),
        activeCellFill: PlatformColor(white: 1, alpha: 0.14),
        lozengeDivider: PlatformColor(white: 1, alpha: 0.16)
    )

    public static let sepia = DesignPalette(
        chromeTop: PlatformColor(hex: 0xEEE1CE),
        chromeBottom: PlatformColor(hex: 0xE5D6BD),
        chromeBorder: PlatformColor(hex: 0xDBC9AC),
        stripBackground: PlatformColor(hex: 0xEBDDC8),
        ink: PlatformColor(hex: 0x4A3A24),
        contentBackground: PlatformColor(hex: 0xF5EDE1),
        sidebarBackground: PlatformColor(hex: 0xEEE1CE),
        sidebarBorder: PlatformColor(hex: 0xDBC9AC),
        textPrimary: PlatformColor(hex: 0x3A2F24),
        textSecondary: PlatformColor(hex: 0x4A3A24),
        textMuted: PlatformColor(hex: 0xA08A6A),
        accent: PlatformColor(hex: 0x2E7FE5),
        accentSoft: PlatformColor(hex: 0x2E7FE5, alpha: 0.15),
        activeCellFill: PlatformColor(hex: 0x5A3C1E, alpha: 0.2),
        lozengeDivider: PlatformColor(hex: 0x5A3C1E, alpha: 0.24)
    )

    public static func palette(for theme: AppTheme) -> DesignPalette {
        switch theme {
        case .dark: .dark
        case .sepia: .sepia
        case .light, .auto: .light
        }
    }

    #if os(macOS)
    /// Palette of the live resolved theme. Reading this inside a SwiftUI
    /// body (or anything observing ThemeManager) tracks theme changes.
    /// macOS-only: iOS resolves through its own ThemeStore and calls
    /// `palette(for:)` directly.
    @MainActor
    public static var current: DesignPalette {
        palette(for: ThemeManager.shared.resolvedTheme)
    }
    #endif
}

/// Stable per-book tint colors — the mockup's generated-cover palette. The
/// same book always hashes to the same swatch, so its tab lozenge and
/// library cover agree across windows and launches.
public enum BookTint {
    /// (cover fill, works-on-it text is light?) — cover palette from the
    /// BookGrid mockup: navy, kraft, blue, brick, paper-white, warm paper.
    public static let covers: [(PlatformColor, lightText: Bool)] = [
        (PlatformColor(hex: 0x0E2849), true),   // navy
        (PlatformColor(hex: 0xD2B090), false),  // kraft
        (PlatformColor(hex: 0x2E7FE5), true),   // blue
        (PlatformColor(hex: 0x8C2F27), true),   // brick
        (PlatformColor(hex: 0x4E6E58), true),   // moss
        (PlatformColor(hex: 0xB58A3C), false),  // ochre
    ]

    /// Deterministic tint for a book path (FNV-1a; Hasher is seeded per
    /// process, which would reshuffle colors every launch).
    public static func color(forPath path: String) -> PlatformColor {
        cover(forPath: path).0
    }

    /// Tint plus whether light text reads on it (generated covers).
    public static func cover(forPath path: String) -> (PlatformColor, lightText: Bool) {
        covers[Int(mix(fnv1a(path)) % UInt64(covers.count))]
    }

    /// splitmix64 finalizer. Raw FNV-1a's LOW bits are dominated by the
    /// last bytes hashed — every path ends ".pdf", so `% count` was
    /// funneling whole libraries into one bucket (observed: three fixture
    /// books, one color). The avalanche spreads the tail through all bits.
    public static func mix(_ value: UInt64) -> UInt64 {
        var hash = value
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        return hash ^ (hash >> 31)
    }

    public static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

extension PlatformColor {
    /// sRGB color from 0xRRGGBB.
    public convenience init(hex: UInt32, alpha: CGFloat = 1) {
        #if os(macOS)
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
        #else
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
        #endif
    }
}

// MARK: - SwiftUI bridge

extension Color {
    /// Bridges the palette's platform color to SwiftUI on either OS.
    public init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}

extension DesignPalette {
    public var chromeTopColor: Color { Color(platformColor: chromeTop) }
    public var chromeBottomColor: Color { Color(platformColor: chromeBottom) }
    public var chromeBorderColor: Color { Color(platformColor: chromeBorder) }
    public var stripBackgroundColor: Color { Color(platformColor: stripBackground) }
    public var inkColor: Color { Color(platformColor: ink) }
    public var contentBackgroundColor: Color { Color(platformColor: contentBackground) }
    public var sidebarBackgroundColor: Color { Color(platformColor: sidebarBackground) }
    public var sidebarBorderColor: Color { Color(platformColor: sidebarBorder) }
    public var textPrimaryColor: Color { Color(platformColor: textPrimary) }
    public var textSecondaryColor: Color { Color(platformColor: textSecondary) }
    public var textMutedColor: Color { Color(platformColor: textMuted) }
    public var accentColor: Color { Color(platformColor: accent) }
    public var accentSoftColor: Color { Color(platformColor: accentSoft) }

    /// Chrome band (titlebar/status bar) vertical gradient.
    public var chromeGradient: LinearGradient {
        LinearGradient(
            colors: [chromeTopColor, chromeBottomColor],
            startPoint: .top, endPoint: .bottom
        )
    }
}
