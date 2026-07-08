#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// One reader window: tab strip on top, optional sidebar + find bar, and the
/// active tab's PDF. State lives in the session coordinator so it survives
/// the window and lands in session.json.
public struct ReaderWindowView: View {
    let windowID: UUID

    @State private var find = FindController()
    @State private var ui = ReaderWindowUIState()
    @Environment(\.openWindow) private var openWindow

    public init(windowID: UUID) {
        self.windowID = windowID
    }

    private var model: ReaderWindowModel {
        SessionCoordinator.shared.model(for: windowID)
    }

    /// Context handed to palette rows; menu commands build their own from
    /// focused values but land on the same command table.
    private var commandContext: CommandContext {
        CommandContext(
            model: model,
            ui: ui,
            openReaderWindow: { openWindow(id: "reader", value: UUID()) },
            openLibraryWindow: { openWindow(id: "library") }
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                TabBarView(model: model, onNewTab: openPanel)
                Divider()
            }
            HSplitView {
                if ui.showSidebar, let document = activeDocument {
                    SidebarView(
                        mode: Bindable(ui).sidebarMode,
                        outline: model.outline(for: document),
                        document: document,
                        currentPageIndex: model.activeTab?.pageIndex ?? 0,
                        model: model,
                        find: find,
                        searchFocusToken: ui.searchFocusToken
                    )
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 360)
                    .frame(maxHeight: .infinity)
                }
                content
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Always present (even with no document) so the theme control
            // is reachable from an empty window.
            Divider()
            ReaderStatusBar(model: model, pageCount: activeDocument?.pageCount)
        }
        .frame(minWidth: 500, minHeight: 400)
        .overlay {
            if let paletteMode = ui.palette {
                PaletteOverlay(mode: paletteMode, model: model, ui: ui, context: commandContext)
            }
        }
        .overlay {
            if ui.showHelp {
                HelpOverlayView(ui: ui, model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Shortcut ⌃⌘S lives on the View-menu item (command table).
                Button("Sidebar", systemImage: "sidebar.left") { ui.showSidebar.toggle() }
                    .help("Show or hide the sidebar (⌃⌘S)")
                // Click steps once; right-click shows the labeled history.
                // Shortcuts ⌘[ / ⌘] live in the History menu.
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .disabled(!model.canGoBack)
                    .help("Back (⌘[) — right-click for history")
                    .contextMenu {
                        ForEach(Array(model.backEntries.enumerated()), id: \.offset) { index, entry in
                            Button(model.historyLabel(for: entry)) {
                                model.goBack(count: index + 1)
                            }
                        }
                    }
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .disabled(!model.canGoForward)
                    .help("Forward (⌘]) — right-click for history")
                    .contextMenu {
                        ForEach(Array(model.forwardEntries.enumerated()), id: \.offset) { index, entry in
                            Button(model.historyLabel(for: entry)) {
                                model.goForward(count: index + 1)
                            }
                        }
                    }
            }
            ToolbarItemGroup {
                Button("Library", systemImage: "books.vertical") {
                    openWindow(id: "library")
                }
                .help("Open the library (⇧⌘L)")
                // Shortcuts ⌘F and ⌘⇧O live on the menu items (command
                // table); ⌘O now opens the navigate palette.
                Button("Find", systemImage: "magnifyingglass") { ui.openSearchSidebar() }
                    .disabled(activeDocument == nil)
                    .help("Find in document (⌘F)")
                Button("Open…", systemImage: "folder") { openPanel() }
                    .help("Open a PDF file (⌘⇧O)")
                // Visible entry point to the command palette — the chords
                // (⌘⇧P, ⌘P, /) are otherwise undiscoverable (round 5).
                Button("Commands", systemImage: "command") {
                    ui.presentPalette(.commands)
                }
                .help("All commands (⌘⇧P) · Go to anything (⌘P) · Shortcuts (/)")
            }
        }
        .navigationTitle(activeTitle)
        // No .preferredColorScheme here: SwiftUI only re-applies it to the
        // hosting window reliably while that window is key, so a theme
        // change made in one window left the others' appearance stale.
        // ThemeManager sets window.appearance on every registered window
        // instead (registration happens in WindowAccessor).
        .background(WindowAccessor(model: model))
        .background(WindowKeyEventBridge(model: model, ui: ui))
        .focusedSceneValue(\.readerWindowModel, model)
        .focusedSceneValue(\.readerWindowUI, ui)
        .onAppear {
            openFromLaunchArguments()
            // The launch scene fans out the rest of the restored session.
            for id in SessionCoordinator.shared.takeRemainingRestoreIDs() {
                openWindow(id: "reader", value: id)
            }
        }
        .onChange(of: model.activeTabID) { _, _ in
            // Find state is per-document; a tab switch invalidates it.
            find.cancel()
        }
    }

    private var activeDocument: PDFDocument? {
        guard let tab = model.activeTab else { return nil }
        return model.provider.document(for: model.url(for: tab))
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.activeTab {
            if let document = activeDocument {
                // Keyed on the RESOLVED theme too: a theme switch (or a
                // system appearance flip in auto mode) rebuilds the PDFView
                // so every tile re-renders through the new page filter.
                let primary = ActivePDFView(tab: tab, document: document, model: model)
                    .id("\(tab.id)-\(ThemeManager.shared.resolvedTheme.rawValue)")
                if let splitTab = model.splitTab,
                   let splitDocument = model.provider.document(for: model.url(for: splitTab)) {
                    HSplitView {
                        primary
                            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                        splitPane(tab: splitTab, document: splitDocument)
                            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    primary
                }
            } else {
                ContentUnavailableView {
                    Label("File Not Available", systemImage: "questionmark.folder")
                } description: {
                    Text(tab.pathHint)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Open", systemImage: "book.closed")
            } description: {
                Text("Browse your library or open a PDF file.")
            } actions: {
                Button("Open Library") { openWindow(id: "library") }
                    .buttonStyle(.borderedProminent)
                Button("Open PDF File…") { openPanel() }
                // Discoverability (round 5): the shortcut system is
                // invisible unless something points at it.
                Text("⌘⇧P all commands   ·   ⌘P go to anything   ·   /  shortcuts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
    }

    /// Secondary pane: a slim header naming the tab (with a close-split
    /// button) over its own live PDF view.
    private func splitPane(tab: TabState, document: PDFDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: tab.pathHint)
                    .deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    model.closeSplit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("close-split")
                .help("Close split view")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.bar)
            Divider()
            ActivePDFView(tab: tab, document: document, model: model, isPrimary: false)
                .id("split-\(tab.id)-\(ThemeManager.shared.resolvedTheme.rawValue)")
        }
    }

    private var activeTitle: String {
        guard let tab = model.activeTab else { return "PDF Reader" }
        return URL(fileURLWithPath: tab.pathHint)
            .deletingPathExtension()
            .lastPathComponent
    }

    private func openPanel() {
        model.openTabViaPanel()
    }

    /// Test/automation hook: `PDFReader --open <path> [--open <path> …]`
    /// opens each file in its own tab (in the launch window, once).
    private func openFromLaunchArguments() {
        guard !SessionCoordinator.shared.launchArgumentsConsumed else { return }
        SessionCoordinator.shared.launchArgumentsConsumed = true
        let arguments = ProcessInfo.processInfo.arguments
        var index = arguments.startIndex
        while let flagIndex = arguments[index...].firstIndex(of: "--open"),
              arguments.indices.contains(flagIndex + 1) {
            model.openTab(fileURL: URL(fileURLWithPath: arguments[flagIndex + 1]))
            index = flagIndex + 2
        }
    }
}

public extension FocusedValues {
    /// The key window's reader model, for menu commands.
    @Entry var readerWindowModel: ReaderWindowModel?
}
#endif
