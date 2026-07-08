#if os(macOS)
import AppKit
import PDFKit
import ReaderCore
import SwiftUI

/// Everything a command can act on at invocation time: the focused window's
/// model and UI state, plus scene-level hooks the environment provides.
@MainActor
public struct CommandContext {
    public var model: ReaderWindowModel?
    public var ui: ReaderWindowUIState?
    public var openReaderWindow: () -> Void
    public var openLibraryWindow: () -> Void

    public init(
        model: ReaderWindowModel? = nil,
        ui: ReaderWindowUIState? = nil,
        openReaderWindow: @escaping () -> Void = {},
        openLibraryWindow: @escaping () -> Void = {}
    ) {
        self.model = model
        self.ui = ui
        self.openReaderWindow = openReaderWindow
        self.openLibraryWindow = openLibraryWindow
    }

    /// The active tab's live document, if any.
    public var activeDocument: PDFDocument? {
        guard let model, let tab = model.activeTab else { return nil }
        return model.provider.document(for: model.url(for: tab))
    }
}

/// Grouping for the help overlay and the command palette; menu placement is
/// decided by `ReaderCommands` but always renders the same command structs.
public enum CommandCategory: String, CaseIterable, Sendable {
    case file = "File"
    case navigation = "Navigation"
    case tabs = "Tabs"
    case view = "View"
    case search = "Search"
    case bookmarks = "Bookmarks"
    case help = "Help & Palettes"
}

/// One user-invocable action. The View menu, the command palette, and the
/// help overlay all render from these structs, so they can never drift.
public struct ReaderCommand: Identifiable {
    public let id: String
    public let title: String
    public let category: CommandCategory
    /// Every chord that triggers this command; the first is what a menu item
    /// installs. Extra chords are bound elsewhere (NSEvent monitor, PDFView).
    public let chords: [KeyChord]
    /// False when the chord is owned by another layer (scene shortcut, key
    /// monitor, PDFView keyDown) and the menu must NOT claim it too.
    public let installsMenuShortcut: Bool
    public let isAvailable: @MainActor (CommandContext) -> Bool
    /// Non-nil for stateful commands; menus render them as checkmark toggles.
    public let isOn: (@MainActor (CommandContext) -> Bool)?
    public let run: @MainActor (CommandContext) -> Void

    init(
        id: String,
        title: String,
        category: CommandCategory,
        chords: [KeyChord] = [],
        installsMenuShortcut: Bool = true,
        isAvailable: @escaping @MainActor (CommandContext) -> Bool = { _ in true },
        isOn: (@MainActor (CommandContext) -> Bool)? = nil,
        run: @escaping @MainActor (CommandContext) -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.chords = chords
        self.installsMenuShortcut = installsMenuShortcut
        self.isAvailable = isAvailable
        self.isOn = isOn
        self.run = run
    }

    /// The shortcut a menu item rendered from this command should install.
    public var menuShortcut: KeyboardShortcut? {
        guard installsMenuShortcut else { return nil }
        return chords.first?.keyboardShortcut
    }
}

/// The one command table. Every user-invocable action lives here; menus,
/// palettes, the help overlay, and docs/KEYBINDINGS.md are projections of it.
@MainActor
public enum CommandRegistry {
    public static let all: [ReaderCommand] = build()

    public static func command(id: String) -> ReaderCommand? {
        all.first { $0.id == id }
    }

    public static func commands(ids: [String]) -> [ReaderCommand] {
        ids.compactMap(command(id:))
    }

    public static func commands(idPrefix: String) -> [ReaderCommand] {
        all.filter { $0.id.hasPrefix(idPrefix) }
    }

    // MARK: - Table

    private static func build() -> [ReaderCommand] {
        var commands: [ReaderCommand] = []

        // MARK: File

        commands.append(ReaderCommand(
            id: "file.newWindow", title: "New Window", category: .file,
            chords: [KeyChord("n", [.command])],
            run: { $0.openReaderWindow() }
        ))
        commands.append(ReaderCommand(
            id: "file.newTab", title: "New Tab…", category: .file,
            chords: [KeyChord("t", [.command])],
            isAvailable: { $0.model != nil },
            run: { $0.model?.openTabViaPanel() }
        ))
        // ⌘O belongs to the navigate palette (VS Code/Obsidian quick-open);
        // file-open moved to ⌘⇧O.
        commands.append(ReaderCommand(
            id: "file.openFile", title: "Open File…", category: .file,
            chords: [KeyChord("o", [.command, .shift])],
            isAvailable: { $0.model != nil },
            run: { $0.model?.openTabViaPanel() }
        ))
        // ⌘⇧L is installed at scene level on the Library window; listing it
        // here again would double-bind it.
        commands.append(ReaderCommand(
            id: "file.openLibrary", title: "Open Library", category: .file,
            chords: [KeyChord("l", [.command, .shift])],
            installsMenuShortcut: false,
            run: { $0.openLibraryWindow() }
        ))
        commands.append(ReaderCommand(
            id: "file.closeTab", title: "Close Tab", category: .file,
            chords: [KeyChord("w", [.command])],
            run: { context in
                if context.model?.closeActiveTab() != true {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
        ))
        commands.append(ReaderCommand(
            id: "file.closeWindow", title: "Close Window", category: .file,
            chords: [KeyChord("w", [.command, .shift])],
            run: { _ in NSApp.keyWindow?.performClose(nil) }
        ))

        // MARK: Navigation

        commands.append(ReaderCommand(
            id: "nav.back", title: "Back", category: .navigation,
            chords: [KeyChord("[", [.command])],
            isAvailable: { $0.model?.canGoBack == true },
            run: { $0.model?.goBack() }
        ))
        commands.append(ReaderCommand(
            id: "nav.forward", title: "Forward", category: .navigation,
            chords: [KeyChord("]", [.command])],
            isAvailable: { $0.model?.canGoForward == true },
            run: { $0.model?.goForward() }
        ))
        // Arrows are handled by ReaderPDFView.keyDown (a menu binding would
        // steal arrows from every text field in the window).
        commands.append(ReaderCommand(
            id: "nav.previousPage", title: "Previous Page", category: .navigation,
            chords: [KeyChord(.leftArrow)],
            installsMenuShortcut: false,
            isAvailable: { $0.activeDocument != nil },
            run: { $0.model?.activeController?.goToPreviousPage() }
        ))
        commands.append(ReaderCommand(
            id: "nav.nextPage", title: "Next Page", category: .navigation,
            chords: [KeyChord(.rightArrow)],
            installsMenuShortcut: false,
            isAvailable: { $0.activeDocument != nil },
            run: { $0.model?.activeController?.goToNextPage() }
        ))
        // ⌘G is free for this (owner request): the M8 find bar's ⌘G cycling
        // is gone — the sidebar find cycles with Enter/⇧Enter in its field.
        commands.append(ReaderCommand(
            id: "nav.goToPage", title: "Go to Page…", category: .navigation,
            chords: [KeyChord("g", [.command])],
            isAvailable: { $0.activeDocument != nil },
            run: { $0.ui?.presentPalette(.goToPage) }
        ))
        // ⌘P is freed from Print (VS Code quick-open convention); ⌘O is
        // bound by the window's key monitor, not the menu.
        commands.append(ReaderCommand(
            id: "nav.openAnything", title: "Go to Anything…", category: .navigation,
            chords: [KeyChord("p", [.command]), KeyChord("o", [.command])],
            isAvailable: { $0.model != nil },
            run: { $0.ui?.presentPalette(.navigate) }
        ))

        // MARK: Tabs

        commands.append(ReaderCommand(
            id: "tabs.next", title: "Show Next Tab", category: .tabs,
            chords: [KeyChord("]", [.command, .shift]), KeyChord(.tab, [.control])],
            isAvailable: { ($0.model?.tabs.count ?? 0) > 1 },
            run: { $0.model?.selectNextTab() }
        ))
        commands.append(ReaderCommand(
            id: "tabs.previous", title: "Show Previous Tab", category: .tabs,
            chords: [KeyChord("[", [.command, .shift]), KeyChord(.tab, [.control, .shift])],
            isAvailable: { ($0.model?.tabs.count ?? 0) > 1 },
            run: { $0.model?.selectPreviousTab() }
        ))
        commands.append(ReaderCommand(
            id: "tabs.duplicate", title: "Duplicate Tab", category: .tabs,
            isAvailable: { $0.model?.activeTab != nil },
            run: { context in
                guard let model = context.model, let active = model.activeTab else { return }
                model.duplicateTab(id: active.id)
            }
        ))
        commands.append(ReaderCommand(
            id: "tabs.closeOthers", title: "Close Other Tabs", category: .tabs,
            isAvailable: { ($0.model?.tabs.count ?? 0) > 1 },
            run: { context in
                guard let model = context.model, let active = model.activeTab else { return }
                model.closeOtherTabs(keeping: active.id)
            }
        ))

        // MARK: View

        commands.append(ReaderCommand(
            id: "view.toggleSidebar", title: "Show Sidebar", category: .view,
            chords: [KeyChord("s", [.control, .command])],
            isAvailable: { $0.ui != nil },
            isOn: { $0.ui?.showSidebar == true },
            run: { $0.ui?.showSidebar.toggle() }
        ))
        let layouts: [(String, String, PDFDisplayMode, Character)] = [
            ("view.layout.singlePage", "Single Page", .singlePage, "1"),
            ("view.layout.continuous", "Continuous Scroll", .singlePageContinuous, "2"),
            ("view.layout.twoUp", "Two Pages", .twoUp, "3"),
            ("view.layout.twoUpContinuous", "Two Pages, Continuous", .twoUpContinuous, "4"),
        ]
        for (id, title, mode, digit) in layouts {
            commands.append(ReaderCommand(
                id: id, title: title, category: .view,
                chords: [KeyChord(digit, [.command])],
                isAvailable: { $0.activeDocument != nil },
                isOn: { $0.model?.activeTab?.displayModeRaw == mode.rawValue },
                run: { $0.model?.setDisplayMode(mode.rawValue) }
            ))
        }
        commands.append(ReaderCommand(
            id: "view.fitWidth", title: "Fit Width", category: .view,
            isAvailable: { $0.activeDocument != nil },
            run: { $0.model?.fitWidth() }
        ))
        commands.append(ReaderCommand(
            id: "view.fitHeight", title: "Fit Height", category: .view,
            isAvailable: { $0.activeDocument != nil },
            run: { $0.model?.fitHeight() }
        ))
        // Generated from AppTheme.allCases so a new theme (e.g. "auto")
        // appears everywhere automatically.
        for theme in AppTheme.allCases {
            commands.append(ReaderCommand(
                id: "view.theme.\(theme.rawValue)",
                title: "\(theme.rawValue.capitalized) Theme",
                category: .view,
                isOn: { _ in ThemeManager.shared.current == theme },
                run: { _ in ThemeManager.shared.current = theme }
            ))
        }

        // MARK: Search

        commands.append(ReaderCommand(
            id: "search.find", title: "Find in Document", category: .search,
            chords: [KeyChord("f", [.command])],
            isAvailable: { $0.activeDocument != nil && $0.ui != nil },
            run: { $0.ui?.openSearchSidebar() }
        ))

        // MARK: Bookmarks

        commands.append(ReaderCommand(
            id: "bookmarks.add", title: "Bookmark This Page", category: .bookmarks,
            chords: [KeyChord("d", [.command])],
            isAvailable: { $0.model?.activeTab != nil },
            run: { $0.model?.addBookmarkAtCurrentPosition() }
        ))

        // MARK: Help & palettes

        commands.append(ReaderCommand(
            id: "help.commandPalette", title: "Command Palette…", category: .help,
            chords: [KeyChord("p", [.command, .shift])],
            isAvailable: { $0.ui != nil },
            run: { $0.ui?.presentPalette(.commands) }
        ))
        // "/" and "?" are bound by the window's key monitor so they still
        // type normally inside search fields.
        commands.append(ReaderCommand(
            id: "help.shortcuts", title: "Keyboard Shortcuts", category: .help,
            chords: [KeyChord("/"), KeyChord("?")],
            installsMenuShortcut: false,
            isAvailable: { $0.ui != nil },
            run: { $0.ui?.showHelp = true }
        ))

        return commands
    }
}

/// Parses the go-to-page palette's input. Zero-based result.
public enum GoToPage {
    public static func parse(_ input: String, pageCount: Int) -> Int? {
        guard
            pageCount >= 1,
            let number = Int(input.trimmingCharacters(in: .whitespaces)),
            (1...pageCount).contains(number)
        else { return nil }
        return number - 1
    }
}
#endif
