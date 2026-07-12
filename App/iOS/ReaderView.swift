import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// The reader scene: Cloth & Paper chrome (top band, tinted-lozenge tab
/// strip, mockup status bar) around the PDF panes. Regular width can show
/// a sidebar panel on the left and a split pane on the right; compact
/// (iPhone) presents the sidebar as a sheet and auto-hides the chrome
/// while reading. Only on-screen tabs hold live PDFViews (`.id(...)` tears
/// them down on tab switch — and on theme change, rebuilding render caches).
struct ReaderView: View {
    let model: ReaderSessionModel
    let theme: ThemeStore
    let library: LibraryModel
    @Bindable var chrome: ReaderChromeModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var palette: DesignPalette {
        DesignPalette.palette(for: theme.resolvedTheme)
    }

    /// iPhone reading mode: chrome hides on scroll, returns on tap.
    private var chromeHidden: Bool {
        sizeClass == .compact && chrome.chromeHidden
    }

    var body: some View {
        VStack(spacing: 0) {
            if !chromeHidden {
                ReaderTopBarIOS(model: model, chrome: chrome, palette: palette)
                if !model.tabs.isEmpty {
                    TabStripIOS(model: model, palette: palette)
                    Divider()
                        .overlay(Color(platformColor: palette.chromeBorder))
                }
            }
            HStack(spacing: 0) {
                if chrome.sidebarVisible, sizeClass == .regular,
                   model.activeTabID != nil {
                    SidebarIOS(model: model, palette: palette)
                        .frame(width: 300)
                    Divider()
                        .overlay(Color(platformColor: palette.sidebarBorder))
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let splitTab = model.splitTab,
                   let splitDocument = model.splitDocument {
                    Divider()
                    splitPane(tab: splitTab, document: splitDocument)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !chromeHidden {
                ReaderBottomBarIOS(model: model, theme: theme, palette: palette)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeHidden)
        .fileImporter(
            isPresented: $chrome.showingImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.open(urls: urls)
            }
        }
        .sheet(isPresented: $chrome.showingLibrary) {
            librarySheet
        }
        .sheet(isPresented: compactSidebarBinding) {
            SidebarIOS(model: model, palette: palette) {
                chrome.sidebarVisible = false
            }
            .presentationDetents([.medium, .large])
        }
        .preferredColorScheme(theme.preferredColorScheme)
        .onChange(of: colorScheme, initial: true) { _, scheme in
            theme.noteSystemColorScheme(isDark: scheme == .dark)
        }
    }

    /// Compact width presents the sidebar as a sheet instead of a panel.
    private var compactSidebarBinding: Binding<Bool> {
        Binding(
            get: { chrome.sidebarVisible && sizeClass == .compact },
            set: { chrome.sidebarVisible = $0 }
        )
    }

    /// On iPad the default sheet is a narrow form card; the covers grid
    /// wants the wider page sizing (iOS 18+ — 17 keeps the form sheet).
    @ViewBuilder
    private var librarySheet: some View {
        let screen = LibraryScreen(library: library) { item, entry in
            model.openTab(url: item.fileURL, at: entry)
        }
        if #available(iOS 18.0, *) {
            screen.presentationSizing(.page)
        } else {
            screen
        }
    }

    private func title(for tab: TabState) -> String {
        (tab.pathHint as NSString).lastPathComponent
    }

    // MARK: - Panes

    @ViewBuilder
    private var content: some View {
        if let tab = model.activeTab {
            if model.downloadingTabID == tab.id {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Downloading “\(title(for: tab))” from iCloud…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let document = model.activeDocument {
                pdfView(tab: tab, document: document, pane: .primary)
                    // Drop a tab chip or a sidebar section on the trailing
                    // edge to open it in the split pane (iPad).
                    .overlay(alignment: .trailing) {
                        if UIDevice.current.userInterfaceIdiom == .pad,
                           model.splitTabID == nil {
                            splitDropZone
                        }
                    }
            } else if let error = model.downloadError {
                ContentUnavailableView(
                    "Couldn't Download \(title(for: tab))",
                    systemImage: "icloud.slash",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    "Can't Open \(title(for: tab))",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The file may have been moved or deleted.")
                )
            }
        } else {
            emptyState
        }
    }

    private func pdfView(
        tab: TabState, document: PDFDocument, pane: PDFKitView.Pane
    ) -> some View {
        PDFKitView(
            tab: tab,
            document: document,
            model: model,
            backgroundColor: theme.pdfBackground,
            pane: pane
        )
        .id("\(tab.id)-\(theme.resolvedTheme.rawValue)-\(pane == .split)")
        .ignoresSafeArea(edges: chromeHidden ? [.bottom, .top] : [.bottom])
        .onChromeGestures(pane: pane, sizeClass: sizeClass, chrome: chrome)
    }

    private func splitPane(tab: TabState, document: PDFDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title(for: tab))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button {
                    model.closeSplit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .accessibilityLabel("Close split")
                .hoverEffect(.highlight)
            }
            .foregroundStyle(Color(platformColor: palette.ink))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.chromeGradient)
            Divider()
            pdfView(tab: tab, document: document, pane: .split)
        }
    }

    /// Invisible trailing strip that lights up when a tab chip or sidebar
    /// section is dragged over it — drop opens the split.
    private var splitDropZone: some View {
        SplitDropTargetIOS(palette: palette) { payload in
            if let tabID = DragPayload.decodeTab(payload) {
                model.openInSplit(tabID: tabID)
                return true
            }
            if let entry = DragPayload.decodeSection(payload) {
                model.openEntryInSplit(entry)
                return true
            }
            return false
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No PDF Open", systemImage: "book.closed")
        } description: {
            Text("Open a book from your library, or a PDF from Files.")
        } actions: {
            Button("Browse Library…") {
                chrome.showingLibrary = true
            }
            .buttonStyle(.borderedProminent)
            Button("Open PDF…") {
                chrome.showingImporter = true
            }
        }
    }
}

/// Trailing-edge drop target for opening a split (iPad). Kept narrow so it
/// never blocks reading; widens visually only while a drag hovers it.
private struct SplitDropTargetIOS: View {
    let palette: DesignPalette
    let onDrop: (String) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted
                ? Color(platformColor: palette.accent).opacity(0.18)
                : Color.clear)
            .overlay {
                if isTargeted {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.title2)
                        .foregroundStyle(Color(platformColor: palette.accent))
                }
            }
            .frame(width: 56)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                return onDrop(payload)
            } isTargeted: {
                isTargeted = $0
            }
            .allowsHitTesting(true)
    }
}

/// Wires the PDF view's scroll/tap callbacks to the chrome model on
/// compact width (iPhone reading mode).
private struct ChromeGestureModifier: ViewModifier {
    let pane: PDFKitView.Pane
    let sizeClass: UserInterfaceSizeClass?
    let chrome: ReaderChromeModel

    func body(content: Content) -> some View {
        content
            .background(ChromeGestureBinder(
                enabled: sizeClass == .compact && pane == .primary,
                chrome: chrome))
    }
}

extension View {
    fileprivate func onChromeGestures(
        pane: PDFKitView.Pane, sizeClass: UserInterfaceSizeClass?,
        chrome: ReaderChromeModel
    ) -> some View {
        modifier(ChromeGestureModifier(
            pane: pane, sizeClass: sizeClass, chrome: chrome))
    }
}

/// Finds the sibling ReaderPDFViewIOS and installs the chrome callbacks.
/// UIViewRepresentable because the callbacks live on the UIKit view.
private struct ChromeGestureBinder: UIViewRepresentable {
    let enabled: Bool
    let chrome: ReaderChromeModel

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { [weak uiView] in
            guard let pdfView = Self.findPDFView(from: uiView) else { return }
            if enabled {
                pdfView.onScrollInteraction = { [weak chrome] in
                    if chrome?.chromeHidden == false {
                        chrome?.chromeHidden = true
                    }
                }
                pdfView.onContentTap = { [weak chrome] in
                    chrome?.chromeHidden.toggle()
                }
            } else {
                pdfView.onScrollInteraction = nil
                pdfView.onContentTap = nil
            }
        }
    }

    private static func findPDFView(from marker: UIView?) -> ReaderPDFViewIOS? {
        // The marker is a background sibling of the represented PDF view;
        // walk up a few levels and search down.
        var ancestor = marker?.superview
        for _ in 0..<4 {
            if let ancestor, let found = descendantPDFView(in: ancestor) {
                return found
            }
            ancestor = ancestor?.superview
        }
        return nil
    }

    private static func descendantPDFView(in view: UIView) -> ReaderPDFViewIOS? {
        if let pdf = view as? ReaderPDFViewIOS { return pdf }
        for subview in view.subviews {
            if let found = descendantPDFView(in: subview) { return found }
        }
        return nil
    }
}
