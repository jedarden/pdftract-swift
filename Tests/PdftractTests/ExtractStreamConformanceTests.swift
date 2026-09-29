//
// Functional conformance tests for `extractStream`'s documented output.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as ExitCodeMappingTests.swift. Keep it that way: the
// template-owned ConformanceTests.swift cannot carry repo-local additions,
// because editing it here would be overwritten by the next regeneration.
//
// The README presents `extractStream` as the primary path for large PDFs and
// shows `page.pageIndex` and `page.blocks` as the yielded shape. The other
// stream suites pin lifecycle behavior — stderr draining
// (StreamingStderrRegressionTests) and exit-code mapping
// (ExitCodeMappingTests) — but nothing asserted the *functional* output.
// These tests pin the documented contract against a real binary:
//   1. pages arrive in document order,
//   2. pageIndex is 0-based and increments by one per page,
//   3. each streamed page's blocks equal the same page's blocks from
//      `extract()` for the same input,
//   4. a trivial zero-page PDF yields an empty stream.
//
// Every assertion needs pdftract's real NDJSON output — no stub can vouch for
// a page's contents — so each test throws XCTSkip when no pdftract binary can
// be resolved on PATH: the guard pdfswift-8f868708 prescribes for
// binary-dependent tests. Without the binary the suite skips cleanly and bare
// `swift test` stays green. Both CI gates skip this suite too: the build gate
// filters it out (--filter 'StreamingStderrRegressionTests|ExitCodeMappingTests'),
// and although the publish gate's --filter ConformanceTests regex matches this
// class name, that workflow provisions no pdftract binary, so the guard fires
// there as well. Running these for real needs a binary on PATH locally —
// e.g. docker run swift:5.10-jammy over a clean extraction, with a pdftract
// binary on PATH — the same standing as the other binary-gated suites.
//
// Fixtures are synthesized in-code: minimal, structurally valid PDFs (catalog,
// page tree, one Helvetica text run per page, one shared font) written to the
// temp directory, so the repo carries no binary fixtures and each test states
// the page count it needs. Objects are numbered consecutively and the xref
// subsection spans every object, so even a strict parser resolves all of them.
//

import XCTest
@testable import Pdftract

final class ExtractStreamConformanceTests: XCTestCase {
    /// Marker text drawn on each fixture page. Page `i` shows
    /// `"\(markerPrefix) \(i)"`, letting the order test prove that arrival
    /// order follows the document's page tree rather than merely that
    /// pageIndex counts monotonically.
    private static let markerPrefix = "STREAMCONF page"

    // MARK: Binary guard

    /// Resolves the pdftract binary the same way the client's PATH scan does,
    /// or throws XCTSkip. Mirrors `Pdftract`'s resolution (isExecutableFile,
    /// not fileExists) so "skip" and "spawn" can never disagree about whether
    /// a binary is available.
    private static func requireBinary() throws -> String {
        let entries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in entries {
            let candidate = NSString.path(withComponents: [entry, "pdftract"])
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw XCTSkip("pdftract binary not found on PATH; extractStream conformance needs a real binary")
    }

    // MARK: Fixture synthesis

    /// Writes a minimal valid PDF with one page per `pageTexts` entry, each
    /// page drawing its text in a single Helvetica run. Returns the file URL.
    private static func makePDF(pageTexts: [String]) throws -> URL {
        // Object layout: 1 catalog, 2 page tree, then a page object and a
        // content object per page in pair order, then the shared font last —
        // consecutive numbering keeps the xref subsection total covering.
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        let kids = (0..<pageTexts.count).map { "\($0 * 2 + 3) 0 R" }
            .joined(separator: " ")
        objects[2] = "<< /Type /Pages /Count \(pageTexts.count) /Kids [\(kids)] >>"
        let fontNumber = pageTexts.count * 2 + 3
        for (index, text) in pageTexts.enumerated() {
            let pageNumber = index * 2 + 3
            let contentNumber = pageNumber + 1
            objects[pageNumber] =
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 \(fontNumber) 0 R >> >> "
                + "/Contents \(contentNumber) 0 R >>"
            // The markers are plain ASCII with no parens or escapes, so they
            // can sit inside a literal PDF string as-is.
            let stream = "BT /F1 12 Tf 72 720 Td (\(text)) Tj ET"
            objects[contentNumber] =
                "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        }
        objects[fontNumber] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

        var pdf = "%PDF-1.4\n"
        var offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = pdf.utf8.count
            pdf += "\(number) 0 obj\n\(objects[number]!)\nendobj\n"
        }
        let xrefPosition = pdf.utf8.count
        let size = fontNumber + 1
        pdf += "xref\n0 \(size)\n"
        pdf += "0000000000 65535 f \n"
        for number in 1..<size {
            pdf += String(format: "%010d 00000 n \n", offsets[number]!)
        }
        pdf += "trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xrefPosition)\n%%EOF\n"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-stream-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    // MARK: Drain helper

    /// Consumes `stream` to completion, returning the pages in arrival order
    /// (or rethrowing the stream's terminal error).
    private static func drain(_ stream: AsyncThrowingStream<Page, Error>) async throws -> [Page] {
        var pages: [Page] = []
        for try await page in stream {
            pages.append(page)
        }
        return pages
    }

    // MARK: The documented contract

    /// Streamed pages arrive in document order: page `i` of the stream carries
    /// page `i`'s marker text, so arrival follows the document's page tree
    /// rather than merely an increasing counter.
    func testPagesArriveInDocumentOrder() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 4
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        let pages = try await Self.drain(client.extractStream(.path(fixture.path)))

        XCTAssertEqual(pages.count, pageCount, "expected one streamed page per fixture page")
        for (index, page) in pages.enumerated() {
            let blockText = page.blocks.map { $0.text }.joined(separator: " ")
            XCTAssertTrue(
                blockText.contains("\(Self.markerPrefix) \(index)"),
                "stream position \(index) carried blocks for a different page: \(blockText)"
            )
        }
    }

    /// pageIndex follows the documented 0-based convention: it starts at 0 and
    /// increments by exactly one per page, with no gaps or repeats.
    func testPageIndexIsZeroBasedAndIncrementing() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 3
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        let pages = try await Self.drain(client.extractStream(.path(fixture.path)))

        XCTAssertEqual(pages.count, pageCount)
        XCTAssertEqual(
            pages.map { $0.pageIndex },
            Array(0..<pageCount),
            "pageIndex must start at 0 and increment by one per page"
        )
    }

    /// Each streamed page's blocks are the same blocks `extract()` returns for
    /// the same input, page for page — the README's two paths must agree on
    /// the content they hand the caller. Blocks are compared through their
    /// JSON encoding: `Block` is Codable but not Equatable, and encoding is
    /// deterministic for these key-order-stable structs.
    func testStreamedPageBlocksMatchExtract() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 3
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        let streamed = try await Self.drain(client.extractStream(.path(fixture.path)))
        let buffered = try await client.extract(.path(fixture.path))

        XCTAssertEqual(streamed.count, buffered.pages.count,
                       "stream and extract disagree on page count for the same input")
        for (index, page) in streamed.enumerated() {
            let bufferedPage = buffered.pages[index]
            XCTAssertEqual(page.pageIndex, bufferedPage.pageIndex,
                           "stream position \(index) disagrees with extract on pageIndex")
            XCTAssertEqual(
                try JSONEncoder().encode(page.blocks),
                try JSONEncoder().encode(bufferedPage.blocks),
                "stream position \(index)'s blocks differ from extract()'s page \(index) blocks"
            )
        }
    }

    /// A trivial zero-page PDF yields a zero-page stream — not an error and
    /// not a phantom page.
    func testTrivialEmptyPdfYieldsZeroPages() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: [])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        let pages = try await Self.drain(client.extractStream(.path(fixture.path)))

        // `Page` is Codable but not Equatable, so assert on the count rather
        // than comparing arrays.
        XCTAssertEqual(pages.count, 0, "an empty PDF must stream zero pages")
    }
}
