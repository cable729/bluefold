import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Single-window tabbed reader: a control bar (history, library, theme) and
/// a horizontal tab strip over a PDFKit view of the active tab. Only the
/// active tab holds a live PDFView (`.id(...)` tears the view down on every
/// switch — and on theme change, rebuilding the render caches).
struct ReaderView: View {
    let model: ReaderSessionModel
    let theme: ThemeStore
    let library: LibraryModel
    @Bindable var chrome: ReaderChromeModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if !model.tabs.isEmpty {
                tabStrip
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        .preferredColorScheme(theme.preferredColorScheme)
        .onChange(of: colorScheme, initial: true) { _, scheme in
            theme.noteSystemColorScheme(isDark: scheme == .dark)
        }
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

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .accessibilityLabel("Back")
            .hoverEffect(.highlight)

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .accessibilityLabel("Forward")
            .hoverEffect(.highlight)

            Spacer()

            if model.activeTabID != nil {
                Button {
                    model.presentFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Find in document")
                .hoverEffect(.highlight)

                layoutMenu
            }

            themeMenu

            Button {
                chrome.showingLibrary = true
            } label: {
                Image(systemName: "books.vertical")
            }
            .accessibilityLabel("Library")
            .hoverEffect(.highlight)

            Button {
                chrome.showingImporter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Open PDF")
            .hoverEffect(.highlight)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var layoutMenu: some View {
        Menu {
            Picker("Page Layout", selection: Binding(
                get: { model.activeDisplayMode },
                set: { model.setDisplayMode($0) }
            )) {
                Label("Single Page", systemImage: "doc")
                    .tag(PDFDisplayMode.singlePage)
                Label("Continuous Scroll", systemImage: "doc.text")
                    .tag(PDFDisplayMode.singlePageContinuous)
                Label("Two Pages", systemImage: "book")
                    .tag(PDFDisplayMode.twoUp)
                Label("Two Pages Continuous", systemImage: "book.pages")
                    .tag(PDFDisplayMode.twoUpContinuous)
            }
        } label: {
            Image(systemName: "rectangle.split.2x1")
        }
        .accessibilityLabel("Page layout")
        .hoverEffect(.highlight)
    }

    private var themeMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .accessibilityLabel("Theme")
        .hoverEffect(.highlight)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    tabChip(for: tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func tabChip(for tab: TabState) -> some View {
        let isActive = tab.id == model.activeTabID
        return HStack(spacing: 4) {
            Text(title(for: tab))
                .font(.callout)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close \(title(for: tab))")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isActive ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary),
            in: Capsule()
        )
        .contentShape(Capsule())
        .hoverEffect(.highlight)
        .onTapGesture {
            model.activate(tab.id)
        }
    }

    private func title(for tab: TabState) -> String {
        (tab.pathHint as NSString).lastPathComponent
    }

    // MARK: - Content

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
                PDFKitView(
                    tab: tab,
                    document: document,
                    model: model,
                    backgroundColor: theme.pdfBackground
                )
                .id("\(tab.id)-\(theme.resolvedTheme.rawValue)")
                .ignoresSafeArea(edges: .bottom)
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
}
