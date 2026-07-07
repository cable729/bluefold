#if os(macOS)
import ReaderCore
import SwiftUI

/// The library window: a searchable grid of the Calibre collection.
/// Double-click (or Return) opens the book in a reader tab, downloading
/// evicted iCloud files first.
public struct LibraryView: View {
    @State private var model = LibraryModel()
    @State private var openError: String?
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    public init() {}

    public var body: some View {
        Group {
            if model.calibreRoot == nil {
                ContentUnavailableView {
                    Label("No Library Attached", systemImage: "books.vertical")
                } description: {
                    Text("Attach your Calibre folder to browse your books.")
                } actions: {
                    Button("Choose Calibre Folder…") { model.chooseCalibreFolder() }
                }
            } else if model.isLoading && model.items.isEmpty {
                ProgressView("Reading library…")
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("Could Not Read Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.reload() } }
                    Button("Choose Different Folder…") { model.chooseCalibreFolder() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(model.filteredItems) { item in
                            BookCell(
                                item: item,
                                isDownloading: model.downloading.contains(item.id),
                                open: { open(item) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("Library")
        .searchable(text: $model.searchText, prompt: "Title, author, or tag")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.reload() }
                }
                .disabled(model.calibreRoot == nil)
            }
        }
        .task { await model.reload() }
        .alert("Could Not Open Book", isPresented: .init(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
    }

    private func open(_ item: LibraryItem) {
        Task {
            do {
                if let newWindowID = try await model.openItem(item) {
                    openWindow(id: "reader", value: newWindowID)
                }
            } catch {
                openError = error.localizedDescription
            }
        }
    }
}

private struct BookCell: View {
    let item: LibraryItem
    let isDownloading: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let coverURL = item.coverURL, let image = NSImage(contentsOf: coverURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "book.closed")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                        .aspectRatio(0.72, contentMode: .fit)
                }
                if isDownloading {
                    RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4))
                    ProgressView()
                }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .shadow(radius: 2, y: 1)

            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(item.authors.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !item.calibreTags.isEmpty {
                Text(item.calibreTags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open in Reader", action: open)
        }
    }
}
#endif
