#if os(macOS)
import AppKit
import SwiftUI

/// Tag display colors (feedback round 7).
///
/// The store keeps a nullable "#RRGGBB" hex string on `tag`; this type owns
/// the presentation side — the preset palette offered in the tag context
/// menu, hex parsing, and the colored swatch images menus need. Keeping the
/// palette out of the schema means new presets never require a migration,
/// and any valid hex arriving via sync still renders.
public enum TagColor {
    /// One preset swatch in the tag context menu's Color submenu.
    public struct Preset: Identifiable, Sendable {
        public let name: String
        public let hex: String
        public var id: String { hex }
    }

    /// The ~8 presets offered in the UI. Muted enough to read on both light
    /// and dark sidebars (full-saturation primaries glow in dark mode).
    public static let presets: [Preset] = [
        Preset(name: "Red", hex: "#E05252"),
        Preset(name: "Orange", hex: "#E08A3C"),
        Preset(name: "Yellow", hex: "#D4A73B"),
        Preset(name: "Green", hex: "#5FA96B"),
        Preset(name: "Teal", hex: "#3FA8A0"),
        Preset(name: "Blue", hex: "#4A84D8"),
        Preset(name: "Purple", hex: "#9268CF"),
        Preset(name: "Pink", hex: "#CE6BA4"),
    ]

    /// Parses "#RRGGBB" (case-insensitive) into a Color. nil input or
    /// malformed hex (e.g. hand-synced garbage) degrades to nil — the UI
    /// simply renders the tag colorless, never crashes.
    public static func color(fromHex hex: String?) -> Color? {
        guard let (r, g, b) = components(fromHex: hex) else { return nil }
        return Color(red: r, green: g, blue: b)
    }

    /// A small filled-circle image for menu rows. SwiftUI foreground styles
    /// are stripped inside NSMenu-backed context menus, but a non-template
    /// NSImage keeps its colors.
    public static func swatchImage(hex: String, diameter: CGFloat = 12) -> NSImage {
        let (r, g, b) = components(fromHex: hex) ?? (0.5, 0.5, 0.5)
        let fill = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let image = NSImage(
            size: NSSize(width: diameter, height: diameter), flipped: false
        ) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// sRGB components in 0...1, or nil when the string isn't "#RRGGBB".
    static func components(fromHex hex: String?) -> (Double, Double, Double)? {
        guard let hex else { return nil }
        let text = hex.trimmingCharacters(in: .whitespaces)
        guard
            text.hasPrefix("#"),
            text.count == 7,
            text.dropFirst().allSatisfy(\.isHexDigit),
            let value = UInt32(text.dropFirst(), radix: 16)
        else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
#endif
