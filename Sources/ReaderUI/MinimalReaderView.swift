#if os(macOS)
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The M5 single-document reader: an open panel and a PDF view.
/// Replaced by the tabbed reader window in M6.
public struct MinimalReaderView: View {
    @State private var document: PDFDocument?
    @State private var documentURL: URL?

    public init() {}

    public var body: some View {
        Group {
            if let document {
                PDFKitView(document: document)
            } else {
                ContentUnavailableView {
                    Label("No PDF Open", systemImage: "book.closed")
                } description: {
                    Text("Open a PDF to start reading.")
                } actions: {
                    Button("Open PDF…") { openPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            ToolbarItem {
                Button("Open…", systemImage: "folder") { openPanel() }
            }
        }
        .navigationTitle(documentURL?.deletingPathExtension().lastPathComponent ?? "PDF Reader")
        .onAppear(perform: openFromLaunchArguments)
    }

    /// Test hook: `PDFReader --open <path>` opens a PDF without the panel
    /// (used by automated verification and, later, XCUITest).
    private func openFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--open"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let url = URL(fileURLWithPath: arguments[flagIndex + 1])
        if let opened = PDFDocument(url: url) {
            document = opened
            documentURL = url
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let opened = PDFDocument(url: url) {
            document = opened
            documentURL = url
        }
    }
}
#endif
