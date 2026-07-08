import Foundation

/// String form of a `KeyChord` for the user-editable keybindings.json
/// overlay: modifiers and a key joined with "+", e.g. "cmd+shift+o",
/// "ctrl+tab", "opt+cmd+left", "cmd+\\", "?". Parsing is lenient about
/// aliases, case, whitespace, and modifier order; `chordString` emits the
/// canonical form (⌃⌥⇧⌘ order: ctrl+opt+shift+cmd) and round-trips.
extension KeyChord {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownModifier(String)
        case unknownKey(String)
        case missingKey

        public var description: String {
            switch self {
            case .empty:
                "empty chord string"
            case .unknownModifier(let token):
                "unknown modifier \"\(token)\" (use cmd, ctrl, opt/alt, shift)"
            case .unknownKey(let token):
                "unknown key \"\(token)\" (single characters plus return, tab, escape, space, up, down, left, right)"
            case .missingKey:
                "chord has modifiers but no key"
            }
        }
    }

    /// Parses "cmd+shift+o"-style chord strings. The last "+"-separated
    /// token is the key; everything before it must be a modifier.
    public static func parse(_ string: String) throws -> KeyChord {
        var raw = string.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw ParseError.empty }

        // "+" as the key leaves a trailing separator: "+", "cmd++".
        var keyToken: String?
        if raw == "+" {
            return KeyChord("+")
        }
        if raw.hasSuffix("++") {
            keyToken = "+"
            raw = String(raw.dropLast(2))
        }

        var tokens = raw.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if keyToken == nil {
            keyToken = tokens.removeLast()
        }

        var modifiers: Modifiers = []
        for token in tokens {
            guard let modifier = Self.modifier(named: token.lowercased()) else {
                throw token.isEmpty ? ParseError.missingKey : ParseError.unknownModifier(token)
            }
            modifiers.insert(modifier)
        }

        guard let keyToken, !keyToken.isEmpty else { throw ParseError.missingKey }
        // A lone modifier name ("cmd") is a chord without a key.
        if Self.modifier(named: keyToken.lowercased()) != nil {
            throw ParseError.missingKey
        }
        guard let key = Self.key(named: keyToken) else {
            throw ParseError.unknownKey(keyToken)
        }
        return KeyChord(key, modifiers)
    }

    /// Canonical serialization; `parse(chordString) == self` for every chord.
    public var chordString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    private var keyName: String {
        switch key {
        case .character(let character): String(character)
        case .tab: "tab"
        case .escape: "escape"
        case .space: "space"
        case .returnKey: "return"
        case .upArrow: "up"
        case .downArrow: "down"
        case .leftArrow: "left"
        case .rightArrow: "right"
        }
    }

    private static func modifier(named name: String) -> Modifiers? {
        switch name {
        case "cmd", "command", "meta": .command
        case "ctrl", "control": .control
        case "opt", "option", "alt": .option
        case "shift": .shift
        default: nil
        }
    }

    private static func key(named name: String) -> Key? {
        if name.count == 1 {
            // Letters are stored lowercase; shift is a modifier, not case.
            return .character(Character(name.lowercased()))
        }
        switch name.lowercased() {
        case "return", "enter": return .returnKey
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "space": return .space
        case "up", "uparrow": return .upArrow
        case "down", "downarrow": return .downArrow
        case "left", "leftarrow": return .leftArrow
        case "right", "rightarrow": return .rightArrow
        default: return nil
        }
    }
}

#if os(macOS)
import AppKit

extension KeyChord {
    /// The chords an NSEvent could mean, for matching raw keyDown events
    /// against the command table. Two candidates cover the shift ambiguity:
    /// the table writes letters as lowercase + .shift ("cmd+shift+o") but
    /// shifted punctuation as the shifted character with no .shift ("?").
    public static func candidates(for event: NSEvent) -> [KeyChord] {
        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let key: Key
        switch event.keyCode {
        case 48: key = .tab
        case 53: key = .escape
        case 49: key = .space
        case 36, 76: key = .returnKey
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        default:
            guard let character = event.charactersIgnoringModifiers?.first else { return [] }
            // Letters normalize to lowercase (shift stays in modifiers).
            key = .character(Character(String(character).lowercased()))
        }

        var candidates = [KeyChord(key, modifiers)]
        if modifiers.contains(.shift), case .character(let character) = key, !character.isLetter {
            // Shifted punctuation: "?" is typed shift+/ but written "?"
            candidates.append(KeyChord(key, modifiers.subtracting(.shift)))
        }
        return candidates
    }
}
#endif
