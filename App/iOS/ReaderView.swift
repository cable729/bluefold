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

    @State private var showingImporter = false
    @State private var showingLibrary = false
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
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.open(urls: urls)
            }
        }
        .sheet(isPresented: $showingLibrary) {
            LibraryScreen(library: library) { item, entry in
                model.openTab(url: item.fileURL, at: entry)
            }
        }
        .preferredColorScheme(theme.preferredColorScheme)
        .onChange(of: colorScheme, initial: true) { _, scheme in
            theme.noteSystemColorScheme(isDark: scheme == .dark)
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

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .accessibilityLabel("Forward")

            Spacer()

            themeMenu

            Button {
                showingLibrary = true
            } label: {
                Image(systemName: "books.vertical")
            }
            .accessibilityLabel("Library")

            Button {
                showingImporter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Open PDF")
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
                    showingLibrary = true
                }
                .buttonStyle(.borderedProminent)
                Button("Open PDF…") {
                    showingImporter = true
                }
            }
        }
    }
}
