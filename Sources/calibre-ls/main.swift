// calibre-ls: list the PDF books in a Calibre library from the command line.
//
// Usage: calibre-ls <library-root-path>
// Prints one line per book: `title — authors — [tags] — first pdf relative path`.

import CalibreKit
import Foundation

func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data("calibre-ls: \(message)\n".utf8))
    exit(exitCode)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: calibre-ls <library-root-path>", exitCode: 2)
}

do {
    let library = try CalibreLibrary(
        libraryRoot: URL(fileURLWithPath: arguments[1], isDirectory: true)
    )
    for book in try library.fetchBooks() {
        let authors = book.authors.joined(separator: ", ")
        let tags = book.calibreTags.joined(separator: ", ")
        let firstPDF = book.relativePDFPaths.first ?? "(no pdf)"
        print("\(book.title) — \(authors) — [\(tags)] — \(firstPDF)")
    }
} catch {
    fail("\(error)", exitCode: 1)
}
