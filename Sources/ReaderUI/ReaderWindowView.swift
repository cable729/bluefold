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
            session: SessionCoordinator.shared,
            openReaderWindow: { openWindow(id: "reader", value: UUID()) },
            openLibraryWindow: { openWindow(id: "library") },
            presentReaderWindow: { openWindow(id: "reader", value: $0) }
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Unsplit, the one tab bar spans the FULL window width (over
            // the sidebar too — more room for lozenges). Split panes carry
            // their own bars inside the content area instead.
            if !model.tabs.isEmpty, !isSplitRendering {
                TabBarView(model: model, pane: .primary, onNewTab: openPanel)
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
                    // Registers the PDF content area as a drag-to-split drop
                    // target (tab-strip drags light up the left/right half).
                    // Only when a tab is open: an empty window has nothing to
                    // split against, so drops there stay strip/desktop drops.
                    .background(SplitDropZoneAccessor(
                        windowID: windowID, isEnabled: model.activeTab != nil
                    ))
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
        // Clipboard confirmation (margin-anchor clicks) — silent copies
        // feel broken.
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast.text)
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Shortcut ⌘B lives on the View-menu item (command table).
                Button("Sidebar", systemImage: "sidebar.left") { ui.showSidebar.toggle() }
                    .help("Show or hide the sidebar (⌘B)")
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
                // Shortcuts ⌘F and ⌥⌘O live on the menu items (command
                // table); ⌘O opens books, ⌘P navigates the current book.
                Button("Find", systemImage: "magnifyingglass") { ui.openSearchSidebar() }
                    .disabled(activeDocument == nil)
                    .help("Find in document (⌘F)")
                Button("Open…", systemImage: "folder") { openPanel() }
                    .help("Open a PDF file (⌥⌘O)")
                // Visible entry point to the command palette — the chords
                // (⌘⇧P, ⌘P, /) are otherwise undiscoverable (round 5).
                Button("Commands", systemImage: "command") {
                    ui.presentPalette(.commands)
                }
                .help("All commands (⌘⇧P) · Open a book (⌘O) · Sections (⌘P) · Shortcuts (/)")
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
            // Deep links staged before any scene existed flush through this.
            DeepLinkRouter.shared.registerPresenter { openWindow(id: "reader", value: $0) }
        }
        .onChange(of: model.focusedTabID) { _, _ in
            // Find state is per-document; a tab OR pane-focus switch changes
            // which document the sidebar is looking at.
            find.cancel()
        }
    }

    private var activeDocument: PDFDocument? {
        guard let tab = model.activeTab else { return nil }
        return model.provider.document(for: model.url(for: tab))
    }

    /// Whether `content` will render the two-pane split (both documents
    /// resident). The window-level tab bar shows exactly when it won't —
    /// so tabs stay reachable even when a split pane's file went missing.
    private var isSplitRendering: Bool {
        guard
            let tab = model.primaryTab,
            model.provider.document(for: model.url(for: tab)) != nil,
            let splitTab = model.splitTab,
            model.provider.document(for: model.url(for: splitTab)) != nil
        else { return false }
        return true
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.primaryTab {
            if let document = model.provider.document(for: model.url(for: tab)) {
                if let splitTab = model.splitTab,
                   let splitDocument = model.provider.document(for: model.url(for: splitTab)) {
                    // Two panes. EACH pane carries its own HORIZONTAL tab bar
                    // (never stacked); the non-focused pane dims a whisper so
                    // focus is visible without any header chrome. Horizontal
                    // axis = side-by-side, respecting Split Left/Right;
                    // vertical axis = stacked, primary on top (side ignored).
                    if model.splitAxis == .vertical {
                        VSplitView {
                            pane(tab: tab, document: document, role: .primary)
                                .frame(minWidth: 200, maxWidth: .infinity,
                                       minHeight: 150, maxHeight: .infinity)
                            pane(tab: splitTab, document: splitDocument, role: .split)
                                .frame(minWidth: 200, maxWidth: .infinity,
                                       minHeight: 150, maxHeight: .infinity)
                        }
                    } else {
                        HSplitView {
                            if model.splitSide == .leading {
                                pane(tab: splitTab, document: splitDocument, role: .split)
                                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                            }
                            pane(tab: tab, document: document, role: .primary)
                                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                            if model.splitSide == .trailing {
                                pane(tab: splitTab, document: splitDocument, role: .split)
                                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                } else {
                    // Unsplit: the window-level bar is the tab chrome.
                    pdfView(tab: tab, document: document, role: .primary)
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
                // ONE child: ContentUnavailableView lays actions out
                // horizontally, which shoved the hint line off-window and
                // stretched the buttons (round-8 owner screenshot).
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Button("Open Library") { openWindow(id: "library") }
                            .buttonStyle(.borderedProminent)
                        Button("Open PDF File…") { openPanel() }
                    }
                    .fixedSize()
                    // Discoverability (round 5): the shortcut system is
                    // invisible unless something points at it.
                    Text("⌘O open a book   ·   ⌘⇧P all commands   ·   /  shortcuts")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One pane: its own tab bar over its live PDF view. Focus needs no
    /// header or dot — the non-focused pane of a split dims a whisper
    /// instead (the design-system redesign removed pane headers).
    private func pane(tab: TabState, document: PDFDocument, role: ReaderPane) -> some View {
        let isSplit = model.splitTabID != nil
        let isDimmed = isSplit && model.focusedPane != role
        return VStack(spacing: 0) {
            TabBarView(model: model, pane: role, onNewTab: openPanel)
            pdfView(tab: tab, document: document, role: role)
        }
        .overlay {
            if isDimmed {
                // VERY slight: just enough for "the other pane" (owner
                // round 21: even more subtle than the first cut).
                Color.black.opacity(0.035)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDimmed)
    }

    /// The live PDF view of one pane, keyed on the RESOLVED theme too: a
    /// theme switch (or a system appearance flip in auto mode) rebuilds the
    /// PDFView so every tile re-renders through the new page filter. Also
    /// keyed on the document's reload generation: when the file changed on
    /// disk and was re-read (round 18 auto-reload), the pane rebuilds onto
    /// the fresh document — teardown captures the reading position, rebuild
    /// restores it (page index clamped by `go(to:in:)`).
    private func pdfView(tab: TabState, document: PDFDocument, role: ReaderPane) -> some View {
        let generation = SessionCoordinator.shared.documentGenerations[tab.pathHint] ?? 0
        return ActivePDFView(tab: tab, document: document, model: model, isPrimary: role == .primary)
            .id("\(role == .split ? "split-" : "")\(tab.id)-\(ThemeManager.shared.resolvedTheme.rawValue)-r\(generation)")
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

    /// Test/automation hook: `Bluefold --open <path> [--open <path> …]`
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
