import Testing

@testable import ReaderUI

@Suite("Library grid selection")
struct LibrarySelectionTests {
    private let ids = ["a", "b", "c", "d", "e"]

    @Test func plainClickSelectsExactlyOne() {
        var sel = LibrarySelection()
        sel.click("b", modifiers: .none, orderedIDs: ids)
        #expect(sel.selectedIDs == ["b"])
        #expect(sel.anchorID == "b")

        // Plain click replaces, never accumulates.
        sel.click("d", modifiers: .none, orderedIDs: ids)
        #expect(sel.selectedIDs == ["d"])
        #expect(sel.anchorID == "d")
    }

    @Test func commandClickTogglesMembership() {
        var sel = LibrarySelection()
        sel.click("a", modifiers: .none, orderedIDs: ids)
        sel.click("c", modifiers: .command, orderedIDs: ids)
        #expect(sel.selectedIDs == ["a", "c"])
        #expect(sel.anchorID == "c")

        sel.click("c", modifiers: .command, orderedIDs: ids)
        #expect(sel.selectedIDs == ["a"])
        // Toggling the anchor off falls back to a remaining item.
        #expect(sel.anchorID == "a")

        sel.click("a", modifiers: .command, orderedIDs: ids)
        #expect(sel.isEmpty)
        #expect(sel.anchorID == nil)
    }

    @Test func shiftClickSelectsRangeFromAnchor() {
        var sel = LibrarySelection()
        sel.click("b", modifiers: .none, orderedIDs: ids)
        sel.click("d", modifiers: .shift, orderedIDs: ids)
        #expect(sel.selectedIDs == ["b", "c", "d"])
        // Anchor survives, so a second ⇧-click pivots around it…
        sel.click("a", modifiers: .shift, orderedIDs: ids)
        #expect(sel.selectedIDs == ["a", "b"])
        #expect(sel.anchorID == "b")
    }

    @Test func shiftClickWithoutAnchorActsLikePlainClick() {
        var sel = LibrarySelection()
        sel.click("c", modifiers: .shift, orderedIDs: ids)
        #expect(sel.selectedIDs == ["c"])
        #expect(sel.anchorID == "c")
    }

    @Test func shiftClickWithStaleAnchorActsLikePlainClick() {
        var sel = LibrarySelection()
        sel.click("b", modifiers: .none, orderedIDs: ids)
        // The grid re-filtered; "b" is gone but the anchor wasn't pruned yet.
        sel.click("d", modifiers: .shift, orderedIDs: ["c", "d", "e"])
        #expect(sel.selectedIDs == ["d"])
        #expect(sel.anchorID == "d")
    }

    @Test func clearEmptiesEverything() {
        var sel = LibrarySelection()
        sel.click("a", modifiers: .none, orderedIDs: ids)
        sel.click("e", modifiers: .shift, orderedIDs: ids)
        sel.clear()
        #expect(sel.isEmpty)
        #expect(sel.anchorID == nil)
    }

    @Test func pruneDropsIDsMissingFromTheGrid() {
        var sel = LibrarySelection()
        sel.click("a", modifiers: .none, orderedIDs: ids)
        sel.click("c", modifiers: .shift, orderedIDs: ids)
        #expect(sel.selectedIDs == ["a", "b", "c"])

        sel.prune(to: ["b", "d"])
        #expect(sel.selectedIDs == ["b"])
        // Anchor "a" vanished; a surviving selected id takes over.
        #expect(sel.anchorID == "b")

        sel.prune(to: ["d"])
        #expect(sel.isEmpty)
        #expect(sel.anchorID == nil)
    }
}
