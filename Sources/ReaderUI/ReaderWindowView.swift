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
    @State private var showFindBar = false
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
            if showFindBar, let document = activeDocument {
                FindBarView(document: document, model: model, find: find) {
                    showFindBar = false
                }
                Divider()
            }
            HSplitView {
                if showSidebar, let document = activeDocument {
                    SidebarView(
                        outline: OutlineNode.tree(from: document),
                        document: document,
                        onJump: { model.jump(to: $0) }
                    )
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 340)
                }
                content
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Sidebar", systemImage: "sidebar.left") { showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .help("Show or hide the sidebar (⌃⌘S)")
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                    .help("Back (⌘[)")
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                    .help("Forward (⌘])")
            }
            ToolbarItemGroup {
                Button("Find", systemImage: "magnifyingglass") { toggleFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(activeDocument == nil)
                    .help("Find in document (⌘F)")
                Button("Open…", systemImage: "folder") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        .navigationTitle(activeTitle)
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
            showFindBar = false
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
                ActivePDFView(tab: tab, document: document, model: model)
                    .id(tab.id)
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
                Text("Open a PDF to start reading.")
            } actions: {
                Button("Open PDF…") { openPanel() }
            }
        }
    }

    private var activeTitle: String {
        guard let tab = model.activeTab else { return "PDF Reader" }
        return URL(fileURLWithPath: tab.pathHint)
            .deletingPathExtension()
            .lastPathComponent
    }

    private func toggleFindBar() {
        if showFindBar {
            find.cancel()
            model.activeController?.showFindResults([], current: nil)
        }
        showFindBar.toggle()
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
