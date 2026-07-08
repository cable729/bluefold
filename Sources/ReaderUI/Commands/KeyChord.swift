import SwiftUI

/// A keyboard shortcut as plain data: key + modifiers.
///
/// This is the single representation shortcuts live in — the command table
/// stores chords, the menus convert them to SwiftUI `KeyboardShortcut`s, the
/// help overlay and palettes render `display`, and the NSEvent monitor
/// compares raw events against them. One source, no drift.
public struct KeyChord: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case tab
        case escape
        case space
        case returnKey
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Convenience for plain character keys: `KeyChord("p", [.command])`.
    public init(_ character: Character, _ modifiers: Modifiers = []) {
        self.init(.character(character), modifiers)
    }

    /// Standard macOS rendering, modifier order ⌃⌥⇧⌘.
    public var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + keySymbol
    }

    private var keySymbol: String {
        switch key {
        case .character(let character): String(character).uppercased()
        case .tab: "⇥"
        case .escape: "⎋"
        case .space: "Space"
        case .returnKey: "↩"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        }
    }

    /// SwiftUI equivalent, for menu items rendered from the command table.
    public var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent = switch key {
        case .character(let character): KeyEquivalent(character)
        case .tab: .tab
        case .escape: .escape
        case .space: .space
        case .returnKey: .return
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }
}
