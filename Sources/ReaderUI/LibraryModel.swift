#if os(macOS)
import AppKit
import CalibreKit
import Foundation
import Observation
import ReaderPersistence

/// One book in the library UI, whichever source it came from.
public struct LibraryItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case calibre(uuid: String)
        case imported
    }

    public var id: String
    public var source: Source
    public var title: String
    public var authors: [String]
    public var calibreTags: [String]
    public var fileURL: URL
    public var coverURL: URL?
}

/// State of the library window: the Calibre source, the merged item list,
/// and the overlay database handle (tags/collections arrive in M12).
@Observable
@MainActor
public final class LibraryModel {
    public private(set) var items: [LibraryItem] = []
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    /// Books currently being pulled down from iCloud.
    public private(set) var downloading: Set<String> = []

    public var searchText = ""

    private static let calibrePathKey = "CalibreLibraryPath"

    public private(set) var calibreRoot: URL?
    let store: LibraryStore?

    public init() {
        do {
            let dir = AppDataDirectory.url()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try LibraryStore(path: dir.appendingPathComponent("library.db").path)
        } catch {
            store = nil
            loadError = "Library database unavailable: \(error.localizedDescription)"
        }

        if let stored = UserDefaults.standard.string(forKey: Self.calibrePathKey) {
            calibreRoot = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            // Auto-detect the conventional iCloud Calibre location.
            let candidate = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Calibre")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("metadata.db").path) {
                calibreRoot = candidate
                UserDefaults.standard.set(candidate.path, forKey: Self.calibrePathKey)
            }
        }
    }

    public var filteredItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.title.lowercased().contains(query)
                || item.authors.contains { $0.lowercased().contains(query) }
                || item.calibreTags.contains { $0.lowercased().contains(query) }
        }
    }

    public func attachCalibreFolder(_ url: URL) {
        calibreRoot = url
        UserDefaults.standard.set(url.path, forKey: Self.calibrePathKey)
        Task { await reload() }
    }

    public func chooseCalibreFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Calibre library folder (contains metadata.db)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachCalibreFolder(url)
    }

    public func reload() async {
        guard let calibreRoot else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            // metadata.db itself may be evicted.
            let metadata = calibreRoot.appendingPathComponent("metadata.db")
            try await FileAvailability.ensureLocal(metadata)

            let root = calibreRoot
            // CalibreLibrary reads a private copy; the fetch is fast but
            // touches disk — keep it off the main actor.
            let books = try await Task.detached(priority: .userInitiated) {
                try CalibreLibrary(libraryRoot: root).fetchBooks()
            }.value

            items = books.compactMap { book in
                guard let pdfPath = book.relativePDFPaths.first else { return nil }
                return LibraryItem(
                    id: book.uuid,
                    source: .calibre(uuid: book.uuid),
                    title: book.title,
                    authors: book.authors,
                    calibreTags: book.calibreTags,
                    fileURL: root.appendingPathComponent(pdfPath),
                    coverURL: book.coverRelativePath.map { root.appendingPathComponent($0) }
                )
            }

            // Mirror Calibre books into the overlay DB so app tags can
            // attach to them (M12+); Calibre stays the metadata source.
            if let store {
                for item in items {
                    if case .calibre(let uuid) = item.source {
                        _ = try? store.upsertCalibreBook(uuid: uuid, title: item.title)
                    }
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func setItemsForTesting(_ items: [LibraryItem]) {
        self.items = items
    }

    /// Ensures the file is local (downloading from iCloud if evicted), then
    /// stages it in a reader window. Returns a new window ID if one must be
    /// opened by the caller.
    public func openItem(_ item: LibraryItem) async throws -> UUID? {
        downloading.insert(item.id)
        defer { downloading.remove(item.id) }
        try await FileAvailability.ensureLocal(item.fileURL)
        return SessionCoordinator.shared.openInReader(fileURL: item.fileURL)
    }
}
#endif
