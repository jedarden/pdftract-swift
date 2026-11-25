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
// These tests were written as the documented contract against a real binary:
//   1. pages arrive in document order,
//   2. pageIndex is 0-based and increments by one per page,
//   3. each streamed page's blocks equal the same page's blocks from
//      `extract()` for the same input,
//   4. a trivial zero-page PDF yields an empty stream.
//
// Reality (first real-binary run, 2026-11-25, bead pdfswift-3307a377, via
// scripts/e2e-binary-verification.sh against
// pdftract-v1.2.0-x86_64-unknown-linux-musl): the release binary's
// `extract --ndjson` emits one *block* per line ({bbox, block_index, kind,
// page, spans}), none of which decode into this SDK's `Page` (which requires
// page_index/width/height/rotation) — so against that binary the stream
// yields ZERO pages, every line surfacing through `onSkippedLine`, while the
// buffered `extract()` dies in clap before producing anything to compare
// against (`--json` is a valueless flag to the generator, an output-PATH
// option to the CLI). Assertions 1–3 have therefore never passed against any
// real binary — they skipped in every gate until the e2e script existed.
// Tests 1–3 are reality pins now, the convention
// DocumentedApiConformanceTests established: each asserts the binary's
// CURRENT behavior and its comment names the documented contract (the
// original assertion, kept verbatim) to flip back to when the generator
// converges with the binary (proposal pdfswift-ccccb2ff). Test 4 could not
// hold either: the release binary REFUSES a zero-page PDF outright (exit 1,
// "Document contains no pages" — never a stream, never an empty one), so it
// is a pin too. A green
// run here must never be read as "the README contract holds against a real
// binary" — for that, see the flip notes per test.
//
// Every assertion needs pdftract's real NDJSON output — no stub can vouch for
// a page's contents — so each test throws XCTSkip when no pdftract binary can
// be resolved on PATH: the guard pdfswift-8f868708 prescribes for
// binary-dependent tests. Without the binary the suite skips cleanly and bare
// `swift test` stays green. Both CI gates skip this suite too: the build gate
// filters it out (--filter 'StreamingStderrRegressionTests|ExitCodeMappingTests'),
// and although the publish gate's --filter ConformanceTests regex matches this
// class name, that workflow provisions no pdftract binary, so the guard fires
// there as well. Running these for real is what scripts/e2e-binary-verification.sh
// does: it installs the pinned release and runs the full suite with it on
// PATH, refusing a run in which anything skipped — the standing way to
// exercise this suite against a real binary.
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

    /// Thread-safe collector for `onSkippedLine`. The callback runs on the
    /// stream's producer Task while the consuming test awaits the loop, so a
    /// plain array would be a data race (the same shape as
    /// DocumentedApiConformanceTests.SkippedLineCollector).
    private final class SkippedLineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Error] = []

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(error)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }

        /// Every recorded error as a `DecodingError`? The stream surfaces
        /// exactly the JSONDecoder failure for each undecodable line.
        var allAreDecodingErrors: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage.allSatisfy { $0 is DecodingError }
        }
    }

    // MARK: The stream-output pins — block-per-line divergence (see header)

    /// PIN, not contract. The README presents `extractStream` as yielding
    /// pages in document order (stream position `i` carries page `i`'s
    /// marker text) with a zero-based, incrementing `pageIndex` — the two
    /// documented assertions this test replaced (the former
    /// testPagesArriveInDocumentOrder and
    /// testPageIndexIsZeroBasedAndIncrementing, which drove the identical
    /// path and so pinned the identical reality). Against the release
    /// binary the stream never yields a page at all: `extract --ndjson`
    /// emits one *block* per line ({bbox, block_index, kind, page, spans}),
    /// none of which decode into this SDK's `Page`, so every line surfaces
    /// through `onSkippedLine` as the JSONDecoder failure while the drain
    /// completes cleanly with zero pages. The skipped count is exactly the
    /// fixture's page count because each synthesized page carries exactly
    /// one text block — a truncation or partial read would under-count, and
    /// a line that DID decode would mean the binary's NDJSON converged.
    /// When the binary's `--ndjson` emits `Page`-shaped lines, this reds —
    /// flip it back to the two documented assertions it replaced: pages
    /// arrive in document order (stream position `i` carries
    /// `"\(markerPrefix) \(i)"` in its blocks) and
    /// `pages.map(\.pageIndex) == Array(0..<pageCount)`.
    func testStreamYieldsZeroPagesPinningTheBlockLineDivergence() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 3
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let collector = SkippedLineCollector()
        let client = Pdftract(binaryPath: binary)

        // A throw here would mean the child failed — the pinned reality is
        // a clean child exit whose lines are all undecodable, not an error.
        let pages = try await Self.drain(
            client.extractStream(.path(fixture.path), onSkippedLine: { collector.record($0) })
        )

        XCTAssertEqual(
            pages.count, 0,
            "block-shaped NDJSON lines must not decode into Pages; the stream yielded \(pages.count) — the block-line pin is stale, restore the documented order/pageIndex assertions"
        )
        XCTAssertEqual(
            collector.count, pageCount,
            "expected one undecodable NDJSON line per fixture page (one block each), got \(collector.count)"
        )
        XCTAssertTrue(
            collector.allAreDecodingErrors,
            "onSkippedLine must surface the JSONDecoder failure for each block-shaped line"
        )
    }

    /// PIN, not contract. The README promises the two paths agree on the
    /// content they hand the caller — each streamed page's blocks equal the
    /// same page's blocks from `extract()` for the same input (the former
    /// testStreamedPageBlocksMatchExtract compared them through their JSON
    /// encoding: `Block` is Codable but not Equatable, and encoding is
    /// deterministic for these key-order-stable structs). Against the
    /// release binary that agreement is unreachable at BOTH layers on the
    /// same input, which is what this pin holds:
    ///
    /// - the stream yields zero pages — every `--ndjson` line is
    ///   block-shaped and fails `Page` decode (the pin above), so there is
    ///   nothing on the streamed side to compare;
    /// - the buffered `extract()` dies in clap before producing anything to
    ///   compare against: the generator passes `--json` as a valueless flag
    ///   while the CLI's `--json <PATH>` takes an output path (`-` for
    ///   stdout), so the child exits 2 with "a value is required for
    ///   '--json <PATH>'" — mapped to `CorruptPdfError`.
    ///
    /// When both layers converge, flip back to the documented assertion:
    /// streamed count equals `buffered.pages.count`, per-page `pageIndex`
    /// equality, and JSON-encoded block equality per stream position.
    func testStreamAndExtractDisagreeAtBothLayersPinningTheBufferedArgvDivergence() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 3
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)

        // Stream side: clean drain, zero decodable pages (the block-line
        // divergence; asserted here so this pin fails independently of the
        // other one if either half moves).
        let collector = SkippedLineCollector()
        let streamed = try await Self.drain(
            client.extractStream(.path(fixture.path), onSkippedLine: { collector.record($0) })
        )
        XCTAssertEqual(
            streamed.count, 0,
            "streamed pages arrived — the stream-side half of the pin is stale"
        )
        XCTAssertEqual(collector.count, pageCount)

        // Buffered side: the child dies in argument parsing.
        do {
            _ = try await client.extract(.path(fixture.path))
            XCTFail("extract returned — the buffered argv half of the pin is stale; restore the documented stream/extract blocks-equality assertions")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap usage error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("a value is required for '--json <PATH>'"),
                "expected the '--json <PATH>' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    /// PIN, not contract. The README's zero-page contract — a trivial
    /// zero-page PDF yields a zero-page stream, not an error and not a
    /// phantom page — is unreachable on the release binary at the fixture
    /// level: the binary REFUSES a zero-page document outright (both
    /// extract forms, buffered and `--ndjson`), exiting 1 with
    /// "Failed to extract PDF: <path> / Caused by: Document contains no
    /// pages" before any line is written. The SDK maps that exit to the
    /// base `PdftractError` (exit 1 is in no named-error row), carrying
    /// the child's stderr — which is what this pin holds, probed
    /// 2026-11-25 (pdfswift-3307a377). When a binary accepts zero-page
    /// documents, this reds — flip it back to the documented assertion:
    /// drain completes cleanly with `pages.count == 0`.
    func testZeroPagePdfPinsTheBinaryDocumentContainsNoPagesRefusal() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: [])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await Self.drain(client.extractStream(.path(fixture.path)))
            XCTFail("zero-page PDF streamed — the refusal pin is stale; assert the documented zero-page stream instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 1,
                "expected the binary's zero-page refusal (exit 1), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("Document contains no pages"),
                "expected the 'Document contains no pages' cause, got: \(error.message.prefix(200))"
            )
        }
    }
}
