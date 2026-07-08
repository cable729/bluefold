import Foundation
import Observation

/// User preferences that live behind the Settings window (macOS ⌘,).
///
/// Persistence follows the app's convention: `UserDefaults.standard` in the
/// real app, NOTHING from unit-test processes (`AppStores.isTestProcess`) —
/// tests inject their own suite (or nil for in-memory-only behavior).
///
/// Live application follows ThemeManager's pattern: changes apply in `didSet`
/// through a hook the owning object registers (SessionCoordinator wires
/// `onDocumentCapacityChange` to the shared DocumentProvider), so a change
/// made in the Settings window lands everywhere at once. The theme itself is
/// NOT here — `ThemeManager` already owns it, and the Settings window binds
/// to it directly.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings(
        defaults: AppStores.isTestProcess ? nil : .standard
    )

    // MARK: - Keys / defaults

    static let documentCapacityKey = "DocumentLRUCapacity"
    static let backgroundIndexingKey = "BackgroundIndexingEnabled"
    static let ocrIndexingKey = "OCRIndexingEnabled"
    static let marginAnchorsKey = "MarginAnchorsEnabled"

    public static let defaultDocumentCapacity = 3
    /// PDFDocuments are memory-mapped so residency is cheap, but each one
    /// still carries parse state and pins its file — a small window keeps
    /// the "10 GB of open books ≠ 10 GB of RAM" guarantee meaningful.
    public static let documentCapacityRange = 1...10

    /// nil = keep values in memory only (test processes without a suite).
    @ObservationIgnored private let defaults: UserDefaults?

    // MARK: - Values

    /// How many open books `DocumentProvider` keeps loaded at once (the
    /// document LRU capacity). Clamped to `documentCapacityRange`; applied
    /// live via `onDocumentCapacityChange`.
    public var documentCapacity: Int {
        didSet {
            let clamped = Self.clampedCapacity(documentCapacity)
            if documentCapacity != clamped {
                documentCapacity = clamped  // re-enters didSet once, then settles
                return
            }
            guard documentCapacity != oldValue else { return }
            defaults?.set(documentCapacity, forKey: Self.documentCapacityKey)
            onDocumentCapacityChange?(documentCapacity)
        }
    }

    /// Whether the library runs its background full-text indexing pass after
    /// every reload. Turning it off stops search results from inside book
    /// text for anything not already indexed (existing index entries keep
    /// working).
    public var backgroundIndexingEnabled: Bool {
        didSet {
            guard backgroundIndexingEnabled != oldValue else { return }
            defaults?.set(backgroundIndexingEnabled, forKey: Self.backgroundIndexingKey)
        }
    }

    /// Whether indexing falls back to OCR for pages without a text layer
    /// (scanned books). Applies to the NEXT indexing pass.
    public var ocrIndexingEnabled: Bool {
        didSet {
            guard ocrIndexingEnabled != oldValue else { return }
            defaults?.set(ocrIndexingEnabled, forKey: Self.ocrIndexingKey)
        }
    }

    /// Margin heading anchors: the clickable link glyphs next to chapters/
    /// sections/theorems. Heading detection is heuristic and can misfire on
    /// odd books (round 16.1 owner feedback: "kinda wonky"), so it has a
    /// kill switch. Applies live — every visible pane observes it.
    public var marginAnchorsEnabled: Bool {
        didSet {
            guard marginAnchorsEnabled != oldValue else { return }
            defaults?.set(marginAnchorsEnabled, forKey: Self.marginAnchorsKey)
        }
    }

    /// Live-apply hook for the document LRU. Called with the new (already
    /// clamped) capacity after it persisted; never called when the value
    /// didn't actually change.
    @ObservationIgnored public var onDocumentCapacityChange: ((Int) -> Void)?

    // MARK: - Init

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        documentCapacity = Self.clampedCapacity(
            defaults?.object(forKey: Self.documentCapacityKey) as? Int
                ?? Self.defaultDocumentCapacity
        )
        backgroundIndexingEnabled =
            defaults?.object(forKey: Self.backgroundIndexingKey) as? Bool ?? true
        ocrIndexingEnabled =
            defaults?.object(forKey: Self.ocrIndexingKey) as? Bool ?? true
        marginAnchorsEnabled =
            defaults?.object(forKey: Self.marginAnchorsKey) as? Bool ?? true
    }

    static func clampedCapacity(_ value: Int) -> Int {
        min(max(value, documentCapacityRange.lowerBound), documentCapacityRange.upperBound)
    }
}
