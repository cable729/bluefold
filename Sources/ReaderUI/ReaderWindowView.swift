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
    @State private var showSidebar = false
    @State private var sidebarMode: SidebarMode = .outline
    @State private var searchFocusToken = 0
    @Environment(\.openWindow) private var openWindow

    public init(windowID: UUID) {
        self.windowID = windowID
    }

    private var model: ReaderWindowModel {
        SessionCoordinator.shared.model(for: windowID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                TabBarView(model: model, onNewTab: openPanel)
                Divider()
            }
            HSplitView {
                if showSidebar, let document = activeDocument {
                    SidebarView(
                        mode: $sidebarMode,
                        outline: model.outline(for: document),
                        document: document,
                        currentPageIndex: model.activeTab?.pageIndex ?? 0,
                        model: model,
                        find: find,
                        searchFocusToken: searchFocusToken
                    )
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 360)
                    .frame(maxHeight: .infinity)
                }
                content
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let document = activeDocument {
                Divider()
                ReaderStatusBar(model: model, pageCount: document.pageCount)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Sidebar", systemImage: "sidebar.left") { showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
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
                Button("Find", systemImage: "magnifyingglass") { openSearchSidebar() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(activeDocument == nil)
                    .help("Find in document (⌘F)")
                Button("Open…", systemImage: "folder") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Open a PDF file (⌘O)")
            }
        }
        .navigationTitle(activeTitle)
        .preferredColorScheme(ThemeManager.shared.current == .dark ? .dark : .light)
        .background(WindowAccessor(model: model))
        .focusedSceneValue(\.readerWindowModel, model)
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

    private func openSearchSidebar() {
        showSidebar = true
        sidebarMode = .search
        searchFocusToken += 1
    }

    private var activeDocument: PDFDocument? {
        guard let tab = model.activeTab else { return nil }
        return model.provider.document(for: model.url(for: tab))
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.activeTab {
            if let document = activeDocument {
                // Keyed on theme too: a theme switch rebuilds the PDFView so
                // every tile re-renders through the new page filter.
                ActivePDFView(tab: tab, document: document, model: model)
                    .id("\(tab.id)-\(ThemeManager.shared.current.rawValue)")
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
            }
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
