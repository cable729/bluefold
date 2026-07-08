#if os(macOS)
import AppKit
import Foundation

/// The user-editable keybindings overlay: a JSON file mapping command ids to
/// chord strings, applied over `CommandRegistry`'s default table at launch.
///
///     {
///       "_docs": ["ignored — keys starting with _ are comments"],
///       "nav.openAnything": "cmd+shift+space",
///       "view.toggleSidebar": null
///     }
///
/// `null` (or `""`) unbinds; a chord string replaces ALL of the command's
/// default chords, aliases included. Bad entries never crash: every problem
/// becomes a human-readable issue (launch alert + help-overlay banner) and
/// the valid rest of the file still applies. Format documented in
/// docs/KEYBINDINGS.md.
public enum Keybindings {
    /// What one JSON entry asks for.
    public enum Action: Equatable, Sendable {
        case bind(KeyChord)
        case unbind
    }

    public struct ParsedFile: Sendable {
        public var actions: [String: Action] = [:]
        public var issues: [String] = []
    }

    /// Commands whose bindings are load-bearing decisions, not preferences.
    /// ⌘G = Go to Page is an owner ruling (docs/KEYBINDINGS.md: find-next
    /// must never take it back), so the whole command is fenced off.
    static let protectedCommandIDs: Set<String> = ["nav.goToPage"]

    // MARK: - File location

    /// Where the overlay lives. `PDFREADER_KEYBINDINGS_FILE` overrides it
    /// (tests, automation); unit-test processes otherwise get nil so they
    /// can never read the user's real Application Support file.
    @MainActor
    public static func fileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let explicit = environment["PDFREADER_KEYBINDINGS_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if AppStores.isTestProcess { return nil }
        return AppDataDirectory.url().appendingPathComponent("keybindings.json")
    }

    // MARK: - Load / parse

    /// Reads and parses the overlay file. A missing file (or nil URL) is the
    /// normal no-overrides case; anything else wrong becomes an issue.
    public static func load(url: URL?) -> ParsedFile {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return ParsedFile()
        }
        do {
            return parse(try Data(contentsOf: url))
        } catch {
            var parsed = ParsedFile()
            parsed.issues.append("keybindings.json could not be read: \(error.localizedDescription)")
            return parsed
        }
    }

    /// Decodes the JSON. Unknown-id and conflict checks need the command
    /// table and happen in `apply`; this stage catches structural problems:
    /// not an object, non-string values, unparseable chords.
    public static func parse(_ data: Data) -> ParsedFile {
        var parsed = ParsedFile()
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                parsed.issues.append("keybindings.json must be a JSON object of \"command.id\": \"chord\" pairs")
                return parsed
            }
            object = decoded
        } catch {
            parsed.issues.append("keybindings.json is not valid JSON: \(error.localizedDescription)")
            return parsed
        }

        for (key, value) in object {
            if key.hasPrefix("_") { continue }  // comment keys ("_docs")
            switch value {
            case is NSNull:
                parsed.actions[key] = .unbind
            case let string as String:
                if string.trimmingCharacters(in: .whitespaces).isEmpty {
                    parsed.actions[key] = .unbind
                    continue
                }
                do {
                    parsed.actions[key] = .bind(try KeyChord.parse(string))
                } catch let error as KeyChord.ParseError {
                    parsed.issues.append("\"\(key)\": bad chord \"\(string)\" — \(error.description)")
                } catch {
                    parsed.issues.append("\"\(key)\": bad chord \"\(string)\"")
                }
            default:
                parsed.issues.append("\"\(key)\": value must be a chord string or null, not \(type(of: value))")
            }
        }
        return parsed
    }

    // MARK: - Apply

    /// Applies parsed overrides to the command table. Every valid entry
    /// lands; unknown ids, protected commands, and chord conflicts are
    /// rejected individually with an issue each. Chord swaps and freed-chord
    /// reassignment work regardless of order in the file: a command with a
    /// surviving override vacates its default chords before conflicts are
    /// checked.
    public static func apply(
        _ parsed: ParsedFile,
        to commands: [ReaderCommand]
    ) -> (commands: [ReaderCommand], issues: [String]) {
        var issues = parsed.issues
        let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })

        // Structurally valid entries; unknown ids and protected commands
        // drop out here.
        var active: [String: Action] = [:]
        for (id, action) in parsed.actions {
            guard let command = byID[id] else {
                issues.append("\"\(id)\": unknown command id (the full list is in docs/KEYBINDINGS.md)")
                continue
            }
            guard !protectedCommandIDs.contains(id) else {
                issues.append("\"\(id)\": \(command.title) cannot be rebound or unbound (see docs/KEYBINDINGS.md)")
                continue
            }
            active[id] = action
        }

        // Conflict resolution to a fixpoint. Each pass: overridden commands
        // vacate their defaults, then every requested chord must be free
        // among the remaining defaults plus already-granted overrides
        // (sorted-id order, so of two claims on one chord the
        // alphabetically first wins). A rejection puts that command's
        // defaults back, which can invalidate a grant made against the
        // vacated chord — so any rejection re-runs the pass until stable.
        // Terminates: every pass either rejects at least one override or
        // is the last.
        while true {
            let vacated = Set(active.keys)
            var owner: [KeyChord: ReaderCommand] = [:]
            for command in commands where !vacated.contains(command.id) {
                for chord in command.chords { owner[chord] = command }
            }
            var rejected: [String] = []
            for id in active.keys.sorted() {
                guard case .bind(let chord) = active[id] else { continue }
                if let taken = owner[chord] {
                    issues.append(
                        "\"\(id)\": \(chord.chordString) is already bound to \"\(taken.id)\" (\(taken.title))"
                    )
                    rejected.append(id)
                } else if let command = byID[id] {
                    owner[chord] = command
                }
            }
            if rejected.isEmpty { break }
            for id in rejected { active[id] = nil }
        }

        let result = commands.map { command -> ReaderCommand in
            switch active[command.id] {
            case .bind(let chord): command.with(chords: [chord])
            case .unbind: command.with(chords: [])
            case nil: command
            }
        }
        return (result, issues)
    }

    // MARK: - Template / reveal

    /// Creates the file (with docs — JSON has no comments, so instructions
    /// live in an ignored "_docs" array listing every command id and its
    /// default chord) if needed, then opens it in the default editor.
    @MainActor
    public static func openFile() {
        guard let url = fileURL() else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: url.path) {
                try template(commands: CommandRegistry.defaults)
                    .data(using: .utf8)?
                    .write(to: url)
            }
        } catch {
            NSLog("PDFReader: could not create keybindings.json: \(error)")
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The starter file: all instructions inside "_docs" (ignored on load),
    /// no active bindings.
    public static func template(commands: [ReaderCommand]) -> String {
        var docs: [String] = [
            "PDFReader keybindings — this file overlays the defaults at launch (relaunch to apply).",
            "Add entries at the top level: \"command.id\": \"chord\", e.g. \"view.toggleSidebar\": \"cmd+shift+b\".",
            "A chord is modifiers + one key joined with '+': cmd, ctrl, opt (or alt), shift.",
            "Keys: letters, digits, punctuation ([ ] \\ / ; ' , . = - `), and return, tab, escape, space, up, down, left, right.",
            "Your chord replaces ALL of a command's default chords, aliases included.",
            "Unbind a command with null or \"\". Keys starting with '_' (like this one) are ignored.",
            "Problems (unknown id, bad chord, chord already taken) are reported at launch; valid entries still apply.",
            "nav.goToPage stays on cmd+g by design and cannot be changed here.",
            "Full documentation: docs/KEYBINDINGS.md in the PDFReader repository.",
            "",
            "Command ids and their defaults:",
        ]
        for command in commands {
            let chords = command.chords.map(\.chordString).joined(separator: ", ")
            docs.append("  \(command.id) — \(command.title)\(chords.isEmpty ? "" : " (\(chords))")")
        }

        // Hand-assembled so _docs stays first and the file is pleasant to edit.
        var out = "{\n  \"_docs\": [\n"
        out += docs.map { "    \(jsonString($0))" }.joined(separator: ",\n")
        out += "\n  ]\n}\n"
        return out
    }

    private static func jsonString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data()
        let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())  // strip the [ ]
    }
}

extension ReaderCommand {
    /// Copy with different chords — how the keybindings overlay rebinds and
    /// unbinds without touching behavior.
    func with(chords: [KeyChord]) -> ReaderCommand {
        ReaderCommand(
            id: id, title: title, category: category, chords: chords,
            installsMenuShortcut: installsMenuShortcut,
            isAvailable: isAvailable, isOn: isOn, run: run
        )
    }
}
#endif
