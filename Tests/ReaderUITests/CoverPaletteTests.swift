#if os(macOS)
import AppKit
import Testing

@testable import ReaderUI

/// Dominant-color extraction for tab gradients (round 22): covers yield
/// their real colors; text pages yield nothing (hash-tint fallback).
@Suite("Cover palette extraction")
@MainActor
struct CoverPaletteTests {
    /// Renders solid vertical bands into a CGImage.
    private func bandedImage(_ bands: [NSColor]) -> CGImage {
        let width = 120, height = 160
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let bandHeight = height / bands.count
        for (index, color) in bands.enumerated() {
            context.setFillColor(color.usingColorSpace(.sRGB)!.cgColor)
            context.fill(CGRect(
                x: 0, y: index * bandHeight, width: width, height: bandHeight
            ))
        }
        return context.makeImage()!
    }

    @Test func twoToneCoverYieldsBothColors() {
        // Axler-style: a yellow cover with a blue band.
        let image = bandedImage([
            NSColor(srgbRed: 0.95, green: 0.8, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.8, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.25, blue: 0.7, alpha: 1),
        ])
        let colors = CoverPalette.dominantColors(in: image)
        #expect(colors.count == 2)
        let first = colors[0].usingColorSpace(.sRGB)!
        #expect(first.redComponent > 0.7 && first.blueComponent < 0.4,
                "the larger yellow area dominates")
        let second = colors[1].usingColorSpace(.sRGB)!
        #expect(second.blueComponent > 0.5 && second.redComponent < 0.4)
    }

    @Test func nearIdenticalShadesCollapseToOne() {
        let image = bandedImage([
            NSColor(srgbRed: 0.8, green: 0.2, blue: 0.15, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.24, blue: 0.18, alpha: 1),
        ])
        #expect(CoverPalette.dominantColors(in: image).count == 1,
                "close reds merge instead of making a fake gradient")
    }

    @Test func whiteTextPageYieldsNothing() {
        // A text page: white with a whisper of black "ink" — too little
        // art to trust; the caller keeps its hash tint.
        let image = bandedImage([
            .white, .white, .white, .white, .white, .white, .white,
            NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        ])
        #expect(CoverPalette.dominantColors(in: image).isEmpty)
    }

    @Test func capsAtThreeColors() {
        let image = bandedImage([
            NSColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.7, blue: 0.2, alpha: 1),
            NSColor(srgbRed: 0.15, green: 0.3, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.9, green: 0.75, blue: 0.1, alpha: 1),
        ])
        #expect(CoverPalette.dominantColors(in: image).count == 3)
    }
}
#endif
