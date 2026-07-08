import Foundation

/// Grid selection semantics for the library, extracted from the view so the
/// click rules are testable: plain click selects exactly one item, ⌘-click
/// toggles membership, ⇧-click extends a contiguous range from the anchor
/// (the last plainly-clicked item). Esc / empty-space clicks clear.
public struct LibrarySelection: Equatable, Sendable {
    public enum Modifiers: Sendable {
        case none
        case command
        case shift
    }

    public private(set) var selectedIDs: Set<String> = []
    /// Range start for ⇧-click: the most recent plain click or ⌘-toggle-on.
    public private(set) var anchorID: String?

    public init() {}

    public var isEmpty: Bool { selectedIDs.isEmpty }
    public var count: Int { selectedIDs.count }

    public func contains(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    public mutating func clear() {
        selectedIDs = []
        anchorID = nil
    }

    /// Applies one click to the selection. `orderedIDs` is the grid's current
    /// visual order (needed to resolve ⇧-click ranges).
    public mutating func click(_ id: String, modifiers: Modifiers, orderedIDs: [String]) {
        switch modifiers {
        case .none:
            selectedIDs = [id]
            anchorID = id
        case .command:
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if selectedIDs.isEmpty {
                    anchorID = nil
                } else if anchorID == id {
                    // Keep ⇧-click usable: fall back to any remaining item.
                    anchorID = orderedIDs.first(where: selectedIDs.contains)
                }
            } else {
                selectedIDs.insert(id)
                anchorID = id
            }
        case .shift:
            guard
                let anchorID,
                let anchorIndex = orderedIDs.firstIndex(of: anchorID),
                let clickIndex = orderedIDs.firstIndex(of: id)
            else {
                // No usable anchor: behave like a plain click.
                click(id, modifiers: .none, orderedIDs: orderedIDs)
                return
            }
            let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
            // Range replaces (Finder-style), but keeps the anchor so repeated
            // ⇧-clicks pivot around the same start.
            selectedIDs = Set(orderedIDs[range])
        }
    }

    /// Drops selected ids that no longer exist in the grid (the filter or
    /// search changed underneath the selection).
    public mutating func prune(to orderedIDs: [String]) {
        let valid = Set(orderedIDs)
        selectedIDs.formIntersection(valid)
        if let anchorID, !valid.contains(anchorID) {
            self.anchorID = selectedIDs.isEmpty ? nil : selectedIDs.first
        }
        if selectedIDs.isEmpty { anchorID = nil }
    }
}
