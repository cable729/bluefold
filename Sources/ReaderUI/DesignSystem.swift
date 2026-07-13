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
    /// Color for the PDF's own hyperref link-annotation borders (the boxes
    /// around cross-references), recolored to match the theme via
    /// `LinkBoxColorizer`. Set to each theme's `accent` — the SAME color as the
    /// sidebar's selected-section text — so the link boxes read as that accent
    /// (owner request). Bluefold is the one override: warm brown, not its blue
    /// accent. The sidebar itself is NOT driven by this — it keeps using
    /// `accent` directly.
    public let linkBox: PlatformColor

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
        accent: PlatformColor(hex: 0x1E6FDA),
        accentSoft: PlatformColor(hex: 0x1E6FDA, alpha: 0.13),
        linkBox: PlatformColor(hex: 0x1E6FDA),
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
        linkBox: PlatformColor(hex: 0x7FB0F2),
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
        accent: PlatformColor(hex: 0x1E6FDA),
        accentSoft: PlatformColor(hex: 0x1E6FDA, alpha: 0.15),
        linkBox: PlatformColor(hex: 0x1E6FDA),
        activeCellFill: PlatformColor(hex: 0x5A3C1E, alpha: 0.2),
        lozengeDivider: PlatformColor(hex: 0x5A3C1E, alpha: 0.24)
    )

    // MARK: Coding-world palettes + Bluefold signature

    /// Solarized Light — Ethan Schoonover's cream base3 paper, teal-gray ink.
    public static let solarizedLight = DesignPalette(
        chromeTop: PlatformColor(hex: 0xEEE8D5),
        chromeBottom: PlatformColor(hex: 0xE3DCC4),
        chromeBorder: PlatformColor(hex: 0xD5CDB4),
        stripBackground: PlatformColor(hex: 0xE9E2CE),
        ink: PlatformColor(hex: 0x586E75),
        contentBackground: PlatformColor(hex: 0xFDF6E3),
        sidebarBackground: PlatformColor(hex: 0xEEE8D5),
        sidebarBorder: PlatformColor(hex: 0xD5CDB4),
        textPrimary: PlatformColor(hex: 0x073642),
        textSecondary: PlatformColor(hex: 0x586E75),
        textMuted: PlatformColor(hex: 0x93A1A1),
        accent: PlatformColor(hex: 0x268BD2),
        accentSoft: PlatformColor(hex: 0x268BD2, alpha: 0.15),
        linkBox: PlatformColor(hex: 0x268BD2),
        activeCellFill: PlatformColor(hex: 0x586E75, alpha: 0.16),
        lozengeDivider: PlatformColor(hex: 0x586E75, alpha: 0.18)
    )

    /// Solarized Dark — base03 deep-teal paper, low-contrast base0 text.
    public static let solarizedDark = DesignPalette(
        chromeTop: PlatformColor(hex: 0x073642),
        chromeBottom: PlatformColor(hex: 0x042A34),
        chromeBorder: PlatformColor(hex: 0x00212B),
        stripBackground: PlatformColor(hex: 0x052E38),
        ink: PlatformColor(hex: 0x93A1A1),
        contentBackground: PlatformColor(hex: 0x002B36),
        sidebarBackground: PlatformColor(hex: 0x073642),
        sidebarBorder: PlatformColor(hex: 0x0A3D49),
        textPrimary: PlatformColor(hex: 0x93A1A1),
        textSecondary: PlatformColor(hex: 0x839496),
        textMuted: PlatformColor(hex: 0x586E75),
        accent: PlatformColor(hex: 0x268BD2),
        accentSoft: PlatformColor(hex: 0x268BD2, alpha: 0.24),
        linkBox: PlatformColor(hex: 0x268BD2),
        activeCellFill: PlatformColor(white: 1, alpha: 0.12),
        lozengeDivider: PlatformColor(white: 1, alpha: 0.14)
    )

    /// Nord — arctic Polar Night paper, Snow Storm text, Frost accent.
    public static let nord = DesignPalette(
        chromeTop: PlatformColor(hex: 0x3B4252),
        chromeBottom: PlatformColor(hex: 0x333A48),
        chromeBorder: PlatformColor(hex: 0x2B303B),
        stripBackground: PlatformColor(hex: 0x373E4C),
        ink: PlatformColor(hex: 0xD8DEE9),
        contentBackground: PlatformColor(hex: 0x2E3440),
        sidebarBackground: PlatformColor(hex: 0x3B4252),
        sidebarBorder: PlatformColor(hex: 0x434C5E),
        textPrimary: PlatformColor(hex: 0xECEFF4),
        textSecondary: PlatformColor(hex: 0xD8DEE9),
        textMuted: PlatformColor(hex: 0x7B8494),
        accent: PlatformColor(hex: 0x88C0D0),
        accentSoft: PlatformColor(hex: 0x88C0D0, alpha: 0.22),
        linkBox: PlatformColor(hex: 0x88C0D0),
        activeCellFill: PlatformColor(white: 1, alpha: 0.12),
        lozengeDivider: PlatformColor(white: 1, alpha: 0.14)
    )

    /// Gruvbox (dark) — warm-retro dark paper, cream text, orange accent.
    public static let gruvbox = DesignPalette(
        chromeTop: PlatformColor(hex: 0x3C3836),
        chromeBottom: PlatformColor(hex: 0x32302F),
        chromeBorder: PlatformColor(hex: 0x282828),
        stripBackground: PlatformColor(hex: 0x393433),
        ink: PlatformColor(hex: 0xEBDBB2),
        contentBackground: PlatformColor(hex: 0x282828),
        sidebarBackground: PlatformColor(hex: 0x3C3836),
        sidebarBorder: PlatformColor(hex: 0x504945),
        textPrimary: PlatformColor(hex: 0xEBDBB2),
        textSecondary: PlatformColor(hex: 0xD5C4A1),
        textMuted: PlatformColor(hex: 0x928374),
        accent: PlatformColor(hex: 0xFE8019),
        accentSoft: PlatformColor(hex: 0xFE8019, alpha: 0.20),
        linkBox: PlatformColor(hex: 0xFE8019),
        activeCellFill: PlatformColor(white: 1, alpha: 0.10),
        lozengeDivider: PlatformColor(white: 1, alpha: 0.12)
    )

    /// Dracula — dark blue-purple paper, off-white text, purple accent.
    public static let dracula = DesignPalette(
        chromeTop: PlatformColor(hex: 0x44475A),
        chromeBottom: PlatformColor(hex: 0x383A4A),
        chromeBorder: PlatformColor(hex: 0x282A36),
        stripBackground: PlatformColor(hex: 0x3E4152),
        ink: PlatformColor(hex: 0xF8F8F2),
        contentBackground: PlatformColor(hex: 0x282A36),
        sidebarBackground: PlatformColor(hex: 0x343746),
        sidebarBorder: PlatformColor(hex: 0x44475A),
        textPrimary: PlatformColor(hex: 0xF8F8F2),
        textSecondary: PlatformColor(hex: 0xE0E0DC),
        textMuted: PlatformColor(hex: 0x7A85B0),
        accent: PlatformColor(hex: 0xBD93F9),
        accentSoft: PlatformColor(hex: 0xBD93F9, alpha: 0.24),
        linkBox: PlatformColor(hex: 0xBD93F9),
        activeCellFill: PlatformColor(white: 1, alpha: 0.12),
        lozengeDivider: PlatformColor(white: 1, alpha: 0.14)
    )

    /// Bluefold signature — brand navy paper + blue accent (the "blue-hour"
    /// reading theme). Chrome reuses the deep-navy dark band.
    public static let bluefold = DesignPalette(
        chromeTop: PlatformColor(hex: 0x14294A),
        chromeBottom: PlatformColor(hex: 0x0E2038),
        chromeBorder: PlatformColor(hex: 0x081524),
        stripBackground: PlatformColor(hex: 0x11233E),
        ink: PlatformColor(hex: 0xE3DEDA),
        contentBackground: PlatformColor(hex: 0x0E2849),
        sidebarBackground: PlatformColor(hex: 0x11233E),
        sidebarBorder: PlatformColor(hex: 0x1B3A5E),
        textPrimary: PlatformColor(hex: 0xEDE9E3),
        textSecondary: PlatformColor(hex: 0xCBD6E4),
        textMuted: PlatformColor(hex: 0x6E86A6),
        accent: PlatformColor(hex: 0x4A90F0),
        accentSoft: PlatformColor(hex: 0x4A90F0, alpha: 0.24),
        // Bluefold's highlight is the icon's warm page tan/brown (not the
        // blue accent) — the sidebar selection and link boxes read warm
        // against the navy paper (owner request).
        linkBox: PlatformColor(hex: 0xD2B090),
        activeCellFill: PlatformColor(white: 1, alpha: 0.13),
        lozengeDivider: PlatformColor(white: 1, alpha: 0.15)
    )

    /// Foldblue — Bluefold's LIGHT signature: warm aussie-brown paper (browner
    /// than sepia) with the icon's light blue as accent and tan as secondary.
    public static let foldblue = DesignPalette(
        chromeTop: PlatformColor(hex: 0xEADFC8),
        chromeBottom: PlatformColor(hex: 0xE0D2B6),
        chromeBorder: PlatformColor(hex: 0xD3C0A0),
        stripBackground: PlatformColor(hex: 0xE6DAC1),
        ink: PlatformColor(hex: 0x14385F),
        contentBackground: PlatformColor(hex: 0xF1E3CC),
        sidebarBackground: PlatformColor(hex: 0xEADFC8),
        sidebarBorder: PlatformColor(hex: 0xD3C0A0),
        textPrimary: PlatformColor(hex: 0x33291B),
        textSecondary: PlatformColor(hex: 0x5A4A34),
        textMuted: PlatformColor(hex: 0xA5906E),
        accent: PlatformColor(hex: 0x1E6FDA),
        accentSoft: PlatformColor(hex: 0x1E6FDA, alpha: 0.15),
        linkBox: PlatformColor(hex: 0x1E6FDA),
        activeCellFill: PlatformColor(hex: 0x5A3C1E, alpha: 0.18),
        lozengeDivider: PlatformColor(hex: 0x5A3C1E, alpha: 0.22)
    )

    /// Gruvbox Light — the warm retro cream companion to Gruvbox (dark),
    /// with a deep-teal accent.
    public static let gruvboxLight = DesignPalette(
        chromeTop: PlatformColor(hex: 0xEBDBB2),
        chromeBottom: PlatformColor(hex: 0xE3D3A7),
        chromeBorder: PlatformColor(hex: 0xD5C4A1),
        stripBackground: PlatformColor(hex: 0xE8D8AE),
        ink: PlatformColor(hex: 0x3C3836),
        contentBackground: PlatformColor(hex: 0xFBF1C7),
        sidebarBackground: PlatformColor(hex: 0xEBDBB2),
        sidebarBorder: PlatformColor(hex: 0xD5C4A1),
        textPrimary: PlatformColor(hex: 0x3C3836),
        textSecondary: PlatformColor(hex: 0x504945),
        textMuted: PlatformColor(hex: 0x928374),
        accent: PlatformColor(hex: 0x076678),
        accentSoft: PlatformColor(hex: 0x076678, alpha: 0.14),
        linkBox: PlatformColor(hex: 0x076678),
        activeCellFill: PlatformColor(hex: 0x504945, alpha: 0.16),
        lozengeDivider: PlatformColor(hex: 0x504945, alpha: 0.18)
    )

    public static func palette(for theme: AppTheme) -> DesignPalette {
        switch theme {
        case .dark: .dark
        case .sepia: .sepia
        case .light, .auto: .light
        case .solarizedLight: .solarizedLight
        case .solarizedDark: .solarizedDark
        case .nord: .nord
        case .gruvbox: .gruvbox
        case .dracula: .dracula
        case .bluefold: .bluefold
        case .foldblue: .foldblue
        case .gruvboxLight: .gruvboxLight
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
    public var linkBoxColor: Color { Color(platformColor: linkBox) }

    /// Chrome band (titlebar/status bar) vertical gradient.
    public var chromeGradient: LinearGradient {
        LinearGradient(
            colors: [chromeTopColor, chromeBottomColor],
            startPoint: .top, endPoint: .bottom
        )
    }
}
