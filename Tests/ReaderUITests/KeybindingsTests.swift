#if os(macOS)
import Foundation
import Testing

@testable import ReaderUI

// MARK: - Chord string parsing (nonisolated — pure functions)

@Suite("KeyChord strings")
struct KeyChordStringTests {
    @Test func parsesPlainChords() throws {
        #expect(try KeyChord.parse("cmd+g") == KeyChord("g", [.command]))
        #expect(try KeyChord.parse("cmd+shift+o") == KeyChord("o", [.command, .shift]))
        #expect(try KeyChord.parse("ctrl+tab") == KeyChord(.tab, [.control]))
        #expect(try KeyChord.parse("opt+cmd+left") == KeyChord(.leftArrow, [.command, .option]))
        #expect(try KeyChord.parse("/") == KeyChord("/"))
        #expect(try KeyChord.parse("?") == KeyChord("?"))
        #expect(try KeyChord.parse("cmd+[") == KeyChord("[", [.command]))
        #expect(try KeyChord.parse("cmd+\\") == KeyChord("\\", [.command]))
        #expect(try KeyChord.parse("cmd+9") == KeyChord("9", [.command]))
    }

    @Test func parsesAliasesCaseAndWhitespace() throws {
        // alt == opt, command == cmd, control == ctrl, enter == return.
        #expect(try KeyChord.parse("alt+cmd+1") == KeyChord("1", [.command, .option]))
        #expect(try KeyChord.parse("command+control+p") == KeyChord("p", [.command, .control]))
        #expect(try KeyChord.parse("cmd+enter") == KeyChord(.returnKey, [.command]))
        #expect(try KeyChord.parse("cmd+esc") == KeyChord(.escape, [.command]))
        // Case-insensitive, letters normalize to lowercase.
        #expect(try KeyChord.parse("Cmd+Shift+G") == KeyChord("g", [.command, .shift]))
        #expect(try KeyChord.parse("CTRL+SPACE") == KeyChord(.space, [.control]))
        // Whitespace around tokens is forgiven.
        #expect(try KeyChord.parse(" cmd + g ") == KeyChord("g", [.command]))
        // Modifier order is free.
        #expect(try KeyChord.parse("shift+cmd+o") == KeyChord("o", [.command, .shift]))
    }

    @Test func parsesPlusAsKey() throws {
        #expect(try KeyChord.parse("+") == KeyChord("+"))
        #expect(try KeyChord.parse("cmd++") == KeyChord("+", [.command]))
        #expect(try KeyChord.parse("cmd+shift++") == KeyChord("+", [.command, .shift]))
    }

    @Test func rejectsMalformedChords() {
        #expect(throws: KeyChord.ParseError.empty) { try KeyChord.parse("") }
        #expect(throws: KeyChord.ParseError.empty) { try KeyChord.parse("   ") }
        // Trailing separator / lone modifier: no key.
        #expect(throws: KeyChord.ParseError.missingKey) { try KeyChord.parse("cmd+") }
        #expect(throws: KeyChord.ParseError.missingKey) { try KeyChord.parse("cmd") }
        #expect(throws: KeyChord.ParseError.missingKey) { try KeyChord.parse("cmd+shift") }
        #expect(throws: KeyChord.ParseError.unknownModifier("banana")) {
            try KeyChord.parse("banana+g")
        }
        // Key must come last.
        #expect(throws: KeyChord.ParseError.unknownModifier("g")) { try KeyChord.parse("g+cmd") }
        #expect(throws: KeyChord.ParseError.unknownKey("gh")) { try KeyChord.parse("cmd+gh") }
        #expect(throws: KeyChord.ParseError.unknownKey("pageup")) { try KeyChord.parse("cmd+pageup") }
    }

    @Test func serializationIsCanonical() {
        // ⌃⌥⇧⌘ order, lowercase names.
        #expect(KeyChord("o", [.command, .shift]).chordString == "shift+cmd+o")
        #expect(KeyChord(.tab, [.control, .shift]).chordString == "ctrl+shift+tab")
        #expect(KeyChord("?").chordString == "?")
        #expect(KeyChord(.leftArrow).chordString == "left")
    }

    @Test @MainActor func everyDefaultChordRoundTrips() throws {
        for command in CommandRegistry.defaults {
            for chord in command.chords {
                #expect(try KeyChord.parse(chord.chordString) == chord, Comment(rawValue: command.id))
            }
        }
    }
}

// MARK: - Overlay file parsing, merge, validation

@Suite("Keybindings overlay")
@MainActor
struct KeybindingsTests {
    private func parse(_ json: String) -> Keybindings.ParsedFile {
        Keybindings.parse(Data(json.utf8))
    }

    private func apply(_ json: String) -> (commands: [ReaderCommand], issues: [String]) {
        Keybindings.apply(parse(json), to: CommandRegistry.defaults)
    }

    private func chords(of id: String, in commands: [ReaderCommand]) -> [KeyChord]? {
        commands.first { $0.id == id }?.chords
    }

    // MARK: Parsing

    @Test func parsesBindingsUnbindingsAndIgnoresDocs() {
        let parsed = parse(
            """
            {
              "_docs": ["ignored", "also ignored"],
              "_anythingUnderscored": 42,
              "view.toggleSidebar": "cmd+shift+b",
              "bookmarks.add": null,
              "search.find": ""
            }
            """
        )
        #expect(parsed.issues.isEmpty)
        #expect(parsed.actions["view.toggleSidebar"] == .bind(KeyChord("b", [.command, .shift])))
        #expect(parsed.actions["bookmarks.add"] == .unbind)
        #expect(parsed.actions["search.find"] == .unbind)
        #expect(parsed.actions.count == 3)
    }

    @Test func badJSONBadValuesAndBadChordsBecomeIssues() {
        #expect(!parse("not json at all").issues.isEmpty)
        #expect(!parse("[1, 2, 3]").issues.isEmpty)

        let mixed = parse(
            """
            {
              "view.toggleSidebar": 7,
              "bookmarks.add": "cmd+notakey",
              "search.find": "cmd+shift+f2f",
              "nav.openAnything": "cmd+k"
            }
            """
        )
        // The valid entry survives; each bad one gets its own issue.
        #expect(mixed.actions == ["nav.openAnything": .bind(KeyChord("k", [.command]))])
        #expect(mixed.issues.count == 3)
        #expect(mixed.issues.contains { $0.contains("view.toggleSidebar") })
        #expect(mixed.issues.contains { $0.contains("cmd+notakey") })
    }

    // MARK: Merge semantics

    @Test func overrideReplacesAllDefaultChordsIncludingAliases() {
        // nav.goToSection ships two chords (⌘P + the ⌘⇧O alias).
        let (commands, issues) = apply(#"{"nav.goToSection": "cmd+shift+space"}"#)
        #expect(issues.isEmpty)
        #expect(chords(of: "nav.goToSection", in: commands) == [KeyChord(.space, [.command, .shift])])
        // Menus render chords.first, so the menu reflects it automatically.
        #expect(
            commands.first { $0.id == "nav.goToSection" }?.menuShortcut
                == KeyChord(.space, [.command, .shift]).keyboardShortcut
        )
    }

    @Test func unbindEmptiesChordsButKeepsTheCommand() {
        let (commands, issues) = apply(#"{"bookmarks.add": null}"#)
        #expect(issues.isEmpty)
        #expect(chords(of: "bookmarks.add", in: commands) == [])
        #expect(commands.first { $0.id == "bookmarks.add" }?.menuShortcut == nil)
        // Still present for the palette and menus (just chordless).
        #expect(commands.contains { $0.id == "bookmarks.add" })
    }

    @Test func untouchedCommandsKeepTheirDefaults() {
        let (commands, _) = apply(#"{"view.toggleSidebar": "cmd+shift+b"}"#)
        #expect(chords(of: "nav.back", in: commands) == [KeyChord("[", [.command])])
        #expect(commands.count == CommandRegistry.defaults.count)
    }

    @Test func freedChordCanBeReassigned() {
        // ⌘B is freed by rebinding view.toggleSidebar, then claimed by
        // bookmarks.add — order in the file doesn't matter.
        let (commands, issues) = apply(
            """
            {
              "view.toggleSidebar": "cmd+shift+b",
              "bookmarks.add": "cmd+b"
            }
            """
        )
        #expect(issues.isEmpty)
        #expect(chords(of: "view.toggleSidebar", in: commands) == [KeyChord("b", [.command, .shift])])
        #expect(chords(of: "bookmarks.add", in: commands) == [KeyChord("b", [.command])])
    }

    @Test func chordSwapBetweenTwoCommandsWorks() {
        let (commands, issues) = apply(
            """
            {
              "search.find": "cmd+b",
              "view.toggleSidebar": "cmd+f"
            }
            """
        )
        #expect(issues.isEmpty)
        #expect(chords(of: "search.find", in: commands) == [KeyChord("b", [.command])])
        #expect(chords(of: "view.toggleSidebar", in: commands) == [KeyChord("f", [.command])])
    }

    // MARK: Validation

    @Test func unknownCommandIDIsReportedAndSkipped() {
        let (commands, issues) = apply(#"{"nav.doesNotExist": "cmd+u"}"#)
        #expect(issues.count == 1)
        #expect(issues[0].contains("nav.doesNotExist"))
        #expect(issues[0].contains("unknown command id"))
        #expect(commands.count == CommandRegistry.defaults.count)
    }

    @Test func conflictWithExistingDefaultIsRejected() {
        // ⌘F belongs to search.find and wasn't freed.
        let (commands, issues) = apply(#"{"bookmarks.add": "cmd+f"}"#)
        #expect(issues.count == 1)
        #expect(issues[0].contains("search.find"))
        // The rejected command keeps its default.
        #expect(chords(of: "bookmarks.add", in: commands) == [KeyChord("d", [.command])])
    }

    @Test func duplicateAssignmentKeepsFirstAlphabetically() {
        let (commands, issues) = apply(
            """
            {
              "view.fitWidth": "cmd+u",
              "view.fitHeight": "cmd+u"
            }
            """
        )
        // Deterministic despite JSON's unordered keys: sorted id order,
        // so view.fitHeight wins and view.fitWidth is reported.
        #expect(issues.count == 1)
        #expect(issues[0].contains("view.fitWidth"))
        #expect(chords(of: "view.fitHeight", in: commands) == [KeyChord("u", [.command])])
        #expect(chords(of: "view.fitWidth", in: commands) == [])  // default was chordless
    }

    @Test func goToPageIsProtectedBothWays() {
        // ⌘G must remain Go to Page (owner ruling — docs/KEYBINDINGS.md).
        let rebind = apply(#"{"nav.goToPage": "cmd+j"}"#)
        #expect(rebind.issues.count == 1)
        #expect(rebind.issues[0].contains("cannot be rebound"))
        #expect(chords(of: "nav.goToPage", in: rebind.commands) == [KeyChord("g", [.command])])

        let unbind = apply(#"{"nav.goToPage": null}"#)
        #expect(unbind.issues.count == 1)
        #expect(chords(of: "nav.goToPage", in: unbind.commands) == [KeyChord("g", [.command])])

        // And nobody else can take ⌘G.
        let steal = apply(#"{"search.find": "cmd+g"}"#)
        #expect(steal.issues.count == 1)
        #expect(steal.issues[0].contains("nav.goToPage"))
        #expect(chords(of: "search.find", in: steal.commands) == [KeyChord("f", [.command])])
    }

    @Test func overlaidTableNeverDuplicatesChords() {
        // Even a hostile file leaves the effective table conflict-free —
        // the invariant CommandRegistryTests enforces on the defaults.
        let (commands, _) = apply(
            """
            {
              "bookmarks.add": "cmd+f",
              "view.fitWidth": "cmd+t",
              "view.fitHeight": "cmd+t",
              "search.allBooks": "cmd+d"
            }
            """
        )
        let all = commands.flatMap(\.chords)
        #expect(Set(all).count == all.count)
    }

    // MARK: File loading

    @Test func loadingMissingOrNilURLIsClean() {
        let missing = Keybindings.load(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("kb-missing-\(UUID().uuidString).json")
        )
        #expect(missing.actions.isEmpty && missing.issues.isEmpty)
        let none = Keybindings.load(url: nil)
        #expect(none.actions.isEmpty && none.issues.isEmpty)
    }

    @Test func loadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"view.toggleSidebar": "ctrl+b"}"#.utf8).write(to: url)
        let parsed = Keybindings.load(url: url)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.actions["view.toggleSidebar"] == .bind(KeyChord("b", [.control])))
    }

    @Test func testProcessNeverResolvesTheRealFile() {
        // The env override wins; without it a unit-test process gets nil —
        // the registry must never read the user's real Application Support.
        #expect(
            Keybindings.fileURL(environment: ["BLUEFOLD_KEYBINDINGS_FILE": "/tmp/kb.json"])
                == URL(fileURLWithPath: "/tmp/kb.json")
        )
        #expect(Keybindings.fileURL(environment: [:]) == nil)
        #expect(CommandRegistry.keybindingsIssues.isEmpty)
    }

    // MARK: Template

    @Test func templateIsValidJSONWithOnlyDocs() throws {
        let template = Keybindings.template(commands: CommandRegistry.defaults)
        // Loads clean: no bindings, no issues (the "_docs" key is ignored).
        let parsed = Keybindings.parse(Data(template.utf8))
        #expect(parsed.actions.isEmpty)
        #expect(parsed.issues.isEmpty)
        // Documents every command id so users don't need the repo.
        for command in CommandRegistry.defaults {
            #expect(template.contains(command.id), Comment(rawValue: command.id))
        }
    }

    // MARK: Monitor dispatch through the table

    @Test func monitorDispatchFindsMonitorOwnedChords() {
        // ⌘5 → tab five; ⌃Tab → next tab; ⌘⇧O → in-book palette alias.
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord("5", [.command])], isEditingText: false
            )?.id == "tabs.select.5"
        )
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord(.tab, [.control])], isEditingText: false
            )?.id == "tabs.next"
        )
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord(.tab, [.control, .shift])], isEditingText: false
            )?.id == "tabs.previous"
        )
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord("o", [.command, .shift])], isEditingText: false
            )?.id == "nav.goToSection"
        )
    }

    @Test func monitorDispatchLeavesOtherLayersAlone() {
        // Menu-installed first chords are the menu's, not the monitor's.
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord("p", [.command])], isEditingText: false
            ) == nil
        )
        // Bare arrows stay with ReaderPDFView.keyDown and list views.
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord(.leftArrow)], isEditingText: false
            ) == nil
        )
        // help.shortcuts ("/") and the scene-owned Library chord are exempt.
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord("/")], isEditingText: false
            ) == nil
        )
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord("l", [.command, .shift])], isEditingText: false
            ) == nil
        )
        // Hard-modifier chords fire while editing text; bare ones don't.
        #expect(
            CommandRegistry.monitorCommand(
                matching: [KeyChord("5", [.command])], isEditingText: true
            ) != nil
        )
    }
}
#endif
