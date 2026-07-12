import ReaderPersistence
import ReaderUI
import SwiftUI

/// The library scope sidebar — the iOS twin of the macOS library sidebar:
/// All Books / smart scopes / the hierarchical Tags and Collections trees,
/// each row selecting a `LibraryFilter` that filters the grid, with inline
/// create / rename / recolor / delete. iPad shows it as the leading column
/// of a `NavigationSplitView`; iPhone presents it as a sheet.
struct LibrarySidebarIOS: View {
    @Bindable var library: LibraryModel
    /// Called after a scope is chosen — dismisses the sheet on iPhone.
    var onSelect: (() -> Void)?

    @State private var pendingCreate: PendingCreate?
    @State private var pendingRename: PendingRename?
    @State private var nameText = ""
    /// The row a book is being dragged over (drop-to-tag highlight).
    @State private var dropTargetTagID: Int64?
    @State private var dropTargetCollectionID: Int64?

    private enum PendingCreate: Identifiable {
        case tag(parent: Int64?)
        case collection(parent: Int64?)
        var id: String {
            switch self {
            case .tag(let p): "tag-\(p.map(String.init) ?? "root")"
            case .collection(let p): "col-\(p.map(String.init) ?? "root")"
            }
        }
    }

    private enum PendingRename: Identifiable {
        case tag(TagRecord)
        case collection(CollectionRecord)
        var id: String {
            switch self {
            case .tag(let t): "tag-\(t.id ?? -1)"
            case .collection(let c): "col-\(c.id ?? -1)"
            }
        }
    }

    var body: some View {
        List {
            Section {
                scopeRow(.all, "All Books", systemImage: "books.vertical")
                scopeRow(.untagged, "Untagged", systemImage: "tag.slash",
                         count: library.untaggedCount)
                scopeRow(.notInAnyCollection, "Not in a Collection",
                         systemImage: "square.stack.3d.up.slash",
                         count: library.notInAnyCollectionCount)
            }

            Section {
                ForEach(flatTags, id: \.record) { entry in
                    tagRow(entry.record, depth: entry.depth)
                }
            } header: {
                sectionHeader("Tags") { pendingCreate = .tag(parent: nil); nameText = "" }
            }

            Section {
                ForEach(flatCollections, id: \.record) { entry in
                    collectionRow(entry.record, depth: entry.depth)
                }
            } header: {
                sectionHeader("Collections") {
                    pendingCreate = .collection(parent: nil); nameText = ""
                }
            }
        }
        .listStyle(.sidebar)
        .alert("New \(pendingCreate.map(kind) ?? "")", isPresented: creatingBinding) {
            TextField("Name", text: $nameText)
            Button("Create") { commitCreate() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: renamingBinding) {
            TextField("Name", text: $nameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Rows

    private func scopeRow(
        _ filter: LibraryFilter, _ title: String, systemImage: String, count: Int? = nil
    ) -> some View {
        Button {
            library.filter = filter
            onSelect?()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").foregroundStyle(.secondary).font(.caption)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(for: filter))
    }

    private func tagRow(_ tag: TagRecord, depth: Int) -> some View {
        Button {
            library.filter = .tag(tag.id ?? -1)
            onSelect?()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(TagColor.color(fromHex: tag.color) ?? Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(tag.name).lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            dropTargetTagID == tag.id
                ? Color.accentColor.opacity(0.25)
                : rowBackground(for: .tag(tag.id ?? -1))
        )
        // Drag a book from the grid onto a tag to apply it.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let itemID = DragPayload.decodeBook(payload),
                  let id = tag.id
            else { return false }
            library.addTag(tagID: id, toItemIDs: [itemID])
            return true
        } isTargeted: { targeted in
            dropTargetTagID = targeted ? tag.id : nil
        }
        .contextMenu {
            Button {
                pendingCreate = .tag(parent: tag.id); nameText = ""
            } label: { Label("New Subtag…", systemImage: "plus") }
            Button {
                pendingRename = .tag(tag); nameText = tag.name
            } label: { Label("Rename…", systemImage: "pencil") }
            Menu {
                Button("None") { if let id = tag.id { library.setTagColor(id: id, color: nil) } }
                ForEach(TagColor.presets) { preset in
                    Button {
                        if let id = tag.id { library.setTagColor(id: id, color: preset.hex) }
                    } label: {
                        Label(preset.name, systemImage: "circle.fill")
                    }
                }
            } label: { Label("Color", systemImage: "paintpalette") }
            Divider()
            Button(role: .destructive) {
                if let id = tag.id { library.deleteTag(id: id) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func collectionRow(_ collection: CollectionRecord, depth: Int) -> some View {
        Button {
            library.filter = .collection(collection.id ?? -1)
            onSelect?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(collection.name).lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            dropTargetCollectionID == collection.id
                ? Color.accentColor.opacity(0.25)
                : rowBackground(for: .collection(collection.id ?? -1))
        )
        // Drag a book onto a collection to add it.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let itemID = DragPayload.decodeBook(payload),
                  let id = collection.id
            else { return false }
            library.addToCollection(collectionID: id, itemIDs: [itemID])
            return true
        } isTargeted: { targeted in
            dropTargetCollectionID = targeted ? collection.id : nil
        }
        .contextMenu {
            Button {
                pendingCreate = .collection(parent: collection.id); nameText = ""
            } label: { Label("New Subcollection…", systemImage: "plus") }
            Button {
                pendingRename = .collection(collection); nameText = collection.name
            } label: { Label("Rename…", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) {
                if let id = collection.id { library.deleteCollection(id: id) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New \(title.dropLast())")
        }
    }

    private func rowBackground(for filter: LibraryFilter) -> Color? {
        library.filter == filter ? Color.accentColor.opacity(0.15) : nil
    }

    // MARK: - Tree flattening (depth-indented rows)

    private var flatTags: [(record: TagRecord, depth: Int)] {
        func flatten(_ nodes: [TagNode], depth: Int) -> [(TagRecord, Int)] {
            nodes.flatMap { [($0.tag, depth)] + flatten($0.children, depth: depth + 1) }
        }
        return flatten(library.tagTree, depth: 0)
    }

    private var flatCollections: [(record: CollectionRecord, depth: Int)] {
        func flatten(_ nodes: [CollectionNode], depth: Int) -> [(CollectionRecord, Int)] {
            nodes.flatMap { [($0.collection, depth)] + flatten($0.children, depth: depth + 1) }
        }
        return flatten(library.collectionTree, depth: 0)
    }

    // MARK: - Create / rename

    private func kind(_ create: PendingCreate) -> String {
        switch create {
        case .tag: "Tag"
        case .collection: "Collection"
        }
    }

    private var creatingBinding: Binding<Bool> {
        Binding(get: { pendingCreate != nil }, set: { if !$0 { pendingCreate = nil } })
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })
    }

    private func commitCreate() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let create = pendingCreate else { return }
        switch create {
        case .tag(let parent): library.createTag(name: name, parent: parent)
        case .collection(let parent): library.createCollection(name: name, parent: parent)
        }
        pendingCreate = nil
    }

    private func commitRename() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let rename = pendingRename else { return }
        switch rename {
        case .tag(let tag): if let id = tag.id { library.renameTag(id: id, to: name) }
        case .collection(let c): if let id = c.id { library.renameCollection(id: id, to: name) }
        }
        pendingRename = nil
    }
}
