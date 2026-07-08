#if os(macOS)
import PDFKit
import ReaderCore
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
    /// Library books, fetched ONCE per palette appearance — `rows` is
    /// recomputed per keystroke and must never hit SQLite.
    @State private var libraryBooks: [BookCandidateInput] = []

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
                        // ⌘Return: background variant. Plain Return falls
                        // through to onSubmit.
                        guard press.modifiers.contains(.command) else { return .ignored }
                        runSelected(inBackground: true)
                        return .handled
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

    /// Quick-open source: every library book with a known file location
    /// (Calibre paths are mirrored into file_ref at library reload).
    private func loadLibraryBooks() {
        guard mode == .navigate else { return }
        let books = AppStores.library.flatMap { try? $0.openableBooks() } ?? []
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
    }

    private var headerIcon: String {
        switch mode {
        case .navigate: "location"
        case .commands: "command"
        case .goToPage: "number"
        }
    }

    private var placeholder: String {
        switch mode {
        case .navigate: "Go to section, bookmark, tab, or library book…"
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
                                PaletteRowView(row: row, isSelected: index == selection)
                                    .id(row.id)
                                    .onTapGesture {
                                        selection = index
                                        let cmdHeld = NSApp.currentEvent?
                                            .modifierFlags.contains(.command) == true
                                        runSelected(inBackground: cmdHeld)
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
        case .navigate: "No matching section, bookmark, tab, or book"
        case .commands: "No matching command"
        case .goToPage: ""
        }
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
        let run: @MainActor () -> Void
        /// ⌘-click / ⌘-Return variant: act without switching away (open a
        /// background tab, browser-style). nil = no background form.
        var runInBackground: (@MainActor () -> Void)?
    }

    private var rows: [Row] {
        switch mode {
        case .commands: commandRows()
        case .navigate: navigateRows()
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
                run: { [context] in command.run(context) }
            )
        }
    }

    private func navigateRows() -> [Row] {
        rank(
            items: assembleCandidates(),
            text: \.title,
            fallbackText: \.searchText
        ) { candidate, match in
            navigateRow(for: candidate, match: match)
        }
    }

    private func navigateRow(for candidate: NavigateCandidate, match: FuzzyMatch?) -> Row {
        var background: (@MainActor () -> Void)?
        if hasBackgroundForm(candidate.action) {
            background = { perform(candidate.action, inBackground: true) }
        }
        return Row(
            id: candidate.id,
            icon: candidate.icon,
            title: candidate.title,
            subtitle: candidate.subtitle,
            trailing: nil,
            highlight: match?.matchedIndices ?? [],
            run: { perform(candidate.action, inBackground: false) },
            runInBackground: background
        )
    }

    /// Switching to a tab has no meaningful background form.
    private func hasBackgroundForm(_ action: NavigateCandidate.Action) -> Bool {
        switch action {
        case .jump, .openBook: true
        case .selectTab: false
        }
    }

    /// Live inputs → pure assembly (`NavigateCandidates.assemble` is the
    /// unit-tested part).
    private func assembleCandidates() -> [NavigateCandidate] {
        let outline = context.activeDocument.map { model.outline(for: $0) } ?? []
        let bookmarks = model.activeBookmarks.map {
            BookmarkCandidateInput(page: $0.page, label: $0.label)
        }

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

        return NavigateCandidates.assemble(
            outline: outline, bookmarks: bookmarks, tabs: tabs,
            books: libraryBooks, openPaths: openPaths
        )
    }

    /// `inBackground` = ⌘ variant: open a NEW tab without switching to it
    /// (browser ⌘-click). Jumps become an adjacent background tab at the
    /// target; books open unactivated.
    private func perform(_ action: NavigateCandidate.Action, inBackground: Bool) {
        switch action {
        case .jump(let entry):
            if inBackground, let tab = model.activeTab {
                model.openTab(
                    fileURL: model.url(for: tab), activate: false,
                    at: entry, after: tab.id
                )
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
            // iCloud-evicted books download first; the tab opens when the
            // bytes are local (same behavior as opening from the library).
            // Weak: the window (and its model) may close mid-download.
            let model = self.model
            Task { @MainActor [weak model] in
                try? await FileAvailability.ensureLocal(url)
                model?.openTab(fileURL: url, activate: !inBackground)
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

    private func runSelected(inBackground: Bool = false) {
        switch mode {
        case .goToPage:
            guard let page = GoToPage.parse(query, pageCount: pageCount) else { return }
            model.jump(to: NavEntry(pageIndex: page))
        case .navigate, .commands:
            let rows = self.rows
            guard rows.indices.contains(selection) else { return }
            let row = rows[selection]
            if inBackground, let background = row.runInBackground {
                // Background open keeps the palette up (and focus in the
                // query field) so several books/sections can be queued —
                // the point of ⌘-click is "don't switch me away".
                background()
                return
            }
            dismiss()
            row.run()
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
            if let trailing = row.trailing, !trailing.isEmpty {
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
