//
// Passthrough tests for the `Source.bytes` argument path — the in-memory
// source that README.md documents in "Extract from in-memory Data"
// (pdfswift-1959bda3). Before that section and this file, `.bytes` was the
// one public `Source` case with neither usage docs nor test coverage, despite
// being the only source case with a disk side effect: it spills the payload
// to a temporary file so the pdftract CLI can read it.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as ExitCodeMappingTests.swift and
// ExtractOptionsOcrPassthroughTests.swift. Keep it that way.
//
// What is pinned, in two halves:
//
//   1. Spill. The caller's `Data` reaches disk byte-for-byte (multi-byte
//      UTF-8 and an embedded NUL pin exact-bytes copying, not just length),
//      under a `pdftract-input-<UUID>.pdf` name in the temp directory, and
//      the child receives that path as a positional argument — no inline
//      data on the argv. It is the SOLE argument for the flagless consumers
//      (extract, both streaming paths, search); extractText and
//      extractMarkdown append only their format flag (+ --json) after it.
//   2. Cleanup. The SDK deletes the spill itself when the call finishes —
//      the README's "no manual cleanup is required" promise. Asserted on the
//      success path (the buffered `defer` runs before `extract` returns), on
//      the failing-child path (exit 4), and on both streaming paths, because
//      `PreparedArgs.cleanUp()` placement is inlined per method in
//      Methods.swift.tera: a template edit could fix one consumer and miss
//      another, exactly the per-method drift ExtractOptionsOcrPassthroughTests
//      guards for the options serialization.
//
// Why every consumer: the spill itself is shared (`Source.toArgs` in
// Types.swift.tera), but each method appends `prepared.arguments` and places
// its own `defer { prepared.cleanUp() }`, so the five `source.toArgs()` call
// sites can drift independently. extract / extractText / extractMarkdown /
// extractStream / search are all pinned here; getMetadata, hash, and classify
// share the buffered shape extract pins (toArgs → defer → append → exec), and
// verifyReceipt takes a path literal rather than a `Source`.
//
// Timeout and cancellation reach the same `defer` through the same throw
// paths the failing-child test exercises; ProcessLifecycleTests owns that
// termination machinery (and carries the known docker-env failures), so this
// file does not re-drive child termination itself.
//
// No real pdftract binary is needed and none is consulted: the stub answers
// for it, so the whole suite runs in any environment, including the CI build
// gate's containers. The stub additionally copies every argv element that
// names an existing file to a known location before exiting — the only way
// to inspect the spill's contents, since the SDK deletes it as part of the
// call returning.
//
// The exact-name and exact-argv assertions are deliberately strict, per the
// suite convention: a regeneration that renames the spill, changes its
// extension, or reorders the argv fails here loudly instead of silently
// changing what every `.bytes` caller's invocation means.
//

import XCTest
@testable import Pdftract
// White-box access to PdftractCodegen internals (`Source.toArgs`,
// `PreparedArgs.cleanUp`): `@testable import Pdftract` alone only opens the
// re-export shell in Pdftract.swift — the re-exported public API — not the
// defining module's internal declarations.
@testable import PdftractCodegen

final class SourceBytesPassthroughTests: XCTestCase {
    // MARK: Fixture

    /// Payload carrying a multi-byte UTF-8 sequence and an embedded NUL: a
    /// length-only spill or a String round-trip fails both, so byte equality
    /// here means the file on disk is the caller's `Data`, not a re-encoding
    /// of it.
    private static let pdfBytes = Data(
        "%PDF-1.4\nna\u{00EF}ve caf\u{00E9} \u{0000}payload\n%%EOF\n".utf8
    )

    /// Minimal `Document` JSON the buffered-path stub prints — enough for
    /// `extract`, `extractText`, and `extractMarkdown` to decode; none of the
    /// buffered tests assert decoded content, only the argv, the spill, and
    /// the cleanup.
    private static let minimalDocumentJSON =
        #"{"schema_version":"1.0","pages":[],"metadata":{"page_count":0}}"#

    /// Minimal `Page` NDJSON line, so the extractStream stub yields exactly
    /// one page — proving the child ran to completion before the spill
    /// assertions are read.
    private static let minimalPageNDJSON =
        #"{"page_index":0,"width":612,"height":792,"rotation":0,"spans":[],"blocks":[]}"#

    /// Minimal `Match` NDJSON line, same purpose for the search stub.
    private static let minimalMatchNDJSON =
        #"{"text":"invoice","page":3,"bbox":[1,2,3,4],"context":{"before":"a ","after":" b"}}"#

    // MARK: Argv-capturing stub (ExtractOptionsOcrPassthroughTests pattern,
    // plus input capture)

    /// Writes an executable stub `pdftract` that records its argv one argument
    /// per line into `<directory>/captured-argv.txt`, copies every argument
    /// naming an existing file to `<directory>/captured-input.bin` (the
    /// spilled `.bytes` payload is deleted by the SDK when the call returns,
    /// so the copy is the only way to inspect it), prints `stdout` (and one
    /// stderr line when failing), and exits with `exitCode`. The capture paths
    /// are baked into this stub instance, so concurrent tests never share
    /// capture state.
    private static func writeArgCapturingStub(
        stdout: String,
        exitCode: Int = 0
    ) throws -> (directory: URL, binaryPath: String, capturePath: String, inputCopyPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-bytes-passthrough-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let captureURL = directory.appendingPathComponent("captured-argv.txt")
        let inputCopyURL = directory.appendingPathComponent("captured-input.bin")
        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > '\(captureURL.path)'\n"
        script += "for arg in \"$@\"; do\n"
        script += "  [ -f \"$arg\" ] && cp \"$arg\" '\(inputCopyURL.path)'\n"
        script += "done\n"
        if exitCode != 0 {
            script += "echo 'stub pdftract failure for exit code \(exitCode)' >&2\n"
        }
        // Quoted delimiter: the payload must pass through untouched.
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

    /// The bytes the stub found on disk for the source argument. A missing
    /// copy means the stub never saw an existing file — the spill did not
    /// reach disk — and surfaces as a thrown test error.
    private static func capturedInput(from inputCopyPath: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: inputCopyPath))
    }

    /// Streaming cleanup runs in the producer Task's `defer`, which is not
    /// ordered against the consumer's loop exit: the loop can observe
    /// `finish()` a beat before the producer's `cleanUp()` lands. Poll
    /// briefly instead of asserting synchronously — the README promises the
    /// spill is deleted when the call finishes, not that it is gone before
    /// `next()` returns nil.
    private static func waitUntilRemoved(_ path: String, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Shared spill-shape assertions for a captured buffered/streaming argv:
    /// the element at `sourceArgumentIndex` is the spill and nothing else
    /// about it appears on the argv. `followedBy` names the arguments that
    /// legitimately trail the spill — empty for the flagless consumers, where
    /// the spill is the LAST element (the shape the count assertion used to
    /// hard-code, which wrongly failed the `extractText`/`extractMarkdown`
    /// call sites whose format flags follow the source). Returns the spill
    /// path for the caller's content/cleanup assertions.
    @discardableResult
    private static func assertSpillArgument(
        _ argv: [String],
        sourceArgumentIndex: Int,
        followedBy flags: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        XCTAssertEqual(
            argv.count,
            sourceArgumentIndex + 1 + flags.count,
            "expected exactly \(sourceArgumentIndex + 1 + flags.count) argv elements (spill + \(flags)), sent \(argv)",
            file: file,
            line: line
        )
        let spill = argv[sourceArgumentIndex]
        XCTAssertTrue(
            spill.hasSuffix(".pdf"),
            "spill name \(spill) — expected a .pdf suffix the CLI dispatches on",
            file: file,
            line: line
        )
        XCTAssertTrue(
            spill.contains("pdftract-input-"),
            "spill name \(spill) — expected the pdftract-input- prefix (implementation-pinned)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            spill.hasPrefix(FileManager.default.temporaryDirectory.path),
            "spill \(spill) escaped the temp directory",
            file: file,
            line: line
        )
        return spill
    }

    // MARK: Buffered exec path — the README example

    /// The README "Extract from in-memory Data" example verbatim: the spill
    /// is the sole positional argument after `extract --json`, holds the
    /// caller's exact bytes, and is already gone when `extract` returns — the
    /// "no manual cleanup is required" promise on the success path.
    func testExtractFromInMemoryDataSpillsExactBytesAndCleansUp() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalDocumentJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        _ = try await client.extract(.bytes(Self.pdfBytes))

        let argv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(argv[0], "extract")
        XCTAssertEqual(argv[1], "--json")
        let spill = try Self.assertSpillArgument(argv, sourceArgumentIndex: 2)

        XCTAssertEqual(
            try Self.capturedInput(from: stub.inputCopyPath),
            Self.pdfBytes,
            "the file the child received is not the caller's bytes"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: spill),
            "the spilled temp file survived the extract() return — Source.bytes leaks on the success path"
        )
    }

    // MARK: Spill mechanics, direct

    /// `Source.bytes(data).toArgs()` on its own: one positional argument, one
    /// registered temporary file, byte-identical spill — and `cleanUp()`
    /// removes it, idempotently, as its "Idempotent" doc comment promises.
    /// This is the only test that pins the `temporaryFiles` registration
    /// itself; the end-to-end tests see the file only via the argv.
    func testPreparedArgsFromBytesSpillsAndCleansUpIdempotently() throws {
        let prepared = try Source.bytes(Self.pdfBytes).toArgs()

        XCTAssertEqual(
            prepared.arguments.count,
            1,
            "Source.bytes must contribute exactly one positional argument, sent \(prepared.arguments)"
        )
        XCTAssertEqual(
            prepared.temporaryFiles.count,
            1,
            "Source.bytes must register exactly one temporary file, registered \(prepared.temporaryFiles)"
        )
        XCTAssertEqual(
            prepared.temporaryFiles[0].path,
            prepared.arguments[0],
            "the registered temporary file must be the spilled argument"
        )

        let spill = prepared.arguments[0]
        XCTAssertTrue(spill.hasSuffix(".pdf"), "spill name \(spill) — expected a .pdf suffix")
        XCTAssertTrue(spill.contains("pdftract-input-"), "spill name \(spill) — expected the pdftract-input- prefix")

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: spill)),
            Self.pdfBytes,
            "the spilled file does not hold the caller's bytes"
        )

        prepared.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spill), "cleanUp() left the spill on disk")

        prepared.cleanUp() // second call must be a no-op, not a crash or error
        XCTAssertFalse(FileManager.default.fileExists(atPath: spill))
    }

    // MARK: Failure path

    /// The cleanup promise covers failures: a child that exits nonzero still
    /// leaves no spill behind when `extract` throws. The spill demonstrably
    /// reached the child first — the stub copied it — so this is the error
    /// path, not a never-spawned one.
    func testBytesSpillRemovedWhenBinaryFails() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalDocumentJSON, exitCode: 4)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        do {
            _ = try await client.extract(.bytes(Self.pdfBytes))
            XCTFail("extract() must throw for a child that exits 4")
        } catch let error as PdftractError {
            XCTAssertEqual(
                error.exitCode,
                4,
                "the child's exit 4 must surface as exitCode 4, got \(error.exitCode)"
            )
        }

        // The spill reached the failing child: byte-identical content, same
        // idiom as the success path above (left unused, the read discards its
        // result and asserts nothing).
        XCTAssertEqual(
            try Self.capturedInput(from: stub.inputCopyPath),
            Self.pdfBytes,
            "the spill did not reach the failing child with the caller's bytes"
        )

        let argv = try Self.capturedArguments(from: stub.capturePath)
        let spill = try Self.assertSpillArgument(argv, sourceArgumentIndex: 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: spill),
            "the spilled temp file survived a failing extract() — Source.bytes leaks on the error path"
        )
    }

    // MARK: The other ExtractOptions-shaped consumers

    /// `extractText` and `extractMarkdown` interleave their format flags
    /// *after* the source on the same buffered path; with `.bytes` the
    /// interleaved element is the spill path, and each call cleans up its own
    /// spill.
    func testBytesSourceThroughExtractTextAndMarkdown() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalDocumentJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        _ = try await client.extractText(.bytes(Self.pdfBytes))
        let textArgv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(textArgv[0], "extract")
        let textSpill = try Self.assertSpillArgument(
            textArgv,
            sourceArgumentIndex: 1,
            followedBy: ["--text", "--json"]
        )
        XCTAssertEqual(
            Array(textArgv.dropFirst(2)),
            ["--text", "--json"],
            "extractText() sent \(textArgv) — format flags belong after the spilled source path"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: textSpill),
            "the spilled temp file survived extractText()"
        )

        _ = try await client.extractMarkdown(.bytes(Self.pdfBytes))
        let markdownArgv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(markdownArgv[0], "extract")
        let markdownSpill = try Self.assertSpillArgument(
            markdownArgv,
            sourceArgumentIndex: 1,
            followedBy: ["--md", "--json"]
        )
        XCTAssertEqual(
            Array(markdownArgv.dropFirst(2)),
            ["--md", "--json"],
            "extractMarkdown() sent \(markdownArgv) — format flags belong after the spilled source path"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markdownSpill),
            "the spilled temp file survived extractMarkdown()"
        )
    }

    // MARK: Streaming paths

    /// `extractStream` re-runs the spill and the cleanup inside its own Task
    /// body, on a separate code path from the buffered methods. The page must
    /// arrive, and the spill must be gone once the loop finishes. Removal is
    /// polled: the producer's `defer` is not ordered against the consumer
    /// seeing `finish()`.
    func testBytesSourceThroughExtractStream() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalPageNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        var pages: [Page] = []
        for try await page in client.extractStream(.bytes(Self.pdfBytes)) {
            pages.append(page)
        }

        XCTAssertEqual(pages.count, 1, "stub emitted one Page; the stream must consume it before the spill assertions")
        XCTAssertEqual(pages[0].pageIndex, 0, "the streamed page must decode with the stub's page_index")

        let argv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(argv[0], "extract")
        XCTAssertEqual(argv[1], "--ndjson")
        let spill = try Self.assertSpillArgument(argv, sourceArgumentIndex: 2)
        XCTAssertTrue(
            Self.waitUntilRemoved(spill),
            "the spilled temp file survived extractStream() — Source.bytes leaks on the streaming path"
        )
    }

    /// `search` is the second streaming Task body (`grep`, not `extract`);
    /// same pins as extractStream, with the pattern before the spill.
    func testBytesSourceThroughSearch() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.minimalMatchNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        var matches: [Match] = []
        for try await match in client.search(.bytes(Self.pdfBytes), "invoice") {
            matches.append(match)
        }

        XCTAssertEqual(matches.count, 1, "stub emitted one Match; the stream must consume it before the spill assertions")
        XCTAssertEqual(matches[0].text, "invoice", "the streamed match must decode with the stub's text")

        let argv = try Self.capturedArguments(from: stub.capturePath)
        XCTAssertEqual(argv[0], "grep")
        XCTAssertEqual(argv[1], "invoice", "search() must pass the pattern before the source")
        let spill = try Self.assertSpillArgument(argv, sourceArgumentIndex: 2)
        XCTAssertTrue(
            Self.waitUntilRemoved(spill),
            "the spilled temp file survived search() — Source.bytes leaks on the streaming path"
        )
    }
}
