//
// Real-binary conformance pins for the README-documented APIs that had no
// test coverage anywhere: `extractText`, `extractMarkdown`, `hash`,
// `classify`, `search`, and the `.url` / `.bytes` `Source` cases
// (pdfswift-a53be3d4; search folded in by pdfswift-41c46c80), joined by
// `getMetadata` and the end-to-end `verifyReceipt` pair on 2026-11-25
// (pdfswift-3307a377) — the last two operations that had no real-binary
// coverage, plus the decode-layer "serialization twins" that feed REAL
// binary stdout into the SDK's decoders for the types whose argv layer is
// dead.
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
//   search          `grep <pattern> <input>`       → exit 2, clap:
//                   "unrecognized subcommand 'grep'" — no available binary
//                   (the v1.2.0 musl release or either local lineage build)
//                   has a grep subcommand at all, so search cannot produce
//                   a single match anywhere. The child dies before the
//                   source argument is examined, which is what makes this a
//                   pure argv-layer pin.
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
// Three tests here are deliberately NOT gated that way:
// testSearchYieldsMatchesWithDocumentedPageAndContextFields pins search's
// documented decode contract against an in-code fake `grep` child, because
// no real binary can play that role yet (the subcommand does not exist —
// the search pin above); testClassifyDecodesTheDocumentedTaxonomyAndConfidenceRange
// does the same for classify against a fake that answers with the documented
// Classification JSON (the release binary gates classify behind the
// 'profiles' feature — the classify pin above — so a gate would skip it
// everywhere, forever); and testReadmeClassifySectionMatchesTheDocumentedShape
// pins this README's Classify section (taxonomy table + confidence range)
// against the same documented constant, needing no child at all. Gating the
// decode pair would skip them everywhere, forever: the contract they pin is
// the SDK's own decode behavior, which a fake child exercises as well as a
// converged binary ever will — and they are the flip targets the argv pins'
// comments name.
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

    /// Writes an executable fake `pdftract` that records its argv one
    /// argument per line into `<directory>/captured-argv.txt`, prints
    /// `stdoutLines`, and exits 0 — SourceBytesPassthroughTests' capture
    /// convention, without the spill copy (the input here is the test's own
    /// fixture file, which the SDK never deletes). The decode-side tests use
    /// it: the child stands in for a binary emitting the documented output —
    /// `grep`'s Match NDJSON lines for search, classify's JSON object for
    /// classify — roles no real binary can play yet. Like
    /// StreamingStderrRegressionTests' fakes it ignores its arguments'
    /// content — the argv capture, not the child's behavior, is what proves
    /// which invocation it stood in for.
    private static func writeArgCapturingFake(
        stdoutLines: [String],
        directoryPrefix: String
    ) throws -> (directory: URL, binaryPath: String, capturePath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directoryPrefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capturePath = directory.appendingPathComponent("captured-argv.txt").path
        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > '\(capturePath)'\n"
        for line in stdoutLines {
            script += "echo '\(line)'\n"
        }
        script += "exit 0\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath, capturePath)
    }

    /// Reads back the fake child's captured argv. Arguments arrive one per
    /// line; every argument these tests produce is newline-free, so the
    /// line split is lossless (SourceBytesPassthroughTests' parser verbatim).
    private static func capturedArguments(from capturePath: String) throws -> [String] {
        let raw = try String(contentsOfFile: capturePath, encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: Drain helper

    /// Consumes `stream` to completion, returning the yielded values in
    /// arrival order (or rethrowing the stream's terminal error — the "the
    /// child must not have failed" assertion for the pins that expect a
    /// clean exit). Generic over the element type so it serves both stream
    /// flavors this file drives: `Page` (extractStream) and `Match` (search).
    private static func drain<T>(_ stream: PdftractStream<T>) async throws -> [T] {
        var values: [T] = []
        for try await value in stream {
            values.append(value)
        }
        return values
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

    /// PIN, not contract. README "Classify document" documents a
    /// `Classification` whose `category` is one of the ten fixed
    /// document-type strings and whose `confidence` is a `Double` in
    /// [0, 1] (both pinned decode-side by
    /// testClassifyDecodesTheDocumentedTaxonomyAndConfidenceRange below).
    /// Three divergences deep: the generated argv
    /// (`classify --json <input>`) dies in clap — classify has no `--json`
    /// (its default output is already JSON, `--pretty` just indents it);
    /// behind that, the release binary gates classify itself behind the
    /// 'profiles' feature (exits 0 with an error line), so the documented
    /// contract is unreachable on the release binary even at the CLI level.
    /// When regeneration converges the argv and a profiles-enabled binary is
    /// the target, flip to asserting the live category against the
    /// documented taxonomy and the live confidence against [0, 1] —
    /// testClassifyDecodesTheDocumentedTaxonomyAndConfidenceRange is the
    /// shape that flip must keep holding.
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

    // MARK: The documented classify shape — taxonomy and confidence range
    // (pdfswift-d38d8233; decode-side, no binary gate — see the file header)

    /// The documented `Classification.category` vocabulary (README "Classify
    /// document"): the ten fixed document-type strings the classifier emits,
    /// upstream from `ProfileType` (pdftract
    /// crates/pdftract-core/src/profiles/types.rs) via the CLI's
    /// `profile_type_to_string` (crates/pdftract-cli/src/classify.rs).
    /// `category` is a plain `String` on the SDK side — no Swift enum — so
    /// this constant is the whole machine-readable form of that
    /// documentation; the README test below pins the README's taxonomy
    /// table against it, and the decode test round-trips every member.
    private static let documentedClassifyCategories = [
        "invoice", "receipt", "contract", "scientific_paper", "slide_deck",
        "form", "bank_statement", "legal_filing", "book_chapter", "unknown",
    ]

    /// `<repo root>`, derived from this file's location
    /// (`<root>/Tests/PdftractTests/DocumentedApiConformanceTests.swift`) —
    /// VersionStampConsistencyTests' derivation verbatim — so the README
    /// test reads the checked-out tree it was compiled from and works in
    /// any checkout path, including `git archive` extractions.
    private var repoRoot: String {
        let filePath = #filePath
        let fileDir = (filePath as NSString).deletingLastPathComponent
        let testsDir = (fileDir as NSString).deletingLastPathComponent
        return (testsDir as NSString).deletingLastPathComponent
    }

    /// Pins this repo's README Classify section against
    /// `documentedClassifyCategories` and the documented confidence range.
    /// Deliberately NOT gated on a binary and needing no child at all: it
    /// reads `README.md` relative to `#filePath` (the
    /// VersionStampConsistencyTests convention), so it runs — and fails
    /// loudly — in every environment `swift test` runs in, including
    /// binary-less CI containers. What it pins:
    ///
    /// - the Classify section's taxonomy table enumerates exactly the ten
    ///   documented categories (set equality — a renamed, added, dropped,
    ///   or typoed category fails here, forcing the change through
    ///   `documentedClassifyCategories` and the decode test below
    ///   consciously);
    /// - the section states the confidence scale as the closed-range
    ///   literal `0.0...1.0` (a rewording that drops or rescales it —
    ///   0–100 percentages, an open range — fails here rather than
    ///   silently un-documenting it).
    ///
    /// This is the doc-side twin of
    /// testClassifyDecodesTheDocumentedTaxonomyAndConfidenceRange: together
    /// they keep the README and the decode pin on one taxonomy.
    func testReadmeClassifySectionMatchesTheDocumentedShape() throws {
        let readme = try String(
            contentsOfFile: repoRoot + "/README.md",
            encoding: .utf8
        )
        guard let sectionStart = readme.range(of: "### Classify document") else {
            XCTFail("README.md has no '### Classify document' section — the classify documentation is gone")
            return
        }
        let afterStart = sectionStart.upperBound..<readme.endIndex
        let sectionEnd = readme
            .range(of: "\n### ", options: .literal, range: afterStart)?
            .lowerBound ?? readme.endIndex
        let section = String(readme[sectionStart.lowerBound..<sectionEnd])

        // Parse the taxonomy table body: rows after the `|---|---|`
        // separator whose first cell is a backticked value. The header row
        // (`| `category` | Document type |`) sits before the separator and
        // so never parses as a category.
        var documented: Set<String> = []
        var pastSeparator = false
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|"), trimmed.contains("-"), !trimmed.contains("`") {
                pastSeparator = true
                continue
            }
            guard pastSeparator, trimmed.hasPrefix("| `") else { continue }
            let value = trimmed.dropFirst(3).prefix(while: { $0 != "`" })
            documented.insert(String(value))
        }

        XCTAssertEqual(
            documented, Set(Self.documentedClassifyCategories),
            "README Classify taxonomy table must enumerate exactly the ten documented categories — update documentedClassifyCategories and the decode test together with the README"
        )

        XCTAssertTrue(
            section.contains("0.0...1.0"),
            "README Classify section must state the confidence scale as the closed range 0.0...1.0"
        )
    }

    /// The documented classify contract, pinned on the decode side against
    /// a fixture PDF. Deliberately NOT gated on a real binary (see the file
    /// header): the release binary gates classify behind the 'profiles'
    /// feature — on top of the argv divergence the pin above documents — so
    /// a gate would skip it everywhere, forever. A fake child answers with
    /// the documented wire shape — one `Classification` JSON object with
    /// `category` drawn from the documented taxonomy, `confidence` inside
    /// the documented `0.0...1.0` range — and this test asserts what the
    /// README promises the SDK yields:
    ///
    /// - every documented category string survives the decode intact (a
    ///   decode-side rename or mangling fails the per-category equality);
    /// - `confidence` round-trips and lands inside the closed documented
    ///   range, with both boundary values (0.0, 1.0) decoding exactly;
    /// - the captured argv proves the fixture PDF itself was the classified
    ///   input: the `classify` subcommand with the fixture path last. The
    ///   flags in between are deliberately NOT pinned here — that is
    ///   testClassifyPinsTheCurrentArgvDivergence's job, and the whole
    ///   point of that pin is that the current flag set is wrong.
    ///
    /// This is the flip target for
    /// testClassifyPinsTheCurrentArgvDivergence: when a profiles-enabled,
    /// argv-converged binary is the target, these decode assertions must
    /// keep holding against its live output. One honesty note: the wire
    /// field names this fake emits (`category`, `tags`, `heuristics`) are
    /// the SDK type's own — the upstream CLI's classify JSON names its
    /// fields `document_type`, `reasons`, `runner_up`, `runner_up_confidence`
    /// (crates/pdftract-cli/src/classify.rs ClassificationOutput), a
    /// divergence layer owned by pdfswift-ccccb2ff; this test pins the
    /// SDK's documented decode contract, not any binary's wire format.
    func testClassifyDecodesTheDocumentedTaxonomyAndConfidenceRange() async throws {
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        // Every documented category, decoded from the documented wire shape
        // at a mid-range confidence. The payload is ASCII with no single
        // quotes, so it can sit inside the fake's single-quoted echo as-is.
        for category in Self.documentedClassifyCategories {
            let fake = try Self.writeArgCapturingFake(
                stdoutLines: ["{\"category\":\"\(category)\",\"confidence\":0.87,"
                    + "\"tags\":[\"billing\"],\"heuristics\":{\"has_table\":true}}"],
                directoryPrefix: "pdftract-classify-contract"
            )
            defer { try? FileManager.default.removeItem(at: fake.directory) }

            let client = Pdftract(binaryPath: fake.binaryPath)
            let classification = try await client.classify(.path(fixture.path))

            XCTAssertEqual(
                classification.category, category,
                "category must survive the decode intact (\(category))"
            )
            XCTAssertTrue(
                Self.documentedClassifyCategories.contains(classification.category),
                "decoded category must be a documented taxonomy member, got \(classification.category)"
            )
            XCTAssertEqual(
                classification.confidence, 0.87, accuracy: 1e-12,
                "confidence must round-trip the decoded value"
            )
            XCTAssertGreaterThanOrEqual(
                classification.confidence, 0.0,
                "decoded confidence must sit inside the documented 0.0...1.0 range"
            )
            XCTAssertLessThanOrEqual(
                classification.confidence, 1.0,
                "decoded confidence must sit inside the documented 0.0...1.0 range"
            )
            XCTAssertEqual(
                classification.tags, ["billing"],
                "tags must decode alongside the documented fields"
            )
            XCTAssertEqual(
                classification.heuristics, ["has_table": true],
                "heuristics must decode alongside the documented fields"
            )

            let argv = try Self.capturedArguments(from: fake.capturePath)
            XCTAssertEqual(
                argv.first, "classify",
                "classify() must invoke the classify subcommand"
            )
            XCTAssertEqual(
                argv.last, fixture.path,
                "classify() must pass the fixture path as the classified input"
            )
        }

        // The documented range's boundaries decode exactly — the range is
        // closed. (The SDK does not enforce the range at decode time — a
        // fake emitting 1.5 decodes fine; the range is the classifier's
        // documented output contract, validated upstream, not a decode
        // invariant.)
        for boundary in [0.0, 1.0] {
            let fake = try Self.writeArgCapturingFake(
                stdoutLines: ["{\"category\":\"invoice\",\"confidence\":\(boundary),"
                    + "\"tags\":[],\"heuristics\":{}}"],
                directoryPrefix: "pdftract-classify-contract-boundary"
            )
            defer { try? FileManager.default.removeItem(at: fake.directory) }

            let client = Pdftract(binaryPath: fake.binaryPath)
            let classification = try await client.classify(.path(fixture.path))
            XCTAssertEqual(classification.confidence, boundary, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(classification.confidence, 0.0)
            XCTAssertLessThanOrEqual(classification.confidence, 1.0)
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

    // MARK: The search pins — grep-subcommand divergence + the documented decode contract

    /// PIN, not contract. README "Search" promises
    /// `client.search(.path("document.pdf"), "invoice")` yields a `Match`
    /// per hit with a zero-based `page` (the pdfswift-1a2fa6e0 convention)
    /// and `context.before`/`.after` carrying the surrounding text. No
    /// available binary can run search at all: the generated argv's
    /// subcommand, `grep`, does not exist in any of them — the v1.2.0 musl
    /// release (the README-linked release) and both local lineage builds
    /// die in clap with "unrecognized subcommand 'grep'" (exit 2, mapped to
    /// `CorruptPdfError` — another exit the README's error table does not
    /// list this way). The child dies before the source argument is even
    /// examined, which is what makes this a pure argv-layer pin: no PDF
    /// behavior of any binary is involved. When a binary with a compatible
    /// `grep` lands, this reds — flip it to asserting the yielded matches
    /// against that binary's live output, keeping the decode-side shape
    /// testSearchYieldsMatchesWithDocumentedPageAndContextFields pins.
    func testSearchPinsTheCurrentGrepSubcommandDivergence() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await Self.drain(
                client.search(.path(fixture.path), Self.markerPrefix)
            )
            XCTFail("search returned matches — the grep-subcommand pin is stale; a compatible grep exists, assert the documented Match contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap 'unrecognized subcommand' error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("unrecognized subcommand 'grep'"),
                "expected the unrecognized-'grep' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    /// The documented search contract, pinned on the decode side against a
    /// fixture PDF. Deliberately NOT gated on a real binary (see the file
    /// header): no available binary has a `grep` subcommand, so a gate would
    /// skip this everywhere, forever. A fake child answers with the
    /// documented wire shape — one Match NDJSON line per fixture page, page
    /// indices drawn from the fixture's own page range, surrounding text
    /// unique per page — and this test asserts what the README promises the
    /// SDK yields:
    ///
    /// - matches are found: one per fixture page, carrying the searched
    ///   pattern as `text` (the `\(match.text)` of the README example);
    /// - `page` stays zero-based exactly as pdfswift-1a2fa6e0 documented
    ///   (the fixture's own indices [0, 1, 2] — a decode-side `+1`, i.e.
    ///   1-based pages, turns them into [1, 2, 3] and fails here);
    /// - `context.before`/`.after` arrive in their own fields with their
    ///   text intact — the `...\(before)[\(text)]\(after)...` shape the
    ///   README example prints; swapped, trimmed, or dropped context fails
    ///   the exact per-page equality.
    ///
    /// The captured argv proves the fixture PDF itself was the searched
    /// input: `grep <pattern> <fixture path>` (pattern before source, as
    /// SourceBytesPassthroughTests pins for `.bytes`; this is the `.path`
    /// twin). This is the flip target for
    /// testSearchPinsTheCurrentGrepSubcommandDivergence: when a real binary
    /// gains a compatible `grep`, these decode assertions must keep holding
    /// against its live output.
    func testSearchYieldsMatchesWithDocumentedPageAndContextFields() async throws {
        let pageCount = 3
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        // One match per fixture page. The context strings are unique per
        // page, so a before/after swap cannot pass; the page indices are the
        // fixture's own zero-based range, so a decode-side shift cannot.
        // All lines are ASCII with no shell metacharacters, so they can sit
        // inside the fake's single-quoted echo as-is.
        let matchLines = (0..<pageCount).map { index in
            "{\"text\":\"\(Self.markerPrefix)\",\"page\":\(index),"
                + "\"bbox\":[72.0,720.0,120.0,732.0],"
                + "\"context\":{\"before\":\"preamble \(index) before \","
                + "\"after\":\" after \(index) trailing\"}}"
        }
        let fake = try Self.writeArgCapturingFake(
            stdoutLines: matchLines,
            directoryPrefix: "pdftract-search-contract"
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let matches = try await Self.drain(
            client.search(.path(fixture.path), Self.markerPrefix)
        )

        XCTAssertEqual(
            matches.count, pageCount,
            "expected one match per fixture page, got \(matches.count)"
        )
        XCTAssertEqual(
            matches.map(\.text), Array(repeating: Self.markerPrefix, count: pageCount),
            "every match must carry the searched pattern as its text"
        )
        XCTAssertEqual(
            matches.map(\.page), Array(0..<pageCount),
            "Match.page must stay zero-based — the fixture's own page range — as documented (README: same convention as Page.pageIndex; display match.page + 1)"
        )
        for (index, match) in matches.enumerated() {
            XCTAssertEqual(
                match.context.before, "preamble \(index) before ",
                "context.before must carry the text before the match, intact (match \(index))"
            )
            XCTAssertEqual(
                match.context.after, " after \(index) trailing",
                "context.after must carry the text after the match, intact (match \(index))"
            )
        }

        let argv = try Self.capturedArguments(from: fake.capturePath)
        XCTAssertEqual(
            argv, ["grep", "--", Self.markerPrefix, fixture.path],
            "search() must invoke grep with the pattern after the -- separator, before the fixture path (pdfswift-4e62b1ac)"
        )
    }

    // MARK: The serialization twins — real stdout JSON into the SDK types
    // (pdfswift-3307a377)

    /// A helper-level failure inside the probes below (bad fixture shape,
    /// unexpected child exit). Throwing it fails the test with the message
    /// attached, the same way an assertion would.
    private struct ProbeFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        init(_ message: String) { self.message = message }
    }

    /// Runs the resolved binary with `arguments` verbatim, returning stdout,
    /// stderr, and the child's exit status. This is how the tests below feed
    /// REAL binary output into the SDK's decoders: the generated methods
    /// cannot reach these outputs (that divergence is what the argv pins
    /// hold), so this helper separates the two layers those pins
    /// distinguish — argv reachability and wire-schema compatibility. Stderr
    /// is read after exit; the outputs these probes collect (a 2-page
    /// fixture's JSON) sit far below any pipe buffer limit.
    private static func runBinary(
        _ binary: String,
        arguments: [String]
    ) throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        return (out, err, process.terminationStatus)
    }

    /// Produces a real receipt for `fixture` exactly the way the `Receipt`
    /// type's documentation describes: `extract --receipts lite` embeds a
    /// receipt object (pdf_fingerprint, page_index, bbox, content_hash,
    /// extraction_version) on every span and block, and this saves the first
    /// span's receipt to its own JSON file — the artifact `Receipt.data`
    /// hands to `verify-receipt` as its `RECEIPT.json` positional. Returns
    /// that path plus the pdf_fingerprint the receipt carries, so a pin can
    /// confront the extractor's fingerprint with the verifier's recomputed
    /// one. The caller owns the returned file's directory (a temp dir to
    /// remove).
    private static func produceReceipt(
        binary: String,
        fixture: URL
    ) throws -> (receiptPath: String, receiptDir: URL, pdfFingerprint: String) {
        let run = try runBinary(binary, arguments: [
            "extract", "--receipts", "lite", "--json", "-", "--", fixture.path,
        ])
        guard run.exitCode == 0 else {
            throw ProbeFailure(
                "extract --receipts lite exited \(run.exitCode): \(String(decoding: run.stderr, as: UTF8.self).prefix(200))"
            )
        }
        guard let doc = try JSONSerialization.jsonObject(with: run.stdout) as? [String: Any],
              let pages = doc["pages"] as? [[String: Any]],
              let spans = pages.first?["spans"] as? [[String: Any]],
              let receipt = spans.first?["receipt"] as? [String: Any],
              let fingerprint = receipt["pdf_fingerprint"] as? String else {
            throw ProbeFailure("extract --receipts lite stdout carried no span receipt — the fixture or flag regressed")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receiptURL = directory.appendingPathComponent("receipt.json")
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted])
            .write(to: receiptURL)
        return (receiptURL.path, directory, fingerprint)
    }

    /// PIN, not contract. README "Get metadata" promises
    /// `client.getMetadata(.path("document.pdf"))` returns the document's
    /// metadata. Against the release binary the generated argv dies in
    /// clap: the CLI's extract has no `--metadata-only` flag at all (its
    /// option surface is the output-format PATHs, page ranges, receipts,
    /// cache and include toggles), so the child exits 2 with the
    /// unexpected-argument usage error before the fixture is even opened.
    /// The decode layer itself is compatible — the binary's real
    /// `metadata` object decodes into this SDK's `Metadata` (the twin
    /// below) — but no generated argv reaches it. When the generator
    /// converges, this reds — flip it to asserting
    /// `metadata.pageCount == <fixture page count>` the way the twin
    /// already does decode-side.
    func testGetMetadataPinsTheCurrentArgvDivergence() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await client.getMetadata(.path(fixture.path))
            XCTFail("getMetadata returned — the argv divergence pin is stale; assert the documented Metadata contract instead")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode, 2,
                "expected the child's clap usage error (exit 2), got exit \(error.exitCode)"
            )
            XCTAssertTrue(
                error.message.contains("unexpected argument '--metadata-only' found"),
                "expected the unexpected-'--metadata-only' usage error, got: \(error.message.prefix(200))"
            )
        }
    }

    /// The serialization twin for `Metadata`: the release binary's REAL
    /// `extract --json -` stdout, its `metadata` member fed to the SDK's
    /// `Metadata` decoder. The argv layer is dead (the pin above) — this
    /// test exists to show the wire schema itself is not: the binary's
    /// metadata object carries `page_count` (the one non-optional key
    /// `Metadata` requires) and the synthesized decoder ignores the
    /// binary's extra members (block_count, span_count, cache_status,
    /// cache_age_seconds, reading_order_algorithm), so the decode layer
    /// would work the moment a converged argv reaches it. Driven through
    /// `runBinary` with the correct argv (`--json -`), not through the SDK.
    func testBinaryMetadataObjectDecodesIntoTheSdkMetadataType() async throws {
        let binary = try Self.requireBinary()
        let pageCount = 2
        let fixture = try Self.makePDF(
            pageTexts: (0..<pageCount).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let run = try Self.runBinary(
            binary, arguments: ["extract", "--json", "-", "--", fixture.path]
        )
        XCTAssertEqual(run.exitCode, 0, "extract --json - must exit cleanly on the fixture")

        guard let doc = try JSONSerialization.jsonObject(with: run.stdout) as? [String: Any],
              let metadataObject = doc["metadata"] else {
            throw ProbeFailure("extract --json - stdout carried no metadata member")
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadataObject)
        let metadata = try JSONDecoder().decode(Metadata.self, from: metadataData)

        XCTAssertEqual(
            metadata.pageCount, pageCount,
            "Metadata.pageCount must decode the binary's real page_count"
        )
        // The fixture carries no document-info dictionary, so every
        // optional metadata key decodes to nil — the absence tolerance the
        // SDK type guarantees the wire.
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.author)
        XCTAssertNil(metadata.producer)
    }

    /// PIN for the buffered extraction's wire schema: the release binary's
    /// real `extract --json -` stdout cannot decode into the SDK's
    /// `Document` — but the failure fires one layer deeper than the 2026-11-24
    /// probe expected. The binary's top level DOES carry `schema_version`
    /// ("1.0", sorted after `pages` in its pretty-printed output — easy to
    /// miss in a truncated sample), so `Document.schemaVersion` and
    /// `Document.metadata` (whose `page_count` the binary supplies) decode
    /// fine; the first keyNotFound is `page_index` inside `pages[0]` — the
    /// binary's pages carry `index` instead, and `width`/`height`/
    /// `rotation` are absent entirely, so the page WRAPPER is the whole
    /// drift. Probed against the real decode 2026-11-25 (pdfswift-3307a377):
    /// this pin holds the executable form of that fact. When the binary's
    /// pages carry the SDK's wrapper keys, this reds — flip to asserting
    /// the decoded document's page count and per-page marker text.
    func testBufferedDocumentDecodePinsThePageWrapperSchemaDrift() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(
            pageTexts: (0..<2).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let run = try Self.runBinary(
            binary, arguments: ["extract", "--json", "-", "--", fixture.path]
        )
        XCTAssertEqual(run.exitCode, 0, "extract --json - must exit cleanly on the fixture")

        // The pin's premise, held executable: schema_version is present and
        // decodes — the drift is NOT at the document level.
        guard let doc = try JSONSerialization.jsonObject(with: run.stdout) as? [String: Any],
              (doc["schema_version"] as? String)?.hasPrefix("1") == true else {
            throw ProbeFailure("extract --json - stdout lost its schema_version member — the pin's premise changed")
        }

        do {
            _ = try JSONDecoder().decode(Document.self, from: run.stdout)
            XCTFail("Document decoded — the page-wrapper drift pin is stale; assert the decoded document's pages instead")
        } catch let error as DecodingError {
            guard case .keyNotFound(let key, _) = error else {
                XCTFail("expected keyNotFound, got \(error)")
                return
            }
            XCTAssertEqual(
                key.stringValue, "page_index",
                "the first missing key must be page_index — the binary's pages carry `index`, with no width/height/rotation"
            )
        } catch {
            XCTFail("expected a DecodingError, got \(error)")
        }
    }

    /// The leaf-type serialization twin: the binary's real buffered JSON
    /// `pages[0]` members decode into the SDK's `[Block]` and `[Span]`
    /// arrays. The page wrapper does not (the schema pin above) — but the
    /// leaves do, because the SDK's leaf fields (kind/text/bbox for
    /// `Block`; text/bbox/font/size with optional confidence for `Span`)
    /// are a strict subset of the binary's members and the synthesized
    /// decoders ignore the extras (block-level spans array, span-level
    /// color, rendering_mode, confidence_source). This compatibility is
    /// what any argv fix would immediately expose — pinned here so a leaf
    /// regression cannot hide behind the page-level failure.
    func testBufferedLeafTypesDecodeFromTheRealJson() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(pageTexts: ["\(Self.markerPrefix) 0"])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let run = try Self.runBinary(
            binary, arguments: ["extract", "--json", "-", "--", fixture.path]
        )
        XCTAssertEqual(run.exitCode, 0, "extract --json - must exit cleanly on the fixture")

        guard let doc = try JSONSerialization.jsonObject(with: run.stdout) as? [String: Any],
              let pages = doc["pages"] as? [[String: Any]],
              let firstPage = pages.first,
              let blockObjects = firstPage["blocks"] as? [Any],
              let spanObjects = firstPage["spans"] as? [Any] else {
            throw ProbeFailure("extract --json - stdout carried no pages[0] blocks/spans")
        }

        let blocks = try JSONDecoder().decode(
            [Block].self,
            from: try JSONSerialization.data(withJSONObject: blockObjects)
        )
        XCTAssertEqual(blocks.count, 1, "the fixture's single text block must decode")
        XCTAssertEqual(blocks.first?.kind, "paragraph")
        XCTAssertEqual(blocks.first?.text, "\(Self.markerPrefix) 0")
        XCTAssertEqual(blocks.first?.bbox.count, 4)
        XCTAssertNil(blocks.first?.level, "the binary emits no level for paragraph blocks; the SDK's optional must decode to nil")

        let spans = try JSONDecoder().decode(
            [Span].self,
            from: try JSONSerialization.data(withJSONObject: spanObjects)
        )
        XCTAssertEqual(spans.count, 1, "the fixture's single span must decode")
        XCTAssertEqual(spans.first?.text, "\(Self.markerPrefix) 0")
        XCTAssertEqual(spans.first?.bbox.count, 4)
        XCTAssertEqual(spans.first?.size ?? 0, 12.0, accuracy: 0.001)
        XCTAssertEqual(spans.first?.confidence ?? -1, 1.0, accuracy: 0.0001)
    }

    /// The full SDK→binary→SDK path, exercised for real: `verify-receipt`
    /// is the one subcommand whose CLI contract the generated argv already
    /// matches (boolean `--json`, `<FILE.pdf> <RECEIPT.json>` positionals —
    /// the divergence inventory's lone argv-conforming method), so
    /// `client.verifyReceipt` genuinely drives the release binary end to
    /// end — SDK argv, real child, real receipt. The receipt is real too,
    /// produced by the same binary from the same fixture via
    /// `extract --receipts lite` (the `Receipt` docs' recipe). The pin:
    /// verification still fails, because the binary's verifier recomputes a
    /// DIFFERENT pdf fingerprint from the same file than `extract` embeds
    /// in receipts (stable on both sides across runs;
    /// v1.2.0-binary-divergence-inventory.md documents extract/hash vs
    /// verify-receipt producing three values) — so every receipt dies at
    /// check 1 with exit 10, which the SDK maps to `ReceiptVerifyError`
    /// carrying the child's (empty) stderr as its message. When the
    /// binary's verifier converges with the extractor's fingerprint, this
    /// reds — flip to asserting `result.valid == true` on the same receipt,
    /// with the decode twin below keeping the wire schema honest.
    func testVerifyReceiptDrivesTheReleaseBinaryEndToEndAndPinsTheFingerprintGate() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(
            pageTexts: (0..<2).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let receipt = try Self.produceReceipt(binary: binary, fixture: fixture)
        defer { try? FileManager.default.removeItem(at: receipt.receiptDir) }

        let client = Pdftract(binaryPath: binary)
        do {
            _ = try await client.verifyReceipt(
                fixture.path, receipt: Receipt(data: receipt.receiptPath)
            )
            XCTFail("verifyReceipt returned — the fingerprint-gate pin is stale; assert result.valid == true instead")
        } catch let error as ReceiptVerifyError {
            XCTAssertEqual(
                error.exitCode, 10,
                "expected the binary's fingerprint_mismatch exit (10), got exit \(error.exitCode)"
            )
        } catch {
            XCTFail("expected ReceiptVerifyError (exit 10), got \(type(of: error)): \(error)")
        }
    }

    /// The verifyReceipt serialization twin: the release binary's REAL
    /// `verify-receipt --json` stdout — spawned with the exact argv the SDK
    /// builds — decodes into `ReceiptVerificationResult` with every
    /// documented field populated: `status` in the CLI's failure vocabulary
    /// ("fingerprint_mismatch" — check 1, per the end-to-end pin above),
    /// `best_iou` at 0 (no span was ever compared), the
    /// expected/actual content-hash pair, and `error` carrying the CLI's
    /// explanation — so `valid` is false and `reason` non-nil, the shape
    /// the struct's docs describe for decodes outside `verifyReceipt`
    /// (which throws instead). The recomputed fingerprint in the decode is
    /// asserted DIFFERENT from the receipt's — the executable form of the
    /// divergence that makes the check fail. This is the only operation
    /// whose real wire output this SDK decodes today: the schema-level
    /// proof that the SDK surface is sound wherever the wire agrees.
    func testVerifyReceiptJsonDecodesIntoReceiptVerificationResult() async throws {
        let binary = try Self.requireBinary()
        let fixture = try Self.makePDF(
            pageTexts: (0..<2).map { "\(Self.markerPrefix) \($0)" }
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let receipt = try Self.produceReceipt(binary: binary, fixture: fixture)
        defer { try? FileManager.default.removeItem(at: receipt.receiptDir) }

        let run = try Self.runBinary(
            binary,
            arguments: ["verify-receipt", "--json", "--", fixture.path, receipt.receiptPath]
        )
        XCTAssertEqual(
            run.exitCode, 10,
            "expected the fingerprint_mismatch exit (10); stderr: \(String(decoding: run.stderr, as: UTF8.self).prefix(200))"
        )

        let result = try JSONDecoder().decode(
            ReceiptVerificationResult.self, from: run.stdout
        )
        XCTAssertEqual(result.status, "fingerprint_mismatch")
        XCTAssertFalse(result.valid, "status fingerprint_mismatch must not decode as valid")
        XCTAssertEqual(result.bestIou, 0.0, accuracy: 1e-12)
        XCTAssertNotNil(result.reason, "the failure explanation must decode from the CLI's error field")
        XCTAssertEqual(
            result.expectedContentHash, receipt.pdfFingerprint,
            "the receipt-side fingerprint must decode as the expected hash"
        )
        XCTAssertNotEqual(
            result.actualContentHash, result.expectedContentHash,
            "the verifier's recomputed fingerprint must differ from the receipt's — the divergence the check fails on"
        )
    }
}
