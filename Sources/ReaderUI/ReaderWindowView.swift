#if os(macOS)
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// One reader window: tab strip on top, the active tab's PDF below.
public struct ReaderWindowView: View {
    @State private var model = ReaderWindowModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                TabBarView(model: model, onNewTab: openPanel)
                Divider()
            }
            content
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                    .help("Back (⌘[)")
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                    .help("Forward (⌘])")
            }
            ToolbarItem {
                Button("Open…", systemImage: "folder") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        .navigationTitle(activeTitle)
        .onAppear(perform: openFromLaunchArguments)
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.activeTab {
            if let document = model.provider.document(for: model.url(for: tab)) {
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
