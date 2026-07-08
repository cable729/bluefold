#if os(macOS)
import CoreGraphics
import PDFKit

/// Resolves PDF named destinations (hyperref's `\hypertarget` / section /
/// theorem anchors) to a page + point.
///
/// PDFKit on macOS 26 has NO working public API for this: the private
/// `namedDestination:` selector exists but returns nil (probed 2026-07-08
/// against Axler). So this walks the public CGPDF catalog instead — the
/// Names/Dests name tree, with the old-style (PDF 1.1) catalog Dests
/// dictionary as fallback.
public enum NamedDestinations {
    public struct Target: Equatable, Sendable {
        public let pageIndex: Int
        /// XYZ/FitH destination coordinates when present. May be garbage in
        /// scans — callers navigate through the validated-point pipeline.
        public let point: CGPoint?
    }

    public static func resolve(_ name: String, in document: PDFDocument) -> Target? {
        guard
            !name.isEmpty,
            let cg = document.documentRef,
            let catalog = cg.catalog
        else { return nil }

        // Page dictionaries are the only stable page identity CGPDF gives
        // us; map their pointers to indices once per resolve (cheap even
        // for 1000-page scans).
        var pageIndexByDict: [UnsafeRawPointer: Int] = [:]
        for number in 1...max(cg.numberOfPages, 1) {
            if let page = cg.page(at: number), let dict = page.dictionary {
                pageIndexByDict[unsafeBitCast(dict, to: UnsafeRawPointer.self)] = number - 1
            }
        }

        var namesDict: CGPDFDictionaryRef?
        var destsTree: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict), let names = namesDict,
           CGPDFDictionaryGetDictionary(names, "Dests", &destsTree), let tree = destsTree,
           let hit = lookup(name, in: tree, pages: pageIndexByDict) {
            return hit
        }
        // Old-style catalog /Dests dictionary (rare, pre-PDF-1.2 writers).
        var legacy: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Dests", &legacy), let dests = legacy {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dests, name, &object), let obj = object {
                return target(from: obj, pages: pageIndexByDict)
            }
        }
        return nil
    }

    // MARK: - Name tree walk

    private static func lookup(
        _ name: String,
        in node: CGPDFDictionaryRef,
        pages: [UnsafeRawPointer: Int]
    ) -> Target? {
        var namesArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &namesArray), let array = namesArray {
            let count = CGPDFArrayGetCount(array)
            var index = 0
            while index + 1 < count {
                var stringRef: CGPDFStringRef?
                if CGPDFArrayGetString(array, index, &stringRef), let string = stringRef,
                   let text = CGPDFStringCopyTextString(string), (text as String) == name {
                    var object: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, index + 1, &object), let obj = object {
                        return target(from: obj, pages: pages)
                    }
                    return nil
                }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kidArray = kids {
            // Kids carry sorted Limits; a linear scan over a few dozen kids
            // is fine at our scale and immune to malformed Limits entries.
            for index in 0..<CGPDFArrayGetCount(kidArray) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kidArray, index, &kid), let dict = kid,
                   let hit = lookup(name, in: dict, pages: pages) {
                    return hit
                }
            }
        }
        return nil
    }

    // MARK: - Destination decoding

    /// Accepts both a bare destination array `[page /XYZ x y z]` and the
    /// dictionary wrapper `<< /D [...] >>`.
    private static func target(
        from object: CGPDFObjectRef,
        pages: [UnsafeRawPointer: Int]
    ) -> Target? {
        var arrayRef: CGPDFArrayRef?
        var dictRef: CGPDFDictionaryRef?
        var dest: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &arrayRef), let array = arrayRef {
            dest = array
        } else if CGPDFObjectGetValue(object, .dictionary, &dictRef), let dict = dictRef {
            var inner: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "D", &inner) { dest = inner }
        }
        guard let dest, CGPDFArrayGetCount(dest) >= 1 else { return nil }

        var pageDict: CGPDFDictionaryRef?
        guard
            CGPDFArrayGetDictionary(dest, 0, &pageDict), let page = pageDict,
            let pageIndex = pages[unsafeBitCast(page, to: UnsafeRawPointer.self)]
        else { return nil }

        var point: CGPoint?
        var kindName: UnsafePointer<Int8>?
        if CGPDFArrayGetCount(dest) >= 2, CGPDFArrayGetName(dest, 1, &kindName), let kind = kindName {
            var x: CGPDFReal = 0
            var y: CGPDFReal = 0
            switch String(cString: kind) {
            case "XYZ":
                let hasX = CGPDFArrayGetCount(dest) >= 3 && CGPDFArrayGetNumber(dest, 2, &x)
                let hasY = CGPDFArrayGetCount(dest) >= 4 && CGPDFArrayGetNumber(dest, 3, &y)
                if hasX || hasY { point = CGPoint(x: hasX ? x : 0, y: hasY ? y : 0) }
            case "FitH", "FitBH":
                if CGPDFArrayGetCount(dest) >= 3, CGPDFArrayGetNumber(dest, 2, &y) {
                    point = CGPoint(x: 0, y: y)
                }
            default:
                break  // Fit/FitB/FitV…: page-only jump.
            }
        }
        return Target(pageIndex: pageIndex, point: point)
    }
}
#endif
