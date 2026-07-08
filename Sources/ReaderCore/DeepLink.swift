import CoreGraphics
import Foundation

/// A shareable link to a position inside a library book:
///
///     pdfreader://open?hash=<contentHash>&dest=<name>&page=<1-based>&x=<pt>&y=<pt>
///
/// Links resolve through the library's content-hash lookup, so they survive
/// file moves and renames. `dest` is a PDF named destination (hyperref
/// anchors — theorem/section granularity in well-made LaTeX books) and wins
/// over `page`/`x`/`y` when both are present and the name resolves; the
/// page form is the universal fallback the app emits from "Copy Link".
public struct DeepLink: Equatable, Sendable {
    /// The single rename point. When the app gets its real name, put the
    /// new scheme FIRST and keep old ones listed so links already pasted
    /// into the owner's notes never break (Info.plist must register every
    /// scheme here).
    public static let schemes = ["pdfreader"]
    public static var primaryScheme: String { schemes[0] }
    public static let host = "open"

    public var contentHash: String
    /// PDF named destination; percent-encoded in the URL.
    public var destination: String?
    /// Zero-based page index; serialized 1-based as `page` (human-facing).
    public var pageIndex: Int?
    /// Top-left target in page space. Only meaningful with a page.
    public var point: CGPoint?

    public init(
        contentHash: String,
        destination: String? = nil,
        pageIndex: Int? = nil,
        point: CGPoint? = nil
    ) {
        self.contentHash = contentHash
        self.destination = destination
        self.pageIndex = pageIndex
        self.point = point
    }

    /// The position the link's page form encodes, ready for `openTab(at:)`.
    public var navEntry: NavEntry? {
        guard let pageIndex else { return nil }
        return NavEntry(pageIndex: pageIndex, point: point)
    }

    // MARK: - Codec

    public init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            Self.schemes.contains(scheme),
            components.host?.lowercased() == Self.host
        else { return nil }

        var byName: [String: String] = [:]
        for item in components.queryItems ?? [] {
            byName[item.name] = item.value
        }
        guard let hash = byName["hash"], !hash.isEmpty else { return nil }
        contentHash = hash
        destination = byName["dest"].flatMap { $0.isEmpty ? nil : $0 }

        if let raw = byName["page"], let page = Int(raw), page >= 1 {
            pageIndex = page - 1
            if let x = byName["x"].flatMap(Double.init),
               let y = byName["y"].flatMap(Double.init) {
                point = CGPoint(x: x, y: y)
            } else {
                point = nil
            }
        } else {
            pageIndex = nil
            point = nil
        }
        // A link must aim somewhere: a destination, a page, or (neither =
        // "open the book" — allowed).
    }

    public func url() -> URL {
        var components = URLComponents()
        components.scheme = Self.primaryScheme
        components.host = Self.host
        var items = [URLQueryItem(name: "hash", value: contentHash)]
        if let destination {
            items.append(URLQueryItem(name: "dest", value: destination))
        }
        if let pageIndex {
            items.append(URLQueryItem(name: "page", value: String(pageIndex + 1)))
            if let point {
                items.append(URLQueryItem(name: "x", value: Self.format(point.x)))
                items.append(URLQueryItem(name: "y", value: Self.format(point.y)))
            }
        }
        components.queryItems = items
        // Every component above is constructible; force-unwrap keeps the
        // call sites honest.
        return components.url!
    }

    /// One decimal place — page-space fractions below that are noise.
    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
