#if os(macOS)
import ReaderCore
import ReaderPersistence
import SwiftUI

/// The library window: a searchable grid of the Calibre collection.
/// Double-click (or Return) opens the book in a reader tab, downloading
/// evicted iCloud files first.
public struct LibraryView: View {
    @State private var model = LibraryModel()
    @State private var openError: String?
    @State private var newTagName: String?
    @State private var newCollectionName: String?
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    public init() {}

    public var body: some View {
        Group {
            if model.needsSetup {
                LibrarySetupView(model: model)
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    grid
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle("Library")
        .searchable(text: $model.searchText, prompt: "Title, author, or tag")
        .onChange(of: model.searchText) { _, _ in
            model.searchTextChanged()
        }
        .toolbar {
            ToolbarItemGroup {
                if let progress = model.indexingProgress {
                    Text("Indexing \(progress.done)/\(progress.total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Import PDFs…", systemImage: "square.and.arrow.down") {
                    model.importPDFs()
                }
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.reload() }
                }
                Menu {
                    Button("Change Calibre Folder…") { model.chooseCalibreFolder() }
                    if model.calibreRoot != nil {
                        Button("Detach Calibre Library", role: .destructive) {
                            model.detachCalibreFolder()
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
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
        .sheet(isPresented: .init(
            get: { newTagName != nil },
            set: { if !$0 { newTagName = nil } }
        )) {
            NamePromptSheet(
                title: "New Tag",
                placeholder: "e.g. Algebra",
                text: .init(get: { newTagName ?? "" }, set: { newTagName = $0 })
            ) { name in
                // Creating from within a tag scope nests underneath it.
                if case .tag(let parentID) = model.filter {
                    model.createTag(name: name, parent: parentID)
                } else {
                    model.createTag(name: name)
                }
            }
        }
        .sheet(isPresented: .init(
            get: { newCollectionName != nil },
            set: { if !$0 { newCollectionName = nil } }
        )) {
            NamePromptSheet(
                title: "New Collection",
                placeholder: "e.g. 5140 Algebra 2",
                text: .init(get: { newCollectionName ?? "" }, set: { newCollectionName = $0 })
            ) { name in
                model.createCollection(name: name)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.filter) {
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .tag(LibraryFilter.all)
            }
            Section("Tags") {
                OutlineGroup(model.tagTree, children: \.optionalChildren) { node in
                    tagRow(node)
                }
                newItemButton("New Tag…") { newTagName = "" }
            }
            Section("Collections") {
                ForEach(model.collections, id: \.id) { collection in
                    collectionRow(collection)
                }
                newItemButton("New Collection…") { newCollectionName = "" }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190)
    }

    private func tagRow(_ node: TagNode) -> some View {
        let filterValue: LibraryFilter = node.tag.id.map { LibraryFilter.tag($0) } ?? .all
        return Label(node.tag.name, systemImage: "tag")
            .tag(filterValue)
            .contextMenu {
                Button("Delete Tag", role: .destructive) {
                    if let id = node.tag.id {
                        model.deleteTag(id: id)
                    }
                }
            }
    }

    private func collectionRow(_ collection: CollectionRecord) -> some View {
        let filterValue: LibraryFilter = collection.id.map { LibraryFilter.collection($0) } ?? .all
        return Label(collection.name, systemImage: "folder")
            .tag(filterValue)
    }

    private func newItemButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var grid: some View {
        Group {
            if model.items.isEmpty, !model.isLoading, model.loadError == nil {
                ContentUnavailableView {
                    Label("No Books Yet", systemImage: "books.vertical")
                } description: {
                    Text(model.calibreRoot == nil
                        ? "Import PDFs, or attach a Calibre folder in the ⚙ menu."
                        : "No PDF books found in the Calibre library.")
                } actions: {
                    Button("Import PDFs…") { model.importPDFs() }
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
                    VStack(alignment: .leading, spacing: 0) {
                        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            fullTextResults
                        }
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(model.filteredItems) { item in
                                BookCell(
                                    item: item,
                                    overlayTags: model.itemTags[item.id] ?? [],
                                    isDownloading: model.downloading.contains(item.id),
                                    open: { open(item) },
                                    tagMenu: { tagMenu(for: item) },
                                    collectionMenu: { collectionMenu(for: item) }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
    }

    /// Full-text matches inside book content, shown above the grid while
    /// searching. Clicking a hit opens the book at that page.
    @ViewBuilder
    private var fullTextResults: some View {
        let hits = Array(model.textHits.prefix(20))
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("In Book Text")
                    .font(.headline)
                    .padding(.bottom, 4)
                ForEach(hits) { hit in
                    Button {
                        open(hit)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(hit.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("p.\(hit.page)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(plainSnippet(hit.snippet))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Divider()
                .padding(.horizontal, 20)
                .padding(.top, 12)
        }
    }

    /// Snippets carry «» FTS highlight markers; render them plain.
    private func plainSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
    }

    private func open(_ hit: BookSearchHit) {
        guard let item = model.items.first(where: { $0.id == hit.itemID }) else { return }
        open(item, at: NavEntry(pageIndex: hit.page - 1))
    }

    @ViewBuilder
    private func tagMenu(for item: LibraryItem) -> some View {
        ForEach(model.allTags, id: \.id) { tag in
            Toggle(tag.name, isOn: .init(
                get: { model.hasTag(tag, item: item) },
                set: { _ in model.toggleTag(tag, for: item) }
            ))
        }
        Divider()
        Button("New Tag…") { newTagName = "" }
    }

    @ViewBuilder
    private func collectionMenu(for item: LibraryItem) -> some View {
        ForEach(model.collections, id: \.id) { collection in
            Toggle(collection.name, isOn: .init(
                get: { model.isInCollection(collection, item: item) },
                set: { _ in model.toggleCollection(collection, for: item) }
            ))
        }
        Divider()
        Button("New Collection…") { newCollectionName = "" }
    }

    private func open(_ item: LibraryItem, at entry: NavEntry? = nil) {
        Task {
            do {
                if let newWindowID = try await model.openItem(item, at: entry) {
                    openWindow(id: "reader", value: newWindowID)
                }
            } catch {
                openError = error.localizedDescription
            }
        }
    }
}

/// First-run setup: an explicit choice about the Calibre folder — offered,
/// never silently applied.
private struct LibrarySetupView: View {
    unowned let model: LibraryModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Set Up Your Library")
                .font(.title2.weight(.semibold))
            Text("PDF Reader can browse an existing Calibre library alongside PDFs you import directly. Calibre stays in charge of its own files — this app never modifies them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(spacing: 10) {
                if let candidate = model.detectedCalibreCandidate {
                    Button {
                        model.completeSetup(calibreFolder: candidate)
                    } label: {
                        VStack(spacing: 2) {
                            Text("Use Detected Calibre Library")
                            Text(candidate.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 380)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Choose a Calibre Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.message = "Choose your Calibre library folder (contains metadata.db)."
                    if panel.runModal() == .OK, let url = panel.url {
                        model.completeSetup(calibreFolder: url)
                    }
                }
                .controlSize(.large)
                Button("Skip — Import PDFs Only") {
                    model.completeSetup(calibreFolder: nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// TagNode's children are non-optional; OutlineGroup wants nil for leaves.
extension TagNode {
    var optionalChildren: [TagNode]? {
        children.isEmpty ? nil : children
    }
}

extension TagNode: Identifiable {
    public var id: Int64 { tag.id ?? -1 }
}

/// Small modal prompt for naming a new tag or collection.
private struct NamePromptSheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let commit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Create", action: submit)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func submit() {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        commit(name)
        dismiss()
    }
}

private struct BookCell<TagMenu: View, CollectionMenu: View>: View {
    let item: LibraryItem
    let overlayTags: [TagRecord]
    let isDownloading: Bool
    let open: () -> Void
    @ViewBuilder let tagMenu: () -> TagMenu
    @ViewBuilder let collectionMenu: () -> CollectionMenu

    @State private var cover: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let cover {
                    Image(nsImage: cover)
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
            .task(id: item.coverURL) {
                guard let coverURL = item.coverURL else { return }
                cover = await CoverImageLoader.thumbnail(for: coverURL)
            }

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
            if !overlayTags.isEmpty {
                Text(overlayTags.map(\.name).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open in Reader", action: open)
            Menu("Tags", content: tagMenu)
            Menu("Collections", content: collectionMenu)
        }
    }
}
#endif
