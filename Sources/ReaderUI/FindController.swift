#if os(macOS)
import Observation
import PDFKit

/// Drives in-document text search via PDFKit's async find, collecting match
/// selections as they stream in and tracking the highlighted match.
@MainActor
@Observable
public final class FindController {
    public private(set) var matches: [PDFSelection] = []
    public private(set) var isSearching = false
    public private(set) var currentIndex: Int?
    /// True once a search has been started (distinguishes "no results" from
    /// "not searched yet").
    public private(set) var didSearch = false

    @ObservationIgnored private weak var document: PDFDocument?
    // nonisolated(unsafe): only written in init and read in deinit.
    @ObservationIgnored private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    public init() {
        let center = NotificationCenter.default
        // Delivery is forced onto the main queue, so hopping into MainActor
        // is safe; the unsafe capture silences the (false-positive) region
        // check on the non-Sendable Notification.
        observers.append(center.addObserver(
            forName: .PDFDocumentDidFindMatch, object: nil, queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                guard
                    let self,
                    notification.object as? PDFDocument === self.document,
                    let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                else { return }
                self.matches.append(selection)
                if self.currentIndex == nil {
                    self.currentIndex = 0
                }
            }
        })
        observers.append(center.addObserver(
            forName: .PDFDocumentDidEndFind, object: nil, queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                guard let self, notification.object as? PDFDocument === self.document else { return }
                self.isSearching = false
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public var current: PDFSelection? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    public func search(_ query: String, in document: PDFDocument) {
        cancel()
        self.document = document
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        didSearch = true
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    public func cancel() {
        if let document, document.isFinding {
            document.cancelFindString()
        }
        matches = []
        currentIndex = nil
        isSearching = false
        didSearch = false
    }

    /// Explicit selection of a match (e.g. clicking a result row).
    public func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        currentIndex = index
    }

    public func advance(by step: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let base = currentIndex ?? 0
        currentIndex = ((base + step) % count + count) % count
    }
}
#endif
