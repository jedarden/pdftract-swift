//
// Passthrough tests for `ExtractOptions` OCR flags (`ocrLanguage` /
// `ocrThreshold`), which README.md documents as the way to request OCR
// extraction (`ExtractOptions(ocrLanguage:ocrThreshold:)` fed to
// `client.extract(_:options:)`).
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as ExitCodeMappingTests.swift and
// ExtractStreamConformanceTests.swift. Keep it that way.
//
// What is pinned: the argv each `ExtractOptions` consumer hands to the
// spawned pdftract process. The tests drive an argv-capturing stub `pdftract`
// binary (same fake-binary pattern as ExitCodeMappingTests) that records its
// argv one-per-line into a file and exits 0 with a minimal valid payload, so
// the assertions see exactly what the child received — flag spelling
// (`--ocr-language`, `--ocr-threshold`), flag/value adjacency, position
// relative to the other arguments, and omission for a default-constructed
// `ExtractOptions()`. That is the README's promise to callers, and it is the
// test the codegen drift gate wants: a regenerated `Types.swift.tera` that
// renames either flag, drops it, or reorders it fails here loudly instead of
// silently changing what every caller's OCR request means. The exact-equality
// argv assertions are deliberately strict — when the approved binary-protocol
// repair (pdfswift-ccccb2ff) regenerates the SDK with a different argv shape,
// these tests are meant to force a conscious update, not to be loosened.
//
// All four `ExtractOptions.toArgs()` consumers are covered, because the
// serialization is inlined into each of them (Methods.swift appends
// `options.toArgs()` per method, so a template edit could fix one and miss
// another): the buffered `extract` path, `extractText` and `extractMarkdown`
// (which interleave `--text`/`--md --json` after the options), and the
// `extractStream` Task body, which re-runs the same append on its own path.
//
// No real pdftract binary is needed and none is consulted: the stub answers
// for it, so the whole suite runs in any environment, including the CI build
// gate's containers.
//
// Why there is no real-binary OCR round-trip here (the optional leg of
// pdfswift-006df0b5): one was attempted and is currently impossible against
// every released binary — the SDK's own argv shape (`extract --json <input>`)
// is rejected by the released CLI before any flag is evaluated, because the
// released CLI reads `--json` as a value-taking output path, leaving the
// required `<INPUT>` unsatisfied (exit 2). Reproduced 2026-11-24 against the
// pdftract v1.2.0 musl release asset (sha256 f86d7274…). That is the
// pdfswift-ccccb2ff protocol mismatch (human-approved 2026-10-03), not an OCR
// problem: the `--ocr-language` flag itself is recognized by the released CLI
// (it appears in the usage echo, and `extract <input> --ocr-language eng`
// exits 0 with "OCR languages: eng"). The `--ocr-threshold` flag is worse —
// the released CLI has no such flag at all (`error: unexpected argument
// '--ocr-threshold' found`, exit 2), so that leg cannot round-trip against a
// real binary even after the argv repair lands, and the templates/spec will
// have to be reconciled as part of the pdfswift-ccccb2ff follow-up. Once a
// binary that accepts the SDK's argv exists, a real-binary test belongs here:
// synthesize an image-only PDF (catalog/page/image-XObject/content stream, no
// /Filter needed — an 8x8 raw DeviceGray sample works; verified against the
// v1.2.0 asset: exit 0, one page, no text blocks, "OCR languages: eng" on
// stderr), call `extract` with `ExtractOptions(ocrLanguage: "eng")`, and
// assert extraction succeeds. Until then this suite stays stub-only and the
// gap is tracked on pdfswift-ccccb2ff, not silently skipped here.
//

import XCTest
@testable import Pdftract

final class ExtractOptionsOcrPassthroughTests: XCTestCase {
    // MARK: Argv-capturing stub

    /// Minimal `Document` JSON the buffered-path stub prints: an empty page
    /// list is enough for `extract`, `extractText`, and `extractMarkdown` to
    /// decode successfully — none of the tests assert decoded content, only
    /// the argv the child saw.
    private static let minimalDocumentJSON =
        #"{"schema_version":"1.0","pages":[],"metadata":{"page_count":0}}"#

    /// Minimal `Page` NDJSON line the streaming-path stub prints, so the
    /// drained stream yields exactly one page — proving the child ran to
    /// completion before the test reads the captured argv.
    private static let minimalPageNDJSON =
        #"{"page_index":0,"width":612,"height":792,"rotation":0,"spans":[],"blocks":[]}"#

    /// Writes an executable stub `pdftract` that records its argv one
    /// argument per line into `<directory>/captured-argv.txt`, prints
    /// `stdout` (a minimal valid payload for whichever SDK path will consume
    /// it), and exits 0. The capture path is baked into this stub instance,
    /// so concurrent tests never share capture state.
    private static func writeArgCapturingStub(
        stdout: String
    ) throws -> (directory: URL, binaryPath: String, capturePath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-ocr-passthrough-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let captureURL = directory.appendingPathComponent("captured-argv.txt")
        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > '\(captureURL.path)'\n"
        // Quoted delimiter: the payload must pass through untouched.
        script += "cat <<'PDFTRACT_STUB_EOF'\n\(stdout)\nPDFTRACT_STUB_EOF\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath, captureURL.path)
    }

    /// Reads back the argv the stub recorded. Arguments arrive one per line;
    /// every argument these tests produce is newline-free, so the line split
    /// is lossless.
    private static func capturedArguments(from capturePath: String) throws -> [String] {
        let raw = try String(contentsOfFile: capturePath, encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Drives one buffered-path call against the stub and returns the argv
    /// the child received.
    private func capturedBufferedArgv(
        stdout: String,
        _ call: (Pdftract) async throws -> Void
    ) async throws -> [String] {
        let stub = try Self.writeArgCapturingStub(stdout: stdout)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        try await call(Pdftract(binaryPath: stub.binaryPath))
        return try Self.capturedArguments(from: stub.capturePath)
    }

    // MARK: Buffered exec path

    /// The README "Extract with OCR" example verbatim (`ocrLanguage: "eng"`,
    /// `ocrThreshold: 0.7`) must reach the child as both flags, spelled as
    /// documented, each adjacent to its value — before the `--` separator
    /// that shields the caller-controlled source path from the flag parser
    /// (pdfswift-4e62b1ac).
    func testExtractSerializesBothOcrFlagsFromReadmeExample() async throws {
        let argv = try await capturedBufferedArgv(stdout: Self.minimalDocumentJSON) { client in
            _ = try await client.extract(
                .path("document.pdf"),
                options: ExtractOptions(ocrLanguage: "eng", ocrThreshold: 0.7)
            )
        }

        XCTAssertEqual(
            argv,
            ["extract", "--json", "--ocr-language", "eng", "--ocr-threshold", "0.7", "--", "document.pdf"],
            "extract() with the README OCR options sent \(argv) — expected --ocr-language and --ocr-threshold with their values before the -- separator, the source path after it"
        )
    }

    /// A default-constructed `ExtractOptions` — the shape of every call that
    /// does not opt into OCR — must omit both OCR flags entirely, leaving the
    /// non-OCR argv unchanged. This is the half of the contract that keeps
    /// the flags opt-in: a serialization that emitted `--ocr-language` with a
    /// placeholder (or an empty value) would flip OCR on for every caller.
    func testDefaultExtractOptionsOmitBothOcrFlags() async throws {
        let argv = try await capturedBufferedArgv(stdout: Self.minimalDocumentJSON) { client in
            _ = try await client.extract(.path("document.pdf"), options: ExtractOptions())
        }

        XCTAssertEqual(
            argv,
            ["extract", "--json", "--", "document.pdf"],
            "default ExtractOptions must omit both OCR flags; extract() sent \(argv)"
        )
        XCTAssertFalse(argv.contains("--ocr-language"), "default options leaked --ocr-language")
        XCTAssertFalse(argv.contains("--ocr-threshold"), "default options leaked --ocr-threshold")
    }

    /// Setting only the language must not smuggle in the threshold: each flag
    /// serializes independently, so callers asking for a language without a
    /// confidence floor get exactly that.
    func testOcrLanguageAloneSerializesOnlyOcrLanguage() async throws {
        let argv = try await capturedBufferedArgv(stdout: Self.minimalDocumentJSON) { client in
            _ = try await client.extract(
                .path("document.pdf"),
                options: ExtractOptions(ocrLanguage: "deu")
            )
        }

        XCTAssertEqual(
            argv,
            ["extract", "--json", "--ocr-language", "deu", "--", "document.pdf"],
            "ocrLanguage-only options sent \(argv) — expected only --ocr-language with its value"
        )
    }

    /// Setting only the threshold must not smuggle in the language, and the
    /// threshold must serialize as the caller's value (Swift's shortest
    /// round-trip Double description — `0.75`, not a padded decimal).
    func testOcrThresholdAloneSerializesOnlyOcrThreshold() async throws {
        let argv = try await capturedBufferedArgv(stdout: Self.minimalDocumentJSON) { client in
            _ = try await client.extract(
                .path("document.pdf"),
                options: ExtractOptions(ocrThreshold: 0.75)
            )
        }

        XCTAssertEqual(
            argv,
            ["extract", "--json", "--ocr-threshold", "0.75", "--", "document.pdf"],
            "ocrThreshold-only options sent \(argv) — expected only --ocr-threshold with the caller's value"
        )
    }

    // MARK: The other ExtractOptions consumers

    /// `extractText` and `extractMarkdown` interleave their own format flags
    /// (`--text` / `--md --json`) *after* the options on the same buffered
    /// exec path — the serialization is per-method, so each is pinned: OCR
    /// flags and format flags all before the `--` separator, the source path
    /// after it.
    func testExtractTextAndMarkdownCarryOcrFlags() async throws {
        let textArgv = try await capturedBufferedArgv(stdout: Self.minimalDocumentJSON) { client in
            _ = try await client.extractText(
                .path("document.pdf"),
                options: ExtractOptions(ocrLanguage: "eng", ocrThreshold: 0.7)
            )
        }
        XCTAssertEqual(
            textArgv,
            ["extract", "--ocr-language", "eng", "--ocr-threshold", "0.7", "--text", "--json", "--", "document.pdf"],
            "extractText() sent \(textArgv) — OCR flags and format flags belong before the -- separator, the source path after it"
        )

        let markdownArgv = try await capturedBufferedArgv(stdout: Self.minimalDocumentJSON) { client in
            _ = try await client.extractMarkdown(
                .path("document.pdf"),
                options: ExtractOptions(ocrLanguage: "eng", ocrThreshold: 0.7)
            )
        }
        XCTAssertEqual(
            markdownArgv,
            ["extract", "--ocr-language", "eng", "--ocr-threshold", "0.7", "--md", "--json", "--", "document.pdf"],
            "extractMarkdown() sent \(markdownArgv) — OCR flags and format flags belong before the -- separator, the source path after it"
        )
    }

    // MARK: Streaming path

    /// `extractStream` re-runs the options serialization inside its own Task
    /// body on a separate code path from the buffered methods; the OCR flags
    /// must land in the spawned argv there too. The stub emits one valid Page
    /// line, and the test asserts the page actually arrived — so the capture
    /// is read only after the child demonstrably ran to completion.
    func testExtractStreamCarriesOcrFlags() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalPageNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        var pages: [Page] = []
        for try await page in client.extractStream(
            .path("document.pdf"),
            options: ExtractOptions(ocrLanguage: "eng", ocrThreshold: 0.7)
        ) {
            pages.append(page)
        }

        XCTAssertEqual(pages.count, 1, "stub emitted one Page; the stream must consume it before argv is asserted")
        XCTAssertEqual(
            pages[0].pageIndex,
            0,
            "the streamed page must decode with the stub's page_index"
        )

        let argv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(
            argv,
            ["extract", "--ndjson", "--ocr-language", "eng", "--ocr-threshold", "0.7", "--", "document.pdf"],
            "extractStream() sent \(argv) — the streaming path must carry the OCR flags the buffered path carries, before the -- separator"
        )
    }
}
