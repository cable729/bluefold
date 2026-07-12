import Observation
import PDFKit

/// Drives in-document text search via PDFKit's async find, collecting match
/// selections as they stream in and tracking the highlighted match.
///
/// Restart correctness: PDFKit's find runs on a background thread and its
/// notifications are queued to the main thread, so `document.isFinding` and
/// the delivered notifications can disagree for a moment. This controller
/// therefore counts finds it started itself (`outstandingFinds`, one
/// DidEndFind owed per beginFindString — cancelled finds post it too) and
/// only starts a superseding query once the previous find has fully drained.
/// Stale matches — anything delivered while more than our one live find is
/// outstanding, or while a query is parked — are dropped, so results from an
/// old query can never land after a newer one.
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
    /// Finds we started on `document` whose DidEndFind has not arrived yet.
    @ObservationIgnored private var outstandingFinds = 0
    /// Query parked until the cancelled find(s) drain. Non-nil exactly while
    /// draining; match notifications in that window are stale and dropped.
    @ObservationIgnored private var pendingQuery: String?
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
                    // Stale-match filter: accept only when the single find we
                    // consider live is the only one outstanding.
                    self.isSearching, self.pendingQuery == nil, self.outstandingFinds == 1,
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
                self.outstandingFinds = max(0, self.outstandingFinds - 1)
                guard self.outstandingFinds == 0 else { return }
                if self.pendingQuery != nil {
                    // The cancelled find has fully drained (notifications are
                    // delivered in posting order, so no stale match can
                    // follow its DidEndFind). Start the superseding query —
                    // but NOT from inside this notification's delivery:
                    // beginFindString issued re-entrantly is silently broken
                    // (PDFKit reports isFinding yet never posts a match or
                    // DidEndFind; verified empirically). Hop the main queue
                    // once and start from a clean stack. The query stays
                    // parked until the hop so a newer search() can still
                    // replace or clear it.
                    Task { @MainActor [weak self] in
                        self?.startPendingQuery()
                    }
                } else if self.isSearching {
                    self.isSearching = false
                }
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

    /// Starts (or restarts) a search. Safe to call rapid-fire while a
    /// previous find is still streaming — see the type comment.
    public func search(_ query: String, in document: PDFDocument) {
        if self.document !== document {
            // Switching documents: stop any find on the previous one. Its
            // notifications no longer pass the identity guard, so the
            // counter restarts from zero for the new document.
            if let previous = self.document, previous.isFinding {
                previous.cancelFindString()
            }
            self.document = document
            outstandingFinds = 0
        }
        matches = []
        currentIndex = nil
        pendingQuery = nil

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancelOutstanding()
            isSearching = false
            didSearch = false
            return
        }

        didSearch = true
        isSearching = true
        if outstandingFinds > 0 {
            // Park the query until the cancelled find posts DidEndFind
            // (see the observer above).
            pendingQuery = query
            cancelOutstanding()
        } else {
            beginFind(query, in: document)
        }
    }

    public func cancel() {
        cancelOutstanding()
        pendingQuery = nil
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

    /// Runs one main-queue hop after the cancelled find's DidEndFind. If a
    /// newer search() landed in the gap it has already replaced or cleared
    /// the parked query (and bumped `outstandingFinds` if it began
    /// directly), so the guards make this a no-op.
    private func startPendingQuery() {
        guard outstandingFinds == 0, let pending = pendingQuery, let document else { return }
        pendingQuery = nil
        beginFind(pending, in: document)
    }

    private func beginFind(_ query: String, in document: PDFDocument) {
        outstandingFinds += 1
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    private func cancelOutstanding() {
        if let document, document.isFinding {
            document.cancelFindString()
        }
    }
}
