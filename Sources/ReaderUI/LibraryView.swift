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
    @State private var showAllTextHits = false
    @State private var selection = LibrarySelection()
    @State private var showTagsHelp = false
    @State private var showCollectionsHelp = false
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
        .background(ThemeChromeAccessor())  // titlebar tints with the theme
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
                // Creating from within a collection scope nests underneath it.
                if case .collection(let parentID) = model.filter {
                    model.createCollection(name: name, parent: parentID)
                } else {
                    model.createCollection(name: name)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.filter) {
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .tag(LibraryFilter.all)
                Label("Untagged", systemImage: "tag.slash")
                    .badge(model.untaggedCount)
                    .tag(LibraryFilter.untagged)
                Label("Not in a Collection", systemImage: "questionmark.folder")
                    .badge(model.notInAnyCollectionCount)
                    .tag(LibraryFilter.notInAnyCollection)
            }
            Section {
                OutlineGroup(model.tagTree, children: \.optionalChildren) { node in
                    tagRow(node)
                }
                newItemButton("New Tag…") { newTagName = "" }
            } header: {
                // Dropping a tag on the section header un-nests it.
                sectionHeader("Tags", isPresented: $showTagsHelp, help: Self.tagsHelp)
                    .dropDestination(for: String.self) { payloads, _ in
                        guard let dragged = draggedTagID(in: payloads) else { return false }
                        return model.reparentTag(id: dragged, under: nil)
                    }
            }
            Section {
                OutlineGroup(model.collectionTree, children: \.optionalChildren) { node in
                    collectionRow(node.collection)
                }
                newItemButton("New Collection…") { newCollectionName = "" }
            } header: {
                sectionHeader(
                    "Collections", isPresented: $showCollectionsHelp, help: Self.collectionsHelp
                )
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190)
    }

    private static let tagsHelp = """
        A tag describes what a book IS — its subject or attributes. \
        Tags can nest (Algebra ▸ Linear Algebra), and a book can carry \
        as many as you like. Selecting a tag also shows books tagged \
        with any of its sub-tags. Drag books here to tag them.
        """

    private static let collectionsHelp = """
        A collection is a curated set a book is IN — a course, project, \
        or reading list. Collections keep a manual order, can nest, and \
        can mix books from any source. The same book can sit in several \
        collections. Drag books here to add them.
        """

    /// Section title plus a small ⓘ that explains the concept in a popover.
    private func sectionHeader(
        _ title: String, isPresented: Binding<Bool>, help: String
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Button {
                isPresented.wrappedValue.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title.lowercased())")
            .popover(isPresented: isPresented, arrowEdge: .trailing) {
                Text(help)
                    .font(.callout)
                    .frame(width: 260, alignment: .leading)
                    .padding(12)
            }
        }
    }

    /// Payload marker distinguishing a dragged TAG from dragged book IDs in
    /// the shared String transfer type.
    private static let tagDragPrefix = "tag:"

    private func tagRow(_ node: TagNode) -> some View {
        let filterValue: LibraryFilter = node.tag.id.map { LibraryFilter.tag($0) } ?? .all
        return Label(node.tag.name, systemImage: "tag")
            .tag(filterValue)
            .draggable(Self.tagDragPrefix + String(node.tag.id ?? -1)) {
                Label(node.tag.name, systemImage: "tag")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            .contextMenu {
                Button("Move to Top Level") {
                    if let id = node.tag.id {
                        model.reparentTag(id: id, under: nil)
                    }
                }
                .disabled(node.tag.parentID == nil)
                Button("Delete Tag", role: .destructive) {
                    if let id = node.tag.id {
                        model.deleteTag(id: id)
                    }
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                handleTagRowDrop(payloads, onto: node.tag.id)
            }
    }

    /// A tag row accepts two kinds of drags: books (assign the tag) and
    /// other tags (nest under this one — building the tree by drag).
    private func handleTagRowDrop(_ payloads: [String], onto tagID: Int64?) -> Bool {
        guard let tagID else { return false }
        if let dragged = draggedTagID(in: payloads) {
            return model.reparentTag(id: dragged, under: tagID)
        }
        let targets = dropTargets(for: payloads)
        guard !targets.isEmpty else { return false }
        model.addTag(tagID: tagID, toItemIDs: targets)
        return true
    }

    private func draggedTagID(in payloads: [String]) -> Int64? {
        for payload in payloads where payload.hasPrefix(Self.tagDragPrefix) {
            if let id = Int64(payload.dropFirst(Self.tagDragPrefix.count)), id >= 0 {
                return id
            }
        }
        return nil
    }

    private func collectionRow(_ collection: CollectionRecord) -> some View {
        let filterValue: LibraryFilter = collection.id.map { LibraryFilter.collection($0) } ?? .all
        return Label(collection.name, systemImage: "folder")
            .tag(filterValue)
            .contextMenu {
                Button("Open Collection") {
                    openCollection(collection, inNewWindow: false)
                }
                Button("Open Collection in New Window") {
                    openCollection(collection, inNewWindow: true)
                }
                Divider()
                Button("Delete Collection", role: .destructive) {
                    if let id = collection.id {
                        model.deleteCollection(id: id)
                    }
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                let targets = dropTargets(for: ids)
                guard let collectionID = collection.id, !targets.isEmpty else { return false }
                model.addToCollection(collectionID: collectionID, itemIDs: targets)
                return true
            }
    }

    /// Opens every book of a collection as tabs — in the last-focused reader
    /// window or a fresh one. iCloud-evicted files download first; files
    /// that never materialize are skipped rather than blocking the rest.
    private func openCollection(_ collection: CollectionRecord, inNewWindow: Bool) {
        guard let id = collection.id else { return }
        let urls = model.itemsInCollection(id).map(\.fileURL)
        guard !urls.isEmpty else { return }
        Task {
            var local: [URL] = []
            for url in urls {
                try? await FileAvailability.ensureLocal(url)
                if FileAvailability.isLocal(url) {
                    local.append(url)
                }
            }
            guard !local.isEmpty else { return }
            if inNewWindow {
                openWindow(
                    id: "reader",
                    value: SessionCoordinator.shared.openInNewWindow(fileURLs: local)
                )
            } else if let newID = SessionCoordinator.shared.openAllInReader(fileURLs: local) {
                openWindow(id: "reader", value: newID)
            }
        }
    }

    /// Small pill shown under the cursor while dragging a book — the cell
    /// itself would cover the tag/collection rows being aimed at. Reflects
    /// the whole selection when the drag starts on a selected cell.
    private func dragPreview(for item: LibraryItem) -> some View {
        let count = selection.contains(item.id) ? max(selection.count, 1) : 1
        return Label(
            count > 1 ? "\(count) books" : item.title,
            systemImage: count > 1 ? "books.vertical" : "book.closed"
        )
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 180)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    /// A drag that starts on a selected cell carries the whole selection;
    /// dragging an unselected cell affects just that one book.
    private func dropTargets(for droppedIDs: [String]) -> Set<String> {
        let dropped = Set(droppedIDs.filter { id in model.items.contains { $0.id == id } })
        guard !dropped.isEmpty else { return [] }
        if !dropped.isDisjoint(with: selection.selectedIDs) {
            return dropped.union(selection.selectedIDs)
        }
        return dropped
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
                                    isSelected: selection.contains(item.id),
                                    tap: { handleTap(item) },
                                    open: { openKeepingSelection(item) },
                                    reveal: { model.revealInFinder([item]) },
                                    remove: item.source == .imported
                                        ? { removeFromLibrary(item) } : nil,
                                    tagMenu: { tagMenu(for: item) },
                                    collectionMenu: { collectionMenu(for: item) }
                                )
                                // Compact preview: dragging the full-size
                                // cell hides the sidebar rows you aim at.
                                .draggable(item.id) {
                                    dragPreview(for: item)
                                }
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // A click that lands outside every cell (grid gaps,
                        // margins) falls through to this layer and clears
                        // the selection. Cells sit on top and win their own
                        // clicks. (A gesture on the ScrollView itself never
                        // fires — NSScrollView swallows it.)
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selection.clear() }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !selection.isEmpty {
                        selectionBar
                    }
                }
                .background {
                    // Esc clears the selection. A local key monitor scoped
                    // to this window — SwiftUI's .keyboardShortcut(.escape)
                    // never fires here (Escape is routed as cancelOperation,
                    // not a key equivalent, outside dialogs).
                    EscapeCatcher {
                        guard !selection.isEmpty else { return false }
                        selection.clear()
                        return true
                    }
                }
                .onChange(of: model.filteredItems) { _, newItems in
                    selection.prune(to: newItems.map(\.id))
                }
            }
        }
    }

    /// One click on a cell, with whatever modifiers the current event holds.
    private func handleTap(_ item: LibraryItem) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let modifiers: LibrarySelection.Modifiers =
            flags.contains(.command) ? .command : flags.contains(.shift) ? .shift : .none
        selection.click(item.id, modifiers: modifiers, orderedIDs: model.filteredItems.map(\.id))
    }

    private func openKeepingSelection(_ item: LibraryItem) {
        if !selection.contains(item.id) {
            selection.click(
                item.id, modifiers: .none, orderedIDs: model.filteredItems.map(\.id)
            )
        }
        open(item)
    }

    private func removeFromLibrary(_ item: LibraryItem) {
        model.removeImportedItems([item])
        selection.prune(to: model.filteredItems.map(\.id))
    }

    /// Contextual actions for the current selection, shown as a bottom bar.
    private var selectionBar: some View {
        let selected = model.items(withIDs: selection.selectedIDs)
        let importedOnly = !selected.isEmpty && selected.allSatisfy { $0.source == .imported }
        return HStack(spacing: 12) {
            // Visible so its Esc key equivalent reliably registers (hidden
            // buttons don't participate in key-equivalent matching).
            Button {
                selection.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Clear selection (Esc)")
            .accessibilityLabel("Clear selection")
            Text("\(selected.count) selected")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open") {
                for item in selected { open(item) }
            }
            Menu("Tag") {
                ForEach(model.allTags, id: \.id) { tag in
                    Toggle(tag.name, isOn: .init(
                        get: { model.allHaveTag(tag, items: selected) },
                        set: { _ in model.toggleTag(tag, forAll: selected) }
                    ))
                }
                Divider()
                Button("New Tag…") { newTagName = "" }
            }
            .fixedSize()
            Menu("Add to Collection") {
                ForEach(model.collections, id: \.id) { collection in
                    Toggle(collection.name, isOn: .init(
                        get: { model.allInCollection(collection, items: selected) },
                        set: { _ in model.toggleCollection(collection, forAll: selected) }
                    ))
                }
                Divider()
                Button("New Collection…") { newCollectionName = "" }
            }
            .fixedSize()
            Button("Reveal in Finder") {
                model.revealInFinder(selected)
            }
            if importedOnly {
                // Only the app's own imports can be removed — never Calibre
                // books (Calibre's library is read-only).
                Button("Remove", role: .destructive) {
                    model.removeImportedItems(selected)
                    selection.clear()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Full-text matches inside book content, shown above the grid while
    /// searching — capped so the book grid stays visible; expandable.
    @ViewBuilder
    private var fullTextResults: some View {
        let hits = Array(model.textHits.prefix(showAllTextHits ? 60 : 5))
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
                if model.textHits.count > 5 {
                    Button(showAllTextHits
                        ? "Show Fewer"
                        : "Show All \(model.textHits.count) Matches") {
                        showAllTextHits.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 2)
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

/// Runs `onEscape` when Esc is pressed in this view's window (and no sheet
/// is up). Returns true to swallow the event. Needed because Escape reaches
/// views as `cancelOperation:` through the responder chain, which SwiftUI's
/// `.keyboardShortcut(.escape)` does not intercept in a plain window.
private struct EscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onEscape = onEscape
    }

    final class MonitorView: NSView {
        var onEscape: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard
                        let self,
                        event.keyCode == 53,  // Escape
                        event.window === self.window,
                        self.window?.attachedSheet == nil,
                        self.onEscape?() == true
                    else { return event }
                    return nil  // handled: swallow
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
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

extension CollectionNode: Identifiable {
    public var id: Int64 { collection.id ?? -1 }

    var optionalChildren: [CollectionNode]? {
        children.isEmpty ? nil : children
    }
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
    let isSelected: Bool
    let tap: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    /// nil for Calibre books — only the app's own imports are removable.
    let remove: (() -> Void)?
    @ViewBuilder let tagMenu: () -> TagMenu
    @ViewBuilder let collectionMenu: () -> CollectionMenu

    @State private var cover: NSImage?
    @State private var coverRequested = false

    var body: some View {
        BookCellContent(
            item: item,
            overlayTags: overlayTags,
            isDownloading: isDownloading,
            isSelected: isSelected,
            cover: cover
        )
        .equatable()
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded(open))
        .simultaneousGesture(TapGesture(count: 1).onEnded(tap))
        .contextMenu {
            Button("Open in Reader", action: open)
            Menu("Tags", content: tagMenu)
            Menu("Collections", content: collectionMenu)
            Divider()
            Button("Reveal in Finder", action: reveal)
            if let remove {
                Divider()
                Button("Remove from Library", role: .destructive, action: remove)
            }
        }
        .onAppear(perform: requestCover)
    }

    /// Loads the cover through an UNSTRUCTURED task on purpose: `.task` here
    /// gets cancelled by LazyVGrid cell churn during fast scrolling — the
    /// cancelled sleep inside the loader's iCloud check made it bail with
    /// nil, leaving permanent placeholders. The shared loader dedupes
    /// concurrent requests, so churn costs nothing.
    private func requestCover() {
        guard cover == nil, !coverRequested, let url = item.coverURL else { return }
        coverRequested = true
        Task { @MainActor in
            cover = await CoverImageLoader.thumbnail(for: url)
            if cover == nil {
                coverRequested = false  // e.g. still iCloud-evicted; retry next appear
            }
        }
    }
}

/// The visual content of a cell, equatable so a selection change only
/// re-renders the two cells whose `isSelected` actually flipped instead of
/// every visible cell.
private struct BookCellContent: View, Equatable {
    let item: LibraryItem
    let overlayTags: [TagRecord]
    let isDownloading: Bool
    let isSelected: Bool
    let cover: NSImage?

    // nonisolated: the View conformance MainActor-isolates the struct, but
    // Equatable's witness must be callable anywhere. Compares values plus
    // NSImage identity — safe without isolation.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.overlayTags == rhs.overlayTags
            && lhs.isDownloading == rhs.isDownloading
            && lhs.isSelected == rhs.isSelected
            && lhs.cover === rhs.cover
    }

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
        .padding(6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.14))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}
#endif
