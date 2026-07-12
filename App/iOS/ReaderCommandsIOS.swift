import PDFKit
import ReaderCore
import SwiftUI

/// Presentation state the menu bar and the control bar both drive (the
/// importer and library sheets live on ReaderView, but commands are
/// scene-level — so the flags live here, above both).
/// Which list the sidebar shows (macOS sidebar's icon tabs).
enum SidebarMode: String, CaseIterable {
    case contents = "Contents"
    case bookmarks = "Bookmarks"
    case find = "Find"
}

@MainActor
@Observable
final class ReaderChromeModel {
    /// `--library` opens the library sheet on launch (automation hook,
    /// like `--sidebar`; simctl can't tap).
    var showingLibrary = ProcessInfo.processInfo.arguments.contains("--library")
    var showingImporter = false
    /// Sidebar panel (regular width) / sheet (compact). `--sidebar` is an
    /// automation hook (simctl can't tap), like macOS `--open`.
    var sidebarVisible = ProcessInfo.processInfo.arguments.contains("--sidebar")
    var sidebarMode: SidebarMode = .contents
    /// iPhone reading mode: chrome fades while scrolling; tap toggles.
    var chromeHidden = false
    /// When locked (iPhone lock button), chrome stays visible: scrolling
    /// never auto-hides it and the tap toggle is inert.
    var chromeLocked = false {
        didSet {
            if chromeLocked { chromeHidden = false }
        }
    }

    /// The top-bar magnifier and ⌘F: find lives in the sidebar with
    /// Contents/Bookmarks (owner feedback), not a separate surface.
    func showFind() {
        sidebarMode = .find
        sidebarVisible = true
    }
}

/// Hardware-keyboard commands for iPadOS (and iPhone with a keyboard):
/// the iPadOS 26 menu bar and the hold-⌘ shortcut HUD both render from
/// these. Chords mirror docs/KEYBINDINGS.md (the macOS command table)
/// wherever the command exists on iOS — ⌘O and ⌘P stay UNBOUND on
/// purpose; they're reserved for the palettes (macOS parity) so nobody
/// has to relearn chords when those arrive here.
struct ReaderCommandsIOS: Commands {
    let model: ReaderSessionModel
    let theme: ThemeStore
    let chrome: ReaderChromeModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") { chrome.showingImporter = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Open Library") { chrome.showingLibrary = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") {
                if let id = model.activeTabID { model.close(id) }
            }
            .keyboardShortcut("w")
            .disabled(model.activeTabID == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(chrome.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                chrome.sidebarVisible.toggle()
            }
            .keyboardShortcut("b")
        }

        CommandGroup(after: .toolbar) {
            layoutPicker
            Divider()
            Button(model.splitTabID == nil ? "Split Right" : "Close Split") {
                model.toggleSplit()
            }
            .keyboardShortcut("\\")
            .disabled(model.activeTabID == nil)
            Divider()
            themePicker
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Divider()
            Button("Previous Section") { model.goToPreviousSection() }
                .disabled(!model.canGoToPreviousSection)
            Button("Next Section") { model.goToNextSection() }
                .disabled(!model.canGoToNextSection)
            Divider()
            Button("Next Tab") { model.activateAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.tabs.count < 2)
            Button("Previous Tab") { model.activateAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.tabs.count < 2)
            Divider()
            // ⌘1…⌘8 = tab by position, ⌘9 = last (browser convention,
            // matches macOS — where these are key-monitor chords; menus
            // are the only chord layer iOS has).
            ForEach(1..<10, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                    model.activateTab(number: number)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(number != 9 && number > model.tabs.count)
            }
        }

        CommandMenu("Search") {
            // Sidebar Find mode (macOS ⌘F semantics: open the search
            // sidebar), not the system find navigator.
            Button("Find in Document") { chrome.showFind() }
                .keyboardShortcut("f")
                .disabled(model.activeTabID == nil)
        }

        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") { model.addBookmarkAtCurrentPosition() }
                .keyboardShortcut("d")
                .disabled(model.activeTabID == nil)
        }
    }

    /// ⌥⌘1–4 page layouts — same chords and names as the macOS View menu.
    @ViewBuilder
    private var layoutPicker: some View {
        let layouts: [(PDFDisplayMode, String)] = [
            (.singlePage, "Single Page"),
            (.singlePageContinuous, "Continuous Scroll"),
            (.twoUp, "Two Pages"),
            (.twoUpContinuous, "Two Pages Continuous"),
        ]
        ForEach(Array(layouts.enumerated()), id: \.element.1) { index, layout in
            Button {
                model.setDisplayMode(layout.0)
            } label: {
                if model.activeDisplayMode == layout.0 {
                    Label(layout.1, systemImage: "checkmark")
                } else {
                    Text(layout.1)
                }
            }
            .keyboardShortcut(
                KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            .disabled(model.activeTabID == nil)
        }
    }

    @ViewBuilder
    private var themePicker: some View {
        ForEach(AppTheme.allCases, id: \.self) { option in
            Button {
                theme.current = option
            } label: {
                if theme.current == option {
                    Label(ThemeStore.label(for: option), systemImage: "checkmark")
                } else {
                    Text(ThemeStore.label(for: option))
                }
            }
        }
    }
}
