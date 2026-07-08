#if os(macOS)
import PDFKit
import ReaderCore
import ReaderPersistence
import SwiftUI

/// Floating, keyboard-first palette: fuzzy search with ↑↓ + Return + Esc.
/// One view serves all three modes (navigate / commands / go-to-page) so the
/// look and key handling never diverge.
struct PaletteOverlay: View {
    let mode: PaletteMode
    unowned let model: ReaderWindowModel
    let ui: ReaderWindowUIState
    let context: CommandContext

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool
    /// Library data, fetched ONCE per palette appearance — `rows` is
    /// recomputed per keystroke and must never hit SQLite.
    @State private var libraryBooks: [BookCandidateInput] = []
    @State private var libraryCollections: [GroupCandidateInput] = []
    @State private var libraryTags: [GroupCandidateInput] = []

    /// Modifiers currently held, tracked live so the UI can SHOW what
    /// ⌘/⇧ will do before the user commits (round-9 owner request).
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var flagsMonitor: Any?

    /// How a row is invoked: plain (activate), ⌘ (background — open
    /// without switching, palette stays up), ⇧ or ⌥ (new window —
    /// browser convention: ⌘=tab, ⇧=window).
    enum RunVariant {
        case activate, background, newWindow
    }

    /// The variant the currently held modifiers select.
    private var heldVariant: RunVariant {
        if heldModifiers.contains(.command) { return .background }
        if !heldModifiers.intersection([.shift, .option]).isEmpty { return .newWindow }
        return .activate
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            panel
                .padding(.top, 48)
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(keys: [.return]) { press in
                        // ⌘Return: background open. ⇧/⌥Return: new window.
                        // Plain Return falls through to onSubmit.
                        if press.modifiers.contains(.command) {
                            runSelected(variant: .background)
                            return .handled
                        }
                        if !press.modifiers.intersection([.shift, .option]).isEmpty {
                            runSelected(variant: .newWindow)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        move(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(12)

            Divider()

            if mode == .goToPage {
                goToPageHint
            } else {
                resultsList
                if mode == .navigate || mode == .outline {
                    Divider()
                    variantLegend
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onAppear {
            fieldFocused = true
            loadLibraryBooks()
            // Live ⌘/⇧ feedback while the palette is up.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                heldModifiers = event.modifierFlags
                    .intersection([.command, .shift, .option])
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor {
                NSEvent.removeMonitor(flagsMonitor)
            }
            flagsMonitor = nil
        }
        .task {
            // Focus can lose the race against an AppKit first responder
            // (⌘O arrives via an NSEvent monitor while the PDFView holds
            // focus); one delayed re-assert settles it.
            try? await Task.sleep(for: .milliseconds(80))
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: mode) { _, _ in
            query = ""
            selection = 0
            fieldFocused = true
            loadLibraryBooks()
        }
    }

    /// Open-palette sources: every library book with a known file location
    /// (Calibre paths are mirrored into file_ref at library reload), plus
    /// collections and tags with their subtree book counts.
    private func loadLibraryBooks() {
        guard mode == .navigate, let store = AppStores.library else { return }
        let books = (try? store.openableBooks()) ?? []
        // One row per FILE: a book auto-registered before its Calibre row
        // was mirrored exists twice with the same path.
        var seen = Set<String>()
        libraryBooks = books.compactMap { book in
            let path = DocumentProvider.canonicalPath(
                for: URL(fileURLWithPath: book.pathHint)
            )
            guard seen.insert(path).inserted else { return nil }
            return BookCandidateInput(title: book.title, path: path)
        }
        libraryCollections = ((try? store.collections()) ?? []).compactMap { collection in
            guard let id = collection.id else { return nil }
            let count = (try? store.books(inCollectionSubtree: id).count) ?? 0
            return GroupCandidateInput(id: id, name: collection.name, bookCount: count)
        }
        libraryTags = ((try? store.tagTree()) ?? []).flatMap(Self.flattenTags).compactMap { tag in
            guard let id = tag.id else { return nil }
            let count = (try? store.books(withTag: id, includeDescendantTags: true).count) ?? 0
            return GroupCandidateInput(id: id, name: tag.name, bookCount: count)
        }
    }

    private static func flattenTags(_ node: TagNode) -> [TagRecord] {
        [node.tag] + node.children.flatMap(flattenTags)
    }

    private var headerIcon: String {
        switch mode {
        case .navigate: "books.vertical"
        case .outline: "list.bullet"
        case .commands: "command"
        case .goToPage: "number"
        }
    }

    private var placeholder: String {
        switch mode {
        case .navigate: "Open book, collection, tag, or tab…"
        case .outline: "Go to section or bookmark…"
        case .commands: "Run a command…"
        case .goToPage: "Page number (1–\(pageCount))…"
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        let rows = self.rows
        return Group {
            if rows.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                PaletteRowView(
                                    row: row,
                                    isSelected: index == selection,
                                    badge: index == selection ? selectedRowBadge(row) : nil
                                )
                                    .id(row.id)
                                    .onTapGesture {
                                        selection = index
                                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                                        let variant: RunVariant =
                                            flags.contains(.command) ? .background
                                            : !flags.intersection([.shift, .option]).isEmpty
                                                ? .newWindow
                                            : .activate
                                        runSelected(variant: variant)
                                    }
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, new in
                        guard rows.indices.contains(new) else { return }
                        proxy.scrollTo(rows[new].id)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .navigate: "No matching book, collection, tag, or tab"
        case .outline: "No matching section or bookmark"
        case .commands: "No matching command"
        case .goToPage: ""
        }
    }

    /// What the held modifiers would do to the SELECTED row — shown as its
    /// trailing badge so the effect is visible before committing.
    private func selectedRowBadge(_ row: Row) -> String? {
        guard row.supportsBackground else { return nil }
        switch heldVariant {
        case .background: return "→ background tab"
        case .newWindow: return "→ new window"
        case .activate: return nil
        }
    }

    /// Footer legend: what ⏎ / ⌘⏎ / ⇧⏎ do, with the variant the HELD
    /// modifiers select emphasized live (round-9 owner request — the
    /// modifier behaviors were invisible until tried).
    private var variantLegend: some View {
        HStack(spacing: 18) {
            legendItem("⏎", "open", active: heldVariant == .activate)
            legendItem("⌘⏎", "background tab", active: heldVariant == .background)
            legendItem("⇧⏎", "new window", active: heldVariant == .newWindow)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func legendItem(_ chord: String, _ label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(chord)
                .font(.caption.weight(active ? .bold : .regular).monospaced())
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }

    private var goToPageHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle")
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a page number, then press Return")
            } else if let page = GoToPage.parse(query, pageCount: pageCount) {
                Text("Go to page \(page + 1) of \(pageCount) — press Return")
            } else {
                Text("Not a page in this book (1–\(pageCount))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var pageCount: Int {
        context.activeDocument?.pageCount ?? 0
    }

    // MARK: - Row assembly

    fileprivate struct Row: Identifiable {
        let id: String
        let icon: String?
        let title: String
        let subtitle: String?
        let trailing: String?
        /// Matched character offsets in `title` (bold highlight).
        let highlight: [Int]
        let run: @MainActor (RunVariant) -> Void
        /// Whether ⌘ (background) keeps the palette open for this row.
        var supportsBackground = false
    }

    private var rows: [Row] {
        switch mode {
        case .commands: commandRows()
        case .navigate: navigateRows(candidates: openCandidates())
        case .outline: navigateRows(candidates: inBookCandidates())
        case .goToPage: []
        }
    }

    private func commandRows() -> [Row] {
        let available = CommandRegistry.all.filter { $0.isAvailable(context) }
        return rank(
            items: available,
            text: \.title,
            fallbackText: { "\($0.category.rawValue) \($0.title)" }
        ) { command, match in
            Row(
                id: command.id,
                icon: nil,
                title: command.title,
                subtitle: command.category.rawValue,
                trailing: command.chords.map(\.display).joined(separator: "  "),
                highlight: match?.matchedIndices ?? [],
                run: { [context] _ in command.run(context) }
            )
        }
    }

    private func navigateRows(candidates: [NavigateCandidate]) -> [Row] {
        rank(
            items: candidates,
            text: \.title,
            fallbackText: \.searchText
        ) { candidate, match in
            navigateRow(for: candidate, match: match)
        }
    }

    private func navigateRow(for candidate: NavigateCandidate, match: FuzzyMatch?) -> Row {
        Row(
            id: candidate.id,
            icon: candidate.icon,
            title: candidate.title,
            subtitle: candidate.subtitle,
            trailing: nil,
            highlight: match?.matchedIndices ?? [],
            run: { perform(candidate.action, variant: $0) },
            supportsBackground: hasBackgroundForm(candidate.action)
        )
    }

    /// Switching to a tab has no meaningful background form.
    private func hasBackgroundForm(_ action: NavigateCandidate.Action) -> Bool {
        switch action {
        case .jump, .openBook, .openCollection, .openTag: true
        case .selectTab: false
        }
    }

    /// OPEN palette inputs: tabs across windows + library data (pure
    /// assembly in `NavigateCandidates.assembleOpen`, unit-tested).
    private func openCandidates() -> [NavigateCandidate] {
        // Current window's tabs first (strip order), then other windows'.
        var tabs: [TabCandidateInput] = []
        var openPaths: Set<String> = []
        func append(from windowModel: ReaderWindowModel, label: String?) {
            for tab in windowModel.tabs {
                openPaths.insert(tab.pathHint)
                tabs.append(TabCandidateInput(
                    windowID: windowModel.windowID,
                    tabID: tab.id,
                    title: URL(fileURLWithPath: tab.pathHint)
                        .deletingPathExtension().lastPathComponent,
                    pageIndex: tab.pageIndex,
                    isActive: windowModel === model && tab.id == model.activeTabID,
                    windowLabel: label
                ))
            }
        }
        append(from: model, label: nil)
        for (windowID, windowModel) in SessionCoordinator.shared.models
        where windowID != model.windowID {
            append(from: windowModel, label: "other window")
        }

        return NavigateCandidates.assembleOpen(
            tabs: tabs, books: libraryBooks,
            collections: libraryCollections, tags: libraryTags,
            openPaths: openPaths
        )
    }

    /// IN-BOOK palette inputs: the active document's outline + bookmarks.
    private func inBookCandidates() -> [NavigateCandidate] {
        let outline = context.activeDocument.map { model.outline(for: $0) } ?? []
        let bookmarks = model.activeBookmarks.map {
            BookmarkCandidateInput(page: $0.page, label: $0.label)
        }
        return NavigateCandidates.assembleInBook(outline: outline, bookmarks: bookmarks)
    }

    private func perform(_ action: NavigateCandidate.Action, variant: RunVariant) {
        switch action {
        case .jump(let entry):
            if variant == .background, let tab = model.activeTab {
                // ⌘: the section opens as an adjacent background tab —
                // the reading position doesn't move (browser ⌘-click).
                model.openTab(
                    fileURL: model.url(for: tab), activate: false,
                    at: entry, after: tab.id
                )
            } else if variant == .newWindow, let tab = model.activeTab {
                // ⇧: the section opens in a fresh window at that position.
                let windowID = SessionCoordinator.shared.openInNewWindow(
                    fileURLs: [model.url(for: tab)], entries: [entry]
                )
                context.presentReaderWindow(windowID)
            } else {
                model.jump(to: entry)
            }
        case .selectTab(let windowID, let tabID):
            if windowID == model.windowID {
                model.selectTab(id: tabID)
            } else if let target = SessionCoordinator.shared.models[windowID] {
                target.selectTab(id: tabID)
                target.hostWindow?.makeKeyAndOrderFront(nil)
            }
        case .openBook(let url):
            openBooks(urls: [url], variant: variant)
        case .openCollection(let id):
            openBooks(urls: Self.bookURLs(inCollection: id), variant: variant)
        case .openTag(let id):
            openBooks(urls: Self.bookURLs(withTag: id), variant: variant)
        }
    }

    private static func bookURLs(inCollection id: Int64) -> [URL] {
        guard let store = AppStores.library else { return [] }
        return bookURLs(of: (try? store.books(inCollectionSubtree: id)) ?? [], in: store)
    }

    private static func bookURLs(withTag id: Int64) -> [URL] {
        guard let store = AppStores.library else { return [] }
        return bookURLs(
            of: (try? store.books(withTag: id, includeDescendantTags: true)) ?? [],
            in: store
        )
    }

    private static func bookURLs(of books: [BookRecord], in store: LibraryStore) -> [URL] {
        books.compactMap { book in
            guard let bookID = book.id, let ref = try? store.fileRef(forBook: bookID)
            else { return nil }
            return URL(fileURLWithPath: ref.pathHint)
        }
    }

    /// Opens a batch of books per the variant: as tabs here (first one
    /// activated), as background tabs (⌘), or in a fresh window (⇧/⌥).
    ///
    /// Every book that is ALREADY local opens immediately; iCloud-evicted
    /// ones download concurrently and open as they arrive. (The first
    /// version awaited all downloads sequentially before opening anything —
    /// one evicted book made "open the Probability tag" look completely
    /// dead for minutes.)
    private func openBooks(urls: [URL], variant: RunVariant) {
        guard !urls.isEmpty else { return }
        let model = self.model
        let present = context.presentReaderWindow

        var localNow: [URL] = []
        var evicted: [URL] = []
        for url in urls {
            if FileAvailability.isLocal(url) {
                localNow.append(url)
            } else {
                evicted.append(url)
            }
        }

        // Where late arrivals land: this window, or the new window's model.
        var lateTarget = model
        switch variant {
        case .newWindow:
            let windowID = SessionCoordinator.shared.openInNewWindow(fileURLs: localNow)
            present(windowID)
            lateTarget = SessionCoordinator.shared.model(for: windowID)
        case .background:
            for url in localNow {
                model.openTab(fileURL: url, activate: false)
            }
        case .activate:
            for (index, url) in localNow.enumerated() {
                model.openTab(fileURL: url, activate: index == 0)
            }
        }

        guard !evicted.isEmpty else { return }
        let activateFirstArrival = variant == .activate && localNow.isEmpty
        Task { @MainActor [weak lateTarget] in
            await withTaskGroup(of: URL?.self) { group in
                for url in evicted {
                    group.addTask {
                        try? await FileAvailability.ensureLocal(url)
                        return FileAvailability.isLocal(url) ? url : nil
                    }
                }
                var isFirst = true
                for await downloaded in group {
                    guard let downloaded else { continue }
                    lateTarget?.openTab(
                        fileURL: downloaded,
                        activate: activateFirstArrival && isFirst
                    )
                    isFirst = false
                }
            }
        }
    }

    /// Fuzzy-ranks `items`: title matches beat fallback (breadcrumb/category)
    /// matches; ties break toward the original assembly order. Empty query
    /// keeps assembly order.
    private func rank<T>(
        items: [T],
        text: (T) -> String,
        fallbackText: (T) -> String,
        make: (T, FuzzyMatch?) -> Row
    ) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return items.prefix(80).map { make($0, nil) }
        }
        var scored: [(score: Int, index: Int, row: Row)] = []
        for (index, item) in items.enumerated() {
            if let match = FuzzyMatcher.match(query: trimmed, in: text(item)) {
                scored.append((match.score + 4, index, make(item, match)))
            } else if let match = FuzzyMatcher.match(query: trimmed, in: fallbackText(item)) {
                // Matched via breadcrumb/category — no title highlight.
                scored.append((match.score, index, make(item, nil)))
            }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(80)
            .map(\.row)
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = ((selection + delta) % count + count) % count
    }

    private func runSelected(variant: RunVariant = .activate) {
        switch mode {
        case .goToPage:
            guard let page = GoToPage.parse(query, pageCount: pageCount) else { return }
            model.jump(to: NavEntry(pageIndex: page))
        case .navigate, .outline, .commands:
            let rows = self.rows
            guard rows.indices.contains(selection) else { return }
            let row = rows[selection]
            if variant == .background, row.supportsBackground {
                // Background open keeps the palette up (and focus in the
                // query field) so several books/sections can be queued —
                // the point of ⌘ is "don't switch me away".
                row.run(.background)
                return
            }
            dismiss()
            row.run(variant == .background ? .activate : variant)
            return
        }
        dismiss()
    }

    private func dismiss() {
        ui.dismissPalette()
        model.focusActivePDFView()
    }
}

// MARK: - Row rendering

private struct PaletteRowView: View {
    let row: PaletteOverlay.Row
    let isSelected: Bool
    /// Live modifier feedback ("→ background tab"); replaces `trailing`
    /// while a variant modifier is held.
    var badge: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon = row.icon {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
            } else if let trailing = row.trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }

    /// Bolds + tints the fuzzy-matched characters.
    private var highlightedTitle: AttributedString {
        var attributed = AttributedString(row.title)
        guard !row.highlight.isEmpty else { return attributed }
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].font = .system(size: 13, weight: .bold)
            attributed[start..<end].foregroundColor = .accentColor
        }
        return attributed
    }
}
#endif
