import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// Single-window tabbed reader: a horizontal tab strip over a PDFKit view of
/// the active tab. Only the active tab holds a live PDFView (`.id(tab.id)`
/// tears the view down on every switch).
struct ReaderView: View {
    let model: ReaderSessionModel
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
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
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        tabChip(for: tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Button {
                showingImporter = true
            } label: {
                Image(systemName: "plus")
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open PDF")
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
            if let url = model.activeURL {
                PDFKitView(
                    url: url,
                    pageIndex: tab.pageIndex,
                    destinationPoint: tab.destinationPoint,
                    onPageChange: { pageIndex in
                        model.updatePage(tabID: tab.id, pageIndex: pageIndex)
                    },
                    onTeardown: { pageIndex, point in
                        model.captureTeardown(tabID: tab.id, pageIndex: pageIndex, point: point)
                    }
                )
                .id(tab.id)
                .ignoresSafeArea(edges: .bottom)
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
                Text("Open a PDF to start reading.")
            } actions: {
                Button("Open PDF…") {
                    showingImporter = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
