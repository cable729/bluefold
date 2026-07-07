#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI

/// The ⌘F find bar for the active tab's document.
struct FindBarView: View {
    let document: PDFDocument
    unowned let model: ReaderWindowModel
    @Bindable var find: FindController
    let dismiss: () -> Void

    @State private var query = ""
    /// History gets one push per search session (the origin), not one per hop.
    @State private var pushedOrigin = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(startSearch)

            if find.isSearching {
                ProgressView().controlSize(.small)
            } else if !find.matches.isEmpty {
                Text("\(matchNumber) of \(find.matches.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !query.isEmpty, find.didSearch {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: { move(-1) }) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find.matches.isEmpty)
            Button(action: { move(1) }) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(find.matches.isEmpty)

            Button("Done", action: dismissBar)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { fieldFocused = true }
        .onChange(of: find.currentIndex) { _, _ in
            applyCurrentMatch()
        }
        .onChange(of: find.matches.count) { _, _ in
            // Highlights update as matches stream in.
            model.activeController?.showFindResults(find.matches, current: find.current)
        }
    }

    private var matchNumber: Int {
        (find.currentIndex ?? 0) + 1
    }

    private func startSearch() {
        pushedOrigin = false
        find.search(query, in: document)
    }

    private func move(_ step: Int) {
        find.advance(by: step)
    }

    private func applyCurrentMatch() {
        guard let selection = find.current else { return }
        model.activeController?.showFindResults(find.matches, current: selection)
        guard
            let page = selection.pages.first,
            let document = model.activeTab.flatMap({ model.provider.document(for: model.url(for: $0)) })
        else { return }
        let bounds = selection.bounds(for: page)
        let entry = NavEntry(
            pageIndex: document.index(for: page),
            point: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        if pushedOrigin {
            model.activeController?.execute(entry)
        } else {
            model.jump(to: entry)
            pushedOrigin = true
        }
    }

    private func dismissBar() {
        find.cancel()
        model.activeController?.showFindResults([], current: nil)
        dismiss()
    }
}
#endif
