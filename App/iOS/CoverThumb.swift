import Foundation
import ImageIO
import ReaderUI
import UIKit

/// Loads book-cover thumbnails without blocking the UI — the iOS twin of
/// ReaderUI's macOS CoverImageLoader: skips straight to a downsampled decode
/// (never the full image), works off the main thread, caches, coalesces
/// concurrent requests, and pulls evicted iCloud covers down with a bounded
/// wait instead of showing placeholders forever.
enum CoverThumb {
    // NSCache is documented thread-safe.
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()
    private static let maxPixelSize = 320

    /// The image is freshly created and uniquely referenced when it crosses
    /// isolation — boxed explicitly so the transfer is legal under Swift 6.
    private struct Transfer: @unchecked Sendable {
        let image: UIImage?
    }

    /// In-flight loads keyed by path: every caller for the same cover awaits
    /// the one running decode instead of racing duplicates.
    @MainActor private static var inFlight: [String: Task<Transfer, Never>] = [:]

    @MainActor
    static func thumbnail(for url: URL) async -> UIImage? {
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
    /// off the main actor.
    private nonisolated static func load(_ url: URL) async -> Transfer {
        if !FileAvailability.isLocal(url) {
            // Covers are small; pull evicted ones down (bounded wait).
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
        return Transfer(image: UIImage(cgImage: cgImage))
    }
}
