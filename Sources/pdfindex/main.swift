// pdfindex: build and query a full-text index for a PDF from the command line.
//
// Usage: pdfindex <pdf-path> <query...>
//
// Indexes the PDF (keyed by content hash) into ~/Library/Caches/pdf-app/index.db,
// then prints matches within that PDF as `p.<page>: <snippet>`.

import Foundation
import SearchIndexKit

func fail(_ message: String, exitCode: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("pdfindex: " + message + "\n").utf8))
    exit(exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fail("usage: pdfindex <pdf-path> <query...>", exitCode: 2)
}

let pdfURL = URL(fileURLWithPath: arguments[0])
let query = arguments.dropFirst().joined(separator: " ")

do {
    let cachesDir = try FileManager.default
        .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("pdf-app", isDirectory: true)
    try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
    let store = try IndexStore(path: cachesDir.appendingPathComponent("index.db").path)

    let hash = try ContentHash.compute(for: pdfURL)
    let service = IndexingService(store: store)
    let result = try await service.indexDocument(at: pdfURL, contentHash: hash)

    switch result {
    case .alreadyIndexed:
        break
    case .indexed(let pages, let nonEmptyPages):
        FileHandle.standardError.write(
            Data("pdfindex: indexed \(nonEmptyPages)/\(pages) pages\n".utf8))
    case .notSearchable:
        fail("no extractable text in \(pdfURL.path) (scanned document?)")
    }

    // search spans the whole index; keep only hits from this document.
    let hits = try store.search(query, limit: 200)
        .filter { $0.contentHash == hash }
    for hit in hits.prefix(20) {
        print("p.\(hit.page): \(hit.snippet)")
    }
} catch {
    fail("\(error)")
}
