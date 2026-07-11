#if os(macOS)
import AppKit
import PDFKit
import ReaderCore
import ReaderPersistence

/// Opens URLs handed over by the AppDelegate: `bluefold://` deep links
/// (resolved through the library by content hash) and plain file URLs —
/// Finder "Open With"/default-handler opens, dock drops — which go straight
/// into a reader tab.
///
/// URLs can arrive at launch, before any SwiftUI scene exists to present a
/// staged window — they queue until the first scene view registers its
/// `openWindow` action.
@MainActor
public final class DeepLinkRouter {
    public static let shared = DeepLinkRouter()

    private var presentReaderWindow: ((UUID) -> Void)?
    private var queued: [URL] = []

    /// Scene views (reader + library) call this on appear; the latest
    /// registration wins, and any launch-time URLs flush through it.
    public func registerPresenter(_ present: @escaping (UUID) -> Void) {
        presentReaderWindow = present
        let flush = queued
        queued = []
        for url in flush { handle(url) }
    }

    public func handle(_ url: URL) {
        guard presentReaderWindow != nil else {
            queued.append(url)
            return
        }
        Task { await open(url) }
    }

    // MARK: - Resolution

    /// Library lookup: content hash → book row → file path. Pure so tests
    /// can drive it with an in-memory store.
    public static func fileURL(for link: DeepLink, store: LibraryStore) -> URL? {
        guard
            let book = try? store.book(byContentHash: link.contentHash),
            let bookID = book.id,
            let path = try? store.pathHint(forBookID: bookID)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The position a link aims at inside its (already loaded) document.
    /// A resolving named destination beats the page fallback; garbage
    /// points are the navigation pipeline's problem (validatedPoint).
    public static func entry(for link: DeepLink, in document: PDFDocument?) -> NavEntry? {
        if let name = link.destination, let document,
           let target = NamedDestinations.resolve(name, in: document) {
            return NavEntry(pageIndex: target.pageIndex, point: target.point)
        }
        return link.navEntry
    }

    private func open(_ url: URL) async {
        if url.isFileURL {
            await openFile(url)
            return
        }
        guard let link = DeepLink(url: url) else {
            fail("“\(url.absoluteString)” is not a valid \(DeepLink.primaryScheme):// link.")
            return
        }
        guard let store = AppStores.library else {
            fail("The library database is unavailable.")
            return
        }
        guard let fileURL = Self.fileURL(for: link, store: store) else {
            fail("No book in the library matches this link. Import the book, then try again.")
            return
        }
        do {
            try await FileAvailability.ensureLocal(fileURL)
        } catch {
            fail("Couldn't download “\(fileURL.lastPathComponent)” from iCloud: \(error.localizedDescription)")
            return
        }
        // The provider caches this load; the tab about to open reuses it.
        let document = link.destination != nil
            ? SessionCoordinator.shared.provider.document(for: fileURL)
            : nil
        let entry = Self.entry(for: link, in: document)
        if let staged = SessionCoordinator.shared.openInReader(fileURL: fileURL, at: entry) {
            presentReaderWindow?(staged)
        }
        NSApp.activate()
    }

    /// A PDF opened from outside the app (Finder, dock drop). No library
    /// lookup — the file is the target; the library import, if the user
    /// wants one, is the watched-folder pipeline's job.
    private func openFile(_ fileURL: URL) async {
        do {
            try await FileAvailability.ensureLocal(fileURL)
        } catch {
            fail(
                "Couldn't download “\(fileURL.lastPathComponent)” from iCloud: "
                    + error.localizedDescription,
                title: "Couldn't Open File"
            )
            return
        }
        if let staged = SessionCoordinator.shared.openInReader(fileURL: fileURL) {
            presentReaderWindow?(staged)
        }
        NSApp.activate()
    }

    private func fail(_ message: String, title: String = "Couldn't Open Link") {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
#endif
