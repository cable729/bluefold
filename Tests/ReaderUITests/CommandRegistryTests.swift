#if os(macOS)
import Foundation
import PDFKit
import ReaderCore
import Testing

@testable import ReaderUI

@Suite("CommandRegistry")
@MainActor
struct CommandRegistryTests {
    // MARK: - Table integrity

    @Test func commandIDsAreUnique() {
        let ids = CommandRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func shortcutsAreUnique() {
        // Every chord of every command — a chord bound twice is a bug no
        // matter which layer (menu, monitor, PDFView) owns it.
        let chords = CommandRegistry.all.flatMap(\.chords)
        let duplicates = Dictionary(grouping: chords, by: \.self)
            .filter { $0.value.count > 1 }
            .keys.map(\.display)
        #expect(duplicates.isEmpty, "duplicate shortcuts: \(duplicates)")
    }

    @Test func titlesAreNonEmptyAndIDsNamespaced() {
        for command in CommandRegistry.all {
            #expect(!command.title.isEmpty)
            #expect(command.id.contains("."), "un-namespaced id: \(command.id)")
        }
    }

    @Test func everyCategoryHasCommands() {
        let used = Set(CommandRegistry.all.map(\.category))
        #expect(used == Set(CommandCategory.allCases))
    }

    @Test func chordDisplayRendering() {
        #expect(KeyChord("p", [.command, .shift]).display == "⇧⌘P")
        #expect(KeyChord(.tab, [.control]).display == "⌃⇥")
        #expect(KeyChord("g", [.command, .option]).display == "⌥⌘G")
        #expect(KeyChord("/").display == "/")
    }

    @Test func monitorOwnedChordsInstallNoMenuShortcut() {
        for id in ["help.shortcuts", "nav.previousPage", "nav.nextPage", "file.openLibrary"] {
            #expect(CommandRegistry.command(id: id)?.menuShortcut == nil)
        }
        // The navigate palette's menu item installs ⌘P; the ⌘O alias is the
        // key monitor's.
        let anything = CommandRegistry.command(id: "nav.openAnything")
        #expect(anything?.menuShortcut != nil)
        #expect(anything?.chords.contains(KeyChord("o", [.command])) == true)
    }

    // MARK: - Behavior through the table

    private func makeContext() -> (CommandContext, ReaderWindowModel, ReaderWindowUIState) {
        let model = ReaderWindowModel(provider: DocumentProvider(capacity: 3))
        let ui = ReaderWindowUIState()
        let context = CommandContext(model: model, ui: ui)
        return (context, model, ui)
    }

    @Test func tabCyclingCommandsCycleTabs() {
        let (context, model, _) = makeContext()
        let a = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        let b = model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.selectTab(id: a)

        CommandRegistry.command(id: "tabs.next")?.run(context)
        #expect(model.activeTabID == b)
        CommandRegistry.command(id: "tabs.previous")?.run(context)
        #expect(model.activeTabID == a)
    }

    @Test func paletteCommandsDriveUIState() {
        let (context, _, ui) = makeContext()

        CommandRegistry.command(id: "help.commandPalette")?.run(context)
        #expect(ui.palette == .commands)

        CommandRegistry.command(id: "nav.openAnything")?.run(context)
        #expect(ui.palette == .navigate)

        CommandRegistry.command(id: "help.shortcuts")?.run(context)
        #expect(ui.showHelp)

        // Presenting a palette hides the help overlay.
        CommandRegistry.command(id: "nav.goToPage")?.run(context)
        #expect(ui.palette == .goToPage)
        #expect(!ui.showHelp)
    }

    @Test func findCommandOpensSearchSidebar() {
        let (context, _, ui) = makeContext()
        let tokenBefore = ui.searchFocusToken
        CommandRegistry.command(id: "search.find")?.run(context)
        #expect(ui.showSidebar)
        #expect(ui.sidebarMode == .search)
        #expect(ui.searchFocusToken == tokenBefore + 1)
    }

    @Test func sidebarToggleReflectsAndFlipsState() {
        let (context, _, ui) = makeContext()
        let command = CommandRegistry.command(id: "view.toggleSidebar")
        #expect(command?.isOn?(context) == false)
        command?.run(context)
        #expect(ui.showSidebar)
        #expect(command?.isOn?(context) == true)
    }

    @Test func layoutCommandsSetDisplayMode() {
        let (context, model, _) = makeContext()
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        CommandRegistry.command(id: "view.layout.twoUp")?.run(context)
        #expect(model.activeTab?.displayModeRaw == PDFDisplayMode.twoUp.rawValue)
        #expect(CommandRegistry.command(id: "view.layout.twoUp")?.isOn?(context) == true)
        #expect(CommandRegistry.command(id: "view.layout.singlePage")?.isOn?(context) == false)
    }

    @Test func reopenClosedTabCommandRoundTripsThroughTheTable() {
        let coordinator = SessionCoordinator(
            sessionFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("reopen-\(UUID().uuidString).json")
        )
        let model = coordinator.model(for: UUID())
        let context = CommandContext(model: model, session: coordinator)
        let command = CommandRegistry.command(id: "tabs.reopenClosed")

        #expect(command?.isAvailable(context) == false)
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        model.closeTab(id: model.tabs[1].id)
        #expect(command?.isAvailable(context) == true)

        command?.run(context)
        #expect(model.tabs.count == 2)
        #expect(model.tabs[1].pathHint.hasSuffix("b.pdf"))
        #expect(command?.isAvailable(context) == false)
    }

    @Test func availabilityTracksWindowState() {
        let empty = CommandContext()
        for id in ["file.newTab", "nav.openAnything", "bookmarks.add", "tabs.duplicate",
                   "tabs.reopenClosed"] {
            #expect(CommandRegistry.command(id: id)?.isAvailable(empty) == false, Comment(rawValue: id))
        }
        #expect(CommandRegistry.command(id: "file.newWindow")?.isAvailable(empty) == true)

        let (context, model, _) = makeContext()
        #expect(CommandRegistry.command(id: "nav.back")?.isAvailable(context) == false)
        #expect(CommandRegistry.command(id: "tabs.next")?.isAvailable(context) == false)
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.openTab(fileURL: URL(fileURLWithPath: "/tmp/b.pdf"))
        #expect(CommandRegistry.command(id: "tabs.next")?.isAvailable(context) == true)
    }

    // MARK: - Go to page parsing

    @Test func goToPageParsing() {
        #expect(GoToPage.parse("5", pageCount: 10) == 4)
        #expect(GoToPage.parse(" 7 ", pageCount: 10) == 6)
        #expect(GoToPage.parse("1", pageCount: 10) == 0)
        #expect(GoToPage.parse("10", pageCount: 10) == 9)
        #expect(GoToPage.parse("0", pageCount: 10) == nil)
        #expect(GoToPage.parse("11", pageCount: 10) == nil)
        #expect(GoToPage.parse("abc", pageCount: 10) == nil)
        #expect(GoToPage.parse("", pageCount: 10) == nil)
        #expect(GoToPage.parse("3", pageCount: 0) == nil)
    }
}
#endif
