#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// One reader window: tab strip on top, optional sidebar + find bar, and the
/// active tab's PDF.
public struct ReaderWindowView: View {
    @State private var model = ReaderWindowModel()
    @State private var find = FindController()
    @State private var showSidebar = false
    @State private var showFindBar = false

    public init() {}

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
        .onAppear(perform: openFromLaunchArguments)
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.openTab(fileURL: url)
        }
    }

    /// Test/automation hook: `PDFReader --open <path> [--open <path> …]`
    /// opens each file in its own tab.
    private func openFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        var index = arguments.startIndex
        while let flagIndex = arguments[index...].firstIndex(of: "--open"),
              arguments.indices.contains(flagIndex + 1) {
            model.openTab(fileURL: URL(fileURLWithPath: arguments[flagIndex + 1]))
            index = flagIndex + 2
        }
    }
}
#endif
