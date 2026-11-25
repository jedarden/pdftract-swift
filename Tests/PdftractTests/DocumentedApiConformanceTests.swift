//
// Real-binary conformance pins for the README-documented APIs that had no
// test coverage anywhere: `extractText`, `extractMarkdown`, `hash`,
// `classify`, and the `.url` / `.bytes` `Source` cases (pdfswift-a53be3d4).
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as ExtractStreamConformanceTests.swift, whose shape this file
// mirrors (binary guard, in-code fixture synthesis, XCTSkip-not-fail).
//
// Why pins rather than the documented contracts: this repo's founding defect
// (proposal pdfswift-ccccb2ff) is a generated API that cannot drive the very
// binary the README points at. Probed 2026-11-24 against
// pdftract-v1.2.0-x86_64-unknown-linux-musl — the release the README's
// "Binary version compatibility" section links — with identical output for
// the argv pins on two other local builds:
//
//   extractText     `extract <input> --text --json` → exit 2, clap: "a value
//                   is required for '--text <PATH>'" — the CLI's --text takes
//                   an output PATH ('-' for stdout); the generator emits a
//                   valueless flag, so the child dies in argument parsing.
//   extractMarkdown `extract <input> --md --json`   → exit 2, same shape for
//                   '--md <PATH>'.
//   hash            `hash --json <input>`           → exit 2, clap:
//                   "unexpected argument '--json'" — the hash subcommand has
//                   no --json flag at all; it prints a bare
//                   `pdftract-v1:…` fingerprint line, not the Fingerprint
//                   JSON ({hash, page_count, fast_hash, metadata}) this SDK
//                   decodes — a second divergence layer behind the argv one.
//   classify        `classify --json <input>`        → exit 2, same clap
//                   message. Behind it, the release binary gates classify
//                   itself behind the 'profiles' feature (it exits 0 with an
//                   "Error: Classification requires the 'profiles' feature"
//                   line), so the SDK's Classification contract is doubly
//                   unreachable on the release binary.
//   .url            `Source.url` passes the URL string through as the
//                   extract positional INPUT, and the release binary then:
//                   rejects http(s) at its remote-feature gate (exit 2,
//                   "Remote sources require the 'remote' feature to be
//                   enabled") — the README's headline
//                   `client.extract(.url(https://…))` example is unreachable
//                   on the release binary; and rejects file:// with exit 1
//                   ("Failed to extract PDF: …"), which the README's error
//                   table does not list for URLs at all.
//   .bytes          the spill reaches the binary — a 2-page fixture yields
//                   exactly two NDJSON lines from a clean exit — but
//                   `extract --ndjson` emits one *block* per line
//                   ({bbox, block_index, kind, page, spans}), not the Page
//                   ({page_index, width, height, rotation, spans, blocks})
//                   this SDK decodes, so every line fails Page decoding and
//                   surfaces through `onSkippedLine` while the stream yields
//                   zero pages.
//
// Every assertion below pins the CURRENT binary-observable behavior, not the
// README's promise. That is deliberate and temporary: when the generator
// converges with the binary, regeneration changes the argv/decode behavior
// and these pins go red — each pin's comment names the documented contract
// it must then be flipped to, so the red is the to-do, not a regression. A
// suite that kept passing unchanged across that regeneration would be the
// failure mode; a green suite here can never be read as "the README contract
// holds against a real binary" — for that, see the flip notes per test.
//
// Everything is gated on a real pdftract on PATH (XCTSkip — the
// pdfswift-8f868708 guard convention shared with ConformanceTests and
// ExtractStreamConformanceTests), so bare `swift test` and both CI gates
// stay green wherever no binary is installed. The compatible binary is the
// release the README names: pdftract v1.2.0. Two local lineage builds
// examined the same day cannot extract anything at all ("Error: Failed to
// extract PDF", exit 1, for every input including the committed probe
// fixture), so the source-case pins assert only what the release binary is
// known to do.
//

import XCTest
@testable import Pdftract

final class DocumentedApiConformanceTests: XCTestCase {
    /// Marker text drawn on each fixture page. No pin asserts decoded page
    /// content — nothing decodes yet — but the fixtures are real multi-page
    /// PDFs, and the NDJSON line count the `.bytes` pin observes is one line
    /// per page precisely because each synthesized page carries exactly one
    /// text block.
    private static let markerPrefix = "DIVCONF page"

    // MARK: Binary guard

    /// Resolves the pdftract binary the same way the client's PATH scan does,
    /// or throws XCTSkip. Mirrors `Pdftract`'s resolution (`isExecutableFile`,
    /// not `fileExists`) so "skip" and "spawn" can never disagree about
    /// whether a binary is available.
    private static func requireBinary() throws -> String {
        #if os(Linux)
        let entries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        #else
        let entries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ";")
            .map(String.init)
        #endif
        for entry in entries {
            let candidate = NSString.path(withComponents: [entry, "pdftract"])
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw XCTSkip("pdftract binary not found on PATH; the documented-API conformance pins need a real binary")
    }

    // MARK: Fixture synthesis

    /// Writes a minimal valid PDF with one page per `pageTexts` entry, each
    /// page drawing its text in a single Helvetica run. Returns the file URL.
    /// Same object layout as ExtractStreamConformanceTests.makePDF (catalog,
    /// page tree, page + content pair per page, shared font last,
    /// consecutively numbered, xref subsection spanning every object).
    private static func makePDF(pageTexts: [String]) throws -> URL {
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
            .appendingPathComponent("pdftract-documented-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    // MARK: Drain helper

    /// Consumes `stream` to completion, returning the pages in arrival order
    /// (or rethrowing the stream's terminal error — the "the child must not
    /// have failed" assertion for the pins that expect a clean exit).
    private static func drain(_ stream: AsyncThrowingStream<Page, Error>) async throws -> [Page] {
        var pages: [Page] = []
        for try await page in stream {
            pages.append(page)
        }
        return pages
    }

    /// Thread-safe collector for `onSkippedLine`. The callback runs on the
    /// stream's producer Task while the consuming test awaits the loop, so a
    /// plain array would be a data race.
    private final class SkippedLineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Error] = []

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(error)
        }

        /// Every recorded error as a `DecodingError`? The stream surfaces
        /// exactly the JSONDecoder failure for each undecodable line.
        var allAreDecodingErrors: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage.allSatisfy { $0 is DecodingError }
        }
    }

    // MARK: The argv divergence pins — extractText / extractMarkdown / hash / classify

    /// PIN, not contract. README "Extract text" promises
    /// `client.extractText(.path("document.pdf"))` returns the extracted
    /// text. Against the release binary the generated argv
    /// (`extract <input> --text --json`) dies in clap: the CLI's `--text`
    /// takes an output PATH, so the valueless flag is a usage error (exit 2,
    /// mapped to `CorruptPdfError`). When the generator emits
    /// `--text -` (or an equivalent the binary accepts), this pin reds —
    /// flip it to assert the returned text contains the fixture's marker.
    func testExtractTextPinsTheCurrentArgvDivergence() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await client.extractText(.path(fixture.path))
            XCTFail("extractText returned — the argv divergence pin is stale; assert the documented text contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap usage error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("a value is required for '--text <PATH>'"),
                "expected the '--text <PATH>' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    /// PIN, not contract. README "Extract Markdown" promises
    /// `client.extractMarkdown(.path("document.pdf"))` returns Markdown. Same
    /// divergence shape as extractText with `--md <PATH>`. When the generator
    /// is fixed, flip to asserting the returned Markdown contains the
    /// fixture's marker (the binary's real `--md -` output page-anchors each
    /// page and separates pages with a horizontal rule).
    func testExtractMarkdownPinsTheCurrentArgvDivergence() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await client.extractMarkdown(.path(fixture.path))
            XCTFail("extractMarkdown returned — the argv divergence pin is stale; assert the documented Markdown contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap usage error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("a value is required for '--md <PATH>'"),
                "expected the '--md <PATH>' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    /// PIN, not contract. README "Hash fingerprint" promises a `Fingerprint`
    /// with 64-hex-char `hash` (SHA-256) and `fastHash` (BLAKE3). Two
    /// divergences deep: the generated argv (`hash --json <input>`) dies in
    /// clap — the hash subcommand has no `--json` — and even the binary's
    /// real output for `hash <input>` is a bare `pdftract-v1:…` fingerprint
    /// line, not the `{hash, page_count, fast_hash, metadata}` JSON the SDK
    /// decodes, so the second divergence survives any argv-only fix. When
    /// regeneration converges both, flip to asserting the hash/fastHash
    /// shape (64 hex chars each) the way the template-owned ConformanceTests
    /// already sketches.
    func testHashPinsTheCurrentArgvDivergence() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await client.hash(.path(fixture.path))
            XCTFail("hash returned — the divergence pin is stale; assert the documented Fingerprint contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap usage error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("unexpected argument '--json' found"),
                "expected the unexpected-'--json' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    /// PIN, not contract. README "Classify document" promises a
    /// `Classification` with a non-empty `category` and a `confidence` in
    /// [0, 1]. Three divergences deep: the generated argv
    /// (`classify --json <input>`) dies in clap — classify has no `--json`
    /// (its default output is already JSON, `--pretty` just indents it);
    /// behind that, the release binary gates classify itself behind the
    /// 'profiles' feature (exits 0 with an error line), so the documented
    /// contract is unreachable on the release binary even at the CLI level.
    /// When regeneration converges the argv and a profiles-enabled binary is
    /// the target, flip to asserting category non-empty and confidence in
    /// [0, 1] the way the template-owned ConformanceTests already sketches.
    func testClassifyPinsTheCurrentArgvDivergence() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await client.classify(.path(fixture.path))
            XCTFail("classify returned — the divergence pin is stale; assert the documented Classification contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap usage error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("unexpected argument '--json' found"),
                "expected the unexpected-'--json' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    // MARK: The Source-case pins — .url

    /// PIN for `.url` passthrough. The SDK hands a `Source.url`'s absolute
    /// string to the binary as its positional INPUT (the URL is the CLI's to
    /// fetch — README "Extract from URL"). The release binary does not
    /// support file:// URLs and reports exit 1 ("Failed to extract PDF"),
    /// which also proves the child genuinely ran on the URL string — a URL
    /// the SDK had mangled into a local path would fail elsewhere, and a
    /// `.url` case the SDK dropped would leave no child failure at all. (On
    /// the v1.2.0 musl release the message echoes the URL verbatim, but two
    /// local builds truncate it, so only the exit and the message stem are
    /// pinned here.) When the SDK gains a working URL story, flip to real
    /// fetch assertions against a served fixture.
    func testFileUrlSourceReachesTheBinaryAsItsInputString() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            // extractStream is the vehicle because it is the one method whose
            // argv shape the release binary accepts at all (`extract --ndjson
            // <input>`); the buffered extract dies in clap before any URL
            // handling, so it could not isolate the .url passthrough.
            _ = try await Self.drain(
                client.extractStream(.url(URL(fileURLWithPath: fixture.path)))
            )
            XCTFail("file:// URL streamed — the pin is stale; assert a real fetch contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 1,
                "expected the binary's file:// failure (exit 1), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("Failed to extract PDF"),
                "expected the binary's extraction-failure message, got: \(error.message.prefix(200))"
            )
        }
    }

    /// PIN for the README's headline `.url` example. `client.extract(.url(
    /// URL(string: "https://…")))` is the first documented usage, and the
    /// release binary refuses every http(s) input at its remote-feature gate
    /// (exit 2, "Remote sources require the 'remote' feature to be enabled")
    /// — before any network is touched, so the URL here points at a refused
    /// port and the pin stays network-free. Exit 2 maps to
    /// `CorruptPdfError`, so the README's error table (which lists exit 2 as
    /// "The PDF file is corrupt or invalid") misdescribes this failure too.
    /// When a remote-enabled binary becomes the target, flip to real
    /// fetch assertions.
    func testHttpsUrlSourceHitsTheBinaryRemoteFeatureGate() async throws {
        let binary = try Self.requireBinary()

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await Self.drain(
                client.extractStream(
                    .url(URL(string: "https://127.0.0.1:9/divconf.example/doc.pdf")!)
                )
            )
            XCTFail("https:// URL streamed — the pin is stale; a remote-enabled binary is installed, assert a real fetch contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the binary's remote-feature gate (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("Remote sources require the 'remote' feature"),
                "expected the remote-feature gate message, got: \(error.message.prefix(200))"
            )
        }
    }

    // MARK: The Source-case pins — .bytes

    /// PIN for `.bytes` end to end. README "Extract from in-memory Data"
    /// promises every `Source`-taking method accepts in-memory bytes with no
    /// manual cleanup. This pin proves the full path against the release
    /// binary: the SDK spills the caller's `Data` to its temp file, the child
    /// reads THAT file (two pages in, two NDJSON lines out, exit 0 — bytes
    /// that never reached the binary could not produce them), and the SDK
    /// surfaces every line through `onSkippedLine` because the binary's
    /// `--ndjson` emits one *block* per line ({bbox, block_index, kind,
    /// page, spans}), which cannot decode into this SDK's `Page`
    /// ({page_index, width, height, rotation, …}). The count is exactly the
    /// fixture's page count because each synthesized page carries exactly
    /// one block. The spill's deletion is pinned by
    /// SourceBytesPassthroughTests against a stub; this pin is the real-child
    /// half the stub cannot vouch for. When the binary's NDJSON converges to
    /// Page lines, the skipped count drops to zero and this reds — flip to
    /// asserting the decoded pages' markers.
    func testBytesSourceDrivesTheRealBinaryButEveryLineFailsPageDecode() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 2
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let data = try Data(contentsOf: fixture)
        let collector = SkippedLineCollector()
        let client = Pdftract(binaryPath: binary)

        // A throw here would mean the child failed (exit != 0) — the pinned
        // reality is a clean child exit with undecodable lines, not an error.
        let pages = try await Self.drain(
            client.extractStream(.bytes(data), onSkippedLine: { collector.record($0) })
        )

        XCTAssertEqual(
            collector.count, pageCount,
            "expected one undecodable NDJSON line per fixture page (one block each), got \(collector.count)"
        )
        XCTAssertTrue(
            collector.allAreDecodingErrors,
            "onSkippedLine must surface the JSONDecoder failure for each block-shaped line"
        )
        XCTAssertEqual(
            pages.count, 0,
            "block-shaped NDJSON lines must not decode into Pages; got \(pages.count)"
        )
    }
}
