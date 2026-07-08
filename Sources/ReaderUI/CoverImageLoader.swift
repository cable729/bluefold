#if os(macOS)
import AppKit
import ImageIO

/// Loads book-cover thumbnails without blocking the UI.
///
/// The naive approach — `NSImage(contentsOf:)` in a view body — decodes the
/// FULL-SIZE cover on the main thread on every scroll frame, and can stall
/// on iCloud-evicted files. This loader: skips non-local files, downsamples
/// straight from the image source (never decoding the full image), does the
/// work off the main thread, and caches the result.
enum CoverImageLoader {
    // NSCache is documented thread-safe.
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()
    private static let maxPixelSize = 320

    static func thumbnail(for url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if !FileAvailability.isLocal(url) {
            // Covers are small; pull evicted ones down (bounded wait) instead
            // of showing placeholders forever.
            try? await FileAvailability.ensureLocal(url, timeout: 10)
            guard FileAvailability.isLocal(url) else { return nil }
        }

        // The image is freshly created and uniquely referenced when it
        // crosses back — boxed explicitly so older Swift 6 compilers (CI)
        // accept the transfer, not just 6.3's region analysis.
        struct Transfer: @unchecked Sendable {
            let image: NSImage?
        }
        let image = await Task.detached(priority: .utility) { () -> Transfer in
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
        }.value.image

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }
}
#endif
