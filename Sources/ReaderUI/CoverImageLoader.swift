#if os(macOS)
import AppKit
import ImageIO

/// Loads book-cover thumbnails without blocking the UI.
///
/// The naive approach — `NSImage(contentsOf:)` in a view body — decodes the
/// FULL-SIZE cover on the main thread on every scroll frame, and can stall
/// on iCloud-evicted files. This loader: skips non-local files, downsamples
/// straight from the image source (never decoding the full image), does the
/// work off the main thread, caches the result, and coalesces concurrent
/// requests for the same cover (grid cell churn during scrolling asks for
/// the same URL many times).
enum CoverImageLoader {
    // NSCache is documented thread-safe.
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()
    private static let maxPixelSize = 320

    /// The image is freshly created and uniquely referenced when it crosses
    /// isolation — boxed explicitly so older Swift 6 compilers (CI) accept
    /// the transfer, not just 6.3's region analysis.
    private struct Transfer: @unchecked Sendable {
        let image: NSImage?
    }

    /// In-flight loads keyed by path: every caller for the same cover awaits
    /// the one running decode instead of racing duplicates.
    @MainActor private static var inFlight: [String: Task<Transfer, Never>] = [:]

    // @MainActor so the non-Sendable NSImage return never crosses isolation
    // (Swift 6.0 on CI rejects that; only the decode runs off-main).
    @MainActor
    static func thumbnail(for url: URL) async -> NSImage? {
        let key = url.path
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let running = inFlight[key] {
            return await running.value.image
        }
        let task = Task { await load(url) }
        inFlight[key] = task
        let image = await task.value.image
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }

    /// The slow path: iCloud materialization check plus downsampled decode,
    /// off the main actor (nonisolated async runs on the global executor).
    private nonisolated static func load(_ url: URL) async -> Transfer {
        if !FileAvailability.isLocal(url) {
            // Covers are small; pull evicted ones down (bounded wait) instead
            // of showing placeholders forever.
            try? await FileAvailability.ensureLocal(url, timeout: 10)
            guard FileAvailability.isLocal(url) else { return Transfer(image: nil) }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return Transfer(image: nil) }
        return Transfer(image: NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        ))
    }
}
#endif
