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
    /// Primary pane's share of the split (0…1); the divider drives it.
    @State private var splitFraction: CGFloat = 0.5

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
                    SidebarIOS(model: model, chrome: chrome, palette: palette)
                        .frame(width: 300)
                    Divider()
                        .overlay(Color(platformColor: palette.sidebarBorder))
                }
                splitArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !chromeHidden {
                ReaderBottomBarIOS(model: model, theme: theme, palette: palette)
            }
        }
        // Theme the whole reading area so split gaps and the letterbox match
        // the page background instead of flashing system white.
        .background(Color(uiColor: theme.pdfBackground).ignoresSafeArea())
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
            SidebarIOS(model: model, chrome: chrome, palette: palette) {
                chrome.sidebarVisible = false
            }
            .presentationDetents([.medium, .large])
        }
        .preferredColorScheme(theme.preferredColorScheme)
        .onChange(of: colorScheme, initial: true) { _, scheme in
            theme.noteSystemColorScheme(isDark: scheme == .dark)
        }
        .onChange(of: model.activeTabID) { _, _ in
            // Never carry hidden chrome across a tab switch/close — the
            // toggle affordance (tap the page) may not be obvious yet.
            chrome.chromeHidden = false
        }
        .onChange(of: model.splitTabID) { _, id in
            if id != nil { splitFraction = 0.5 }
        }
    }

    /// The reading area: primary pane alone, or primary + split laid out
    /// along the split axis with a draggable divider.
    @ViewBuilder
    private var splitArea: some View {
        if let splitTab = model.splitTab, let splitDocument = model.splitDocument {
            SplitContainerIOS(
                axis: model.splitAxis,
                fraction: $splitFraction,
                palette: palette,
                primary: { content },
                secondary: {
                    pdfView(tab: splitTab, document: splitDocument, pane: .split)
                },
                onClosePrimary: { model.promoteSplitToPrimary() },
                onCloseSecondary: { model.closeSplit() }
            )
        } else {
            content
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
                    // Drop a tab chip, sidebar section, or link on the edge
                    // to open it in a split: right on iPad (side-by-side),
                    // bottom on iPhone (top/bottom).
                    .overlay(alignment: sizeClass == .regular ? .trailing : .bottom) {
                        if model.splitTabID == nil {
                            splitDropZone(axis: sizeClass == .regular ? .horizontal : .vertical)
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

    /// Invisible edge strip that lights up when a tab chip, sidebar
    /// section, or link is dragged over it — drop opens the split on `axis`.
    private func splitDropZone(axis: SplitAxis) -> some View {
        SplitDropTargetIOS(axis: axis, palette: palette) { payload in
            if let tabID = DragPayload.decodeTab(payload) {
                model.openInSplit(tabID: tabID, axis: axis)
                return true
            }
            if let entry = DragPayload.decodeSection(payload) {
                model.openEntryInSplit(entry, axis: axis)
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

/// Lays out the primary and split panes along `axis` with a draggable
/// divider. Dragging the divider to either extreme closes the pane being
/// shrunk (the surviving tab returns to a single pane); each pane has a
/// close affordance in its top-trailing corner.
private struct SplitContainerIOS<Primary: View, Secondary: View>: View {
    let axis: SplitAxis
    @Binding var fraction: CGFloat
    let palette: DesignPalette
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    let onClosePrimary: () -> Void
    let onCloseSecondary: () -> Void

    /// Live drag translation along the split axis; the panes only resize
    /// once, on release — during the drag just a ghost line moves, so a big
    /// PDF isn't re-laid-out every frame (that was the jitter).
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false

    private let minFraction: CGFloat = 0.14
    private let maxFraction: CGFloat = 0.86
    private let grabThickness: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let total = axis == .vertical ? geo.size.height : geo.size.width
            let f = min(max(fraction, minFraction), maxFraction)
            let primaryExtent = max(0, total * f)
            Group {
                if axis == .vertical {
                    VStack(spacing: 0) {
                        pane(primary, onClose: onClosePrimary).frame(height: primaryExtent)
                        divider(total: total)
                        pane(secondary, onClose: onCloseSecondary)
                    }
                } else {
                    HStack(spacing: 0) {
                        pane(primary, onClose: onClosePrimary).frame(width: primaryExtent)
                        divider(total: total)
                        pane(secondary, onClose: onCloseSecondary)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if isDragging {
                    ghostLine(boundary: primaryExtent, total: total)
                }
            }
        }
    }

    private func pane<Content: View>(
        _ content: () -> Content, onClose: @escaping () -> Void
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .padding(7)
                }
                .accessibilityLabel("Close pane")
                .hoverEffect(.highlight)
            }
            .clipped()
    }

    /// The resting divider: a hairline with a grab handle. Owns the drag
    /// gesture, so dragging elsewhere in a pane scrolls the PDF as normal.
    private func divider(total: CGFloat) -> some View {
        ZStack {
            Color(platformColor: palette.chromeBorder)
                .frame(
                    width: axis == .horizontal ? 1 : nil,
                    height: axis == .vertical ? 1 : nil
                )
            Capsule()
                .fill(.secondary)
                .frame(
                    width: axis == .vertical ? 36 : 4,
                    height: axis == .vertical ? 4 : 36
                )
        }
        .frame(
            width: axis == .horizontal ? grabThickness : nil,
            height: axis == .vertical ? grabThickness : nil
        )
        .frame(
            maxWidth: axis == .vertical ? .infinity : nil,
            maxHeight: axis == .horizontal ? .infinity : nil
        )
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .gesture(dragGesture(total: total))
    }

    /// The accent line that tracks the finger during a drag.
    private func ghostLine(boundary: CGFloat, total: CGFloat) -> some View {
        let position = min(max(boundary + dragTranslation, 0), total)
        return Capsule()
            .fill(Color(platformColor: palette.accent))
            .frame(
                width: axis == .vertical ? nil : 3,
                height: axis == .vertical ? 3 : nil
            )
            .frame(
                maxWidth: axis == .vertical ? .infinity : nil,
                maxHeight: axis == .horizontal ? .infinity : nil
            )
            .offset(
                x: axis == .horizontal ? position : 0,
                y: axis == .vertical ? position : 0
            )
    }

    private func dragGesture(total: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                dragTranslation = axis == .vertical
                    ? value.translation.height : value.translation.width
            }
            .onEnded { _ in
                let end = min(max(fraction + dragTranslation / max(total, 1), 0), 1)
                isDragging = false
                dragTranslation = 0
                if end <= minFraction {
                    onClosePrimary()
                } else if end >= maxFraction {
                    onCloseSecondary()
                } else {
                    fraction = end
                }
            }
    }
}

/// Edge drop target for opening a split — a narrow strip on the trailing
/// edge (horizontal split) or bottom edge (vertical split), lighting up
/// only while a drag hovers it so it never blocks reading.
private struct SplitDropTargetIOS: View {
    let axis: SplitAxis
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
                    Image(systemName: axis == .vertical
                        ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.title2)
                        .foregroundStyle(Color(platformColor: palette.accent))
                }
            }
            .frame(
                width: axis == .horizontal ? 56 : nil,
                height: axis == .vertical ? 56 : nil
            )
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
                    guard let chrome, !chrome.chromeLocked else { return }
                    if chrome.chromeHidden == false {
                        chrome.chromeHidden = true
                    }
                }
                pdfView.onContentTap = { [weak chrome] in
                    guard let chrome, !chrome.chromeLocked else { return }
                    chrome.chromeHidden.toggle()
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
