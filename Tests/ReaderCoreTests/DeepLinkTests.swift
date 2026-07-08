import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

@Suite struct DeepLinkTests {
    // MARK: - Formatting

    @Test func formatsHashOnlyLink() {
        let link = DeepLink(contentHash: "abc123")
        #expect(link.url().absoluteString == "pdfreader://open?hash=abc123")
    }

    @Test func formatsPageAndPoint() {
        let link = DeepLink(
            contentHash: "abc123",
            pageIndex: 41,
            point: CGPoint(x: 72.04, y: 590.5)
        )
        // page is 1-based in the URL, coordinates keep one decimal.
        #expect(link.url().absoluteString == "pdfreader://open?hash=abc123&page=42&x=72.0&y=590.5")
    }

    @Test func formatsDestinationWithSpecialCharacters() {
        let link = DeepLink(contentHash: "abc", destination: "theorem 1.2/α")
        let url = link.url()
        #expect(DeepLink(url: url)?.destination == "theorem 1.2/α")
    }

    // MARK: - Parsing

    @Test func roundTripsEveryField() {
        let original = DeepLink(
            contentHash: "deadbeef",
            destination: "section.1.1",
            pageIndex: 20,
            point: CGPoint(x: 21.0, y: 590.0)
        )
        let parsed = DeepLink(url: original.url())
        #expect(parsed == original)
    }

    @Test func parsesOneBasedPageToZeroBasedIndex() {
        let link = DeepLink(url: URL(string: "pdfreader://open?hash=h&page=1")!)
        #expect(link?.pageIndex == 0)
    }

    @Test func pointRequiresBothCoordinates() {
        let missingY = DeepLink(url: URL(string: "pdfreader://open?hash=h&page=3&x=10")!)
        #expect(missingY?.pageIndex == 2)
        #expect(missingY?.point == nil)
    }

    @Test func pointWithoutPageIsIgnored() {
        let link = DeepLink(url: URL(string: "pdfreader://open?hash=h&x=10&y=20")!)
        #expect(link?.point == nil)
        #expect(link?.navEntry == nil)
    }

    @Test func rejectsWrongSchemeHostAndMissingHash() {
        #expect(DeepLink(url: URL(string: "https://open?hash=h")!) == nil)
        #expect(DeepLink(url: URL(string: "pdfreader://close?hash=h")!) == nil)
        #expect(DeepLink(url: URL(string: "pdfreader://open?page=3")!) == nil)
        #expect(DeepLink(url: URL(string: "pdfreader://open?hash=")!) == nil)
    }

    @Test func rejectsInvalidPageNumbers() {
        #expect(DeepLink(url: URL(string: "pdfreader://open?hash=h&page=0")!)?.pageIndex == nil)
        #expect(DeepLink(url: URL(string: "pdfreader://open?hash=h&page=x")!)?.pageIndex == nil)
    }

    @Test func schemeIsCaseInsensitive() {
        #expect(DeepLink(url: URL(string: "PDFReader://OPEN?hash=h")!) != nil)
    }

    @Test func navEntryCarriesPageAndPoint() {
        let link = DeepLink(url: URL(string: "pdfreader://open?hash=h&page=5&x=1.5&y=2.5")!)
        #expect(link?.navEntry == NavEntry(pageIndex: 4, point: CGPoint(x: 1.5, y: 2.5)))
    }
}
