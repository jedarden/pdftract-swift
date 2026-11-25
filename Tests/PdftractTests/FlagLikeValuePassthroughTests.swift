//
// Regression tests for the flag-like-value contract (pdfswift-4e62b1ac):
// every caller-controlled value the SDK hands to the pdftract CLI — a
// `Source` path, the `search` pattern, and the two `verifyReceipt` paths —
// reaches the CLI as a positional value *after* the `--` end-of-options
// separator, with all SDK-controlled flags before it. Before this contract
// the values sat before or among the flags, so the CLI's parser claimed any
// leading-dash value: against a real pdftract build,
//
//   pdftract extract --json -report.pdf   → "unexpected argument '-r' found"
//   pdftract grep -js doc.pdf             → '-j'+'s', i.e. --threads with
//                                           value "s" (usage error)
//   pdftract grep -i doc.pdf              → pattern silently becomes the
//                                           case-insensitivity flag; "doc.pdf"
//                                           becomes the pattern
//
// so a file literally named `-report.pdf` was unreferencable and ordinary
// search queries (a negative number, an option-looking word) misbehaved.
// The README documents the contract in "Flag-like paths and patterns"; the
// generator (templates/sdk-skeleton/swift/Methods.swift.tera) emits the
// separator in all six argv-construction sites, and `sdk-contract.md`
// requires the same shape of every SDK.
//
// The separator is emitted UNCONDITIONALLY — not only when a value happens
// to start with `-` — so the spawn shape is value-independent and pinned
// here exactly, per the suite convention: a regeneration that drops the
// separator, reorders the flags, or restores the old source-before-options
// layout fails loudly instead of silently reintroducing the misparse.
// Rejecting leading-dash values instead was explicitly rejected as the
// contract (a negative-number search query is an ordinary input; a path the
// caller can open() must be extractable) — recorded on the bead and in
// sdk-contract.md.
//
// CLI-side reality (the stub cannot prove): `--` plus a flag-like value is
// accepted by the pdftract CLI itself — verified 2026-11-25 against a dev
// build with `--features pdftract-cli/grep` (grep is compiled out of every
// binary shipped to this box): `grep --json -- -js <real fixture>` matches
// end-to-end, `extract --json -- -report.pdf` parses and reaches
// extraction, `verify-receipt --json -- <pdf> <receipt>` parses and reaches
// receipt reading. Evidence in the pdfswift-4e62b1ac bead notes.
//
// Hand-written, not generated: this file is not a codegen template output,
// so `pdftract sdk codegen` leaves it alone — the same standing as
// SourceBytesPassthroughTests.swift. Keep it that way.
//
// No real pdftract binary is needed and none is consulted: the stub answers
// for it, so the whole suite runs in any environment, including the CI build
// gate's containers.
//

import XCTest
@testable import Pdftract

final class FlagLikeValuePassthroughTests: XCTestCase {
    // MARK: Fixture

    /// Minimal `Document` JSON for the buffered extract tests to decode.
    private static let minimalDocumentJSON =
        #"{"schema_version":"1.0","pages":[],"metadata":{"page_count":0}}"#

    /// Minimal `Page` NDJSON line for the streaming extract test.
    private static let minimalPageNDJSON =
        #"{"page_index":0,"width":612,"height":792,"rotation":0,"spans":[],"blocks":[]}"#

    /// Minimal `Match` NDJSON line for the search tests.
    private static let minimalMatchNDJSON =
        #"{"text":"-5%","page":3,"bbox":[1,2,3,4],"context":{"before":"a ","after":" b"}}"#

    /// The CLI's `verify-receipt --json` success output, same shape
    /// ReceiptArgvPassthroughTests decodes.
    private static let successJSON =
        #"{"status":"ok","pdf_fingerprint":"pdftract-v1:abc123","page_index":14,"best_iou":0.97,"expected_content_hash":"sha256:9b21","actual_content_hash":"sha256:9b21"}"#

    /// Bytes for the on-disk file with a dash-leading name: non-empty, so a
    /// truncated read is distinguishable from a successful one.
    private static let dashNamedFileBytes = Data("%PDF-1.4\n-dash-named fixture\n%%EOF\n".utf8)

    // MARK: Argv-capturing stub (suite pattern), with dash-safe file capture

    /// Writes an executable stub `pdftract` that records its argv one
    /// argument per line into `<directory>/captured-argv.txt`, prints
    /// `stdout`, and exits with `exitCode`. Additionally, every argv element
    /// matching `-*.pdf` is copied through `cat --` into
    /// `<directory>/captured-input.bin`: `cat --` (unlike the `[ -f … ]`
    /// guard other stubs use) accepts an operand beginning with `-`, so the
    /// dash-named file's content can be verified without the test utility
    // itself tripping over flag parsing.
    private static func writeArgCapturingStub(
        stdout: String,
        exitCode: Int = 0
    ) throws -> (directory: URL, binaryPath: String, capturePath: String, inputCopyPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-flaglike-passthrough-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let captureURL = directory.appendingPathComponent("captured-argv.txt")
        let inputCopyURL = directory.appendingPathComponent("captured-input.bin")
        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > '\(captureURL.path)'\n"
        script += "for arg in \"$@\"; do\n"
        script += "  case \"$arg\" in\n"
        script += "    -*.pdf) cat -- \"$arg\" >> '\(inputCopyURL.path)' 2>/dev/null ;;\n"
        script += "  esac\n"
        script += "done\n"
        if exitCode != 0 {
            script += "echo 'stub pdftract failure for exit code \(exitCode)' >&2\n"
        }
        script += "cat <<'PDFTRACT_STUB_EOF'\n\(stdout)\nPDFTRACT_STUB_EOF\n"
        script += "exit \(exitCode)\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath, captureURL.path, inputCopyURL.path)
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

    // MARK: Source.path beginning with one dash

    /// A file literally named `-report.pdf` — the defect this bead fixes —
    /// must arrive as `extract`'s positional input after `--`, never as a
    /// flag. The real CLI rejects the pre-fix argv with "unexpected argument
    /// '-r'" before any flag evaluation.
    func testExtractPathBeginningWithDashIsPassedAsAValue() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalDocumentJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        _ = try await client.extract(.path("-report.pdf"))

        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["extract", "--json", "--", "-report.pdf"],
            "a dash-leading path must be the positional after the -- separator"
        )
    }

    // MARK: Source.path beginning with two dashes

    /// A path shaped like a long option (`--pages=evil.pdf`) is shielded by
    /// the same separator — `--` ends flag parsing entirely, so nothing
    /// after it is ever option-consumed, whatever it resembles.
    func testExtractPathBeginningWithDoubleDashIsPassedAsAValue() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalDocumentJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        _ = try await client.extract(.path("--pages=evil.pdf"))

        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["extract", "--json", "--", "--pages=evil.pdf"],
            "a double-dash path must be the positional after the -- separator"
        )
    }

    // MARK: A real dash-named file round-trips

    /// The user-visible fix, end to end at the SDK boundary: an actual file
    /// named `-report.pdf` on disk is extractable. The stub's `cat --` leg
    /// proves the child received a readable file with the caller's bytes at
    /// the dash-leading path — not merely an argv string.
    func testRealDashNamedFileReachesTheChildReadable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-flaglike-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dashNamedFile = directory.appendingPathComponent("-report.pdf")
        try Self.dashNamedFileBytes.write(to: dashNamedFile)

        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalDocumentJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        _ = try await client.extract(.path(dashNamedFile.path))

        let argv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(
            argv,
            ["extract", "--json", "--", dashNamedFile.path],
            "the dash-named file's exact path must follow the -- separator"
        )
        XCTAssertEqual(
            try Data(contentsOf: stub.directory.appendingPathComponent("captured-input.bin")),
            Self.dashNamedFileBytes,
            "the child could not read the caller's bytes from the dash-named path"
        )
    }

    // MARK: Streaming extract site

    /// `extractStream` builds its argv on its own code path; the separator
    /// must hold there too.
    func testExtractStreamPathBeginningWithDashIsPassedAsAValue() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalPageNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        var pages: [Page] = []
        for try await page in client.extractStream(.path("-report.pdf")) {
            pages.append(page)
        }

        XCTAssertEqual(pages.count, 1, "stub emitted one Page; the stream must consume it before argv is asserted")
        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["extract", "--ndjson", "--", "-report.pdf"],
            "the streaming path must shield the dash-leading source the same way"
        )
    }

    // MARK: Search pattern beginning with a dash

    /// A pattern the old argv let the CLI misparse — `-js` became
    /// `--threads s` against a real build — must land after `--`, before the
    /// source (grep's positional order). A `-5%` query is an ordinary input.
    func testSearchPatternBeginningWithDashIsPassedAsAValue() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalMatchNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        var matches: [Match] = []
        for try await match in client.search(.path("document.pdf"), "-5% total") {
            matches.append(match)
        }

        XCTAssertEqual(matches.count, 1, "stub emitted one Match; the stream must consume it before argv is asserted")
        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["grep", "--", "-5% total", "document.pdf"],
            "the pattern must be grep's first positional, after the -- separator"
        )
    }

    /// The silent-misparse case: pattern `-i` resembles the CLI's
    /// case-insensitivity flag. Before the separator it flipped the search's
    /// case-sensitivity and demoted the source path to the pattern; after
    /// it, `-i` is searched for literally.
    func testSearchPatternOfBareFlagIsPassedAsAValue() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalMatchNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        var matches: [Match] = []
        for try await match in client.search(.path("document.pdf"), "-i") {
            matches.append(match)
        }

        XCTAssertEqual(matches.count, 1, "stub emitted one Match; the stream must consume it before argv is asserted")
        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["grep", "--", "-i", "document.pdf"],
            "a flag-shaped pattern must be searched for, never parsed as a flag"
        )
    }

    // MARK: verifyReceipt paths beginning with dashes

    /// Both caller-supplied `verifyReceipt` paths — the PDF and the receipt
    /// JSON — sit after the separator; `--json` moved ahead of it. A
    /// receipt-producing pipeline that names intermediates with leading
    /// dashes must keep working.
    func testVerifyReceiptPathsBeginningWithDashArePassedAsValues() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.successJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        _ = try await client.verifyReceipt("-doc.pdf", receipt: Receipt(data: "-receipt.json"))

        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["verify-receipt", "--json", "--", "-doc.pdf", "-receipt.json"],
            "both verify-receipt positionals must follow the -- separator, --json before it"
        )
    }
}
