#if os(macOS)
import CoreGraphics
import Foundation

/// A real PDF file with `pageCount` pages and a Names/Dests name tree —
/// hand-written bytes, because BOTH CGPDFContext destination APIs
/// (`addDestination`, `setDestination`) silently write nothing on macOS 26
/// (probed 2026-07-08; the name never reaches the file).
func makePDFWithDestinations(
    pageCount: Int,
    destinations: [(name: String, page: Int, point: CGPoint)]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NameTreeFixture-\(UUID().uuidString).pdf")

    let pageObjectNumber = { (page: Int) in 4 + page }
    let kids = (0..<pageCount).map { "\(pageObjectNumber($0)) 0 R" }.joined(separator: " ")
    // Name trees must be lexically sorted (PDF 32000 §7.9.6).
    let pairs = destinations.sorted { $0.name < $1.name }.map { dest in
        "(\(dest.name)) [\(pageObjectNumber(dest.page)) 0 R /XYZ \(Int(dest.point.x)) \(Int(dest.point.y)) 0]"
    }.joined(separator: " ")

    var bodies: [String] = []
    bodies.append("<< /Type /Catalog /Pages 2 0 R /Names << /Dests 3 0 R >> >>")
    bodies.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
    bodies.append("<< /Names [\(pairs)] >>")
    for _ in 0..<pageCount {
        bodies.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
    }

    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, body) in bodies.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
    }
    let xrefStart = pdf.utf8.count
    pdf += "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
    for offset in offsets {
        pdf += String(format: "%010d 00000 n \n", offset)
    }
    pdf += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"

    try Data(pdf.utf8).write(to: url)
    return url
}
#endif
