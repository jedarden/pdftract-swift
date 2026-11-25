//
// Passthrough tests for the README "custom binary path" API —
// `Pdftract(binaryPath:)` (`The SDK will search for 'pdftract' on your PATH.
// To specify a custom binary path: ...`).
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as ExtractOptionsOcrPassthroughTests.swift and
// ExitCodeMappingTests.swift. Keep it that way.
//
// What is pinned, and what the existing suites deliberately do not cover:
//
// 1. The custom path is *actually the binary spawned* — the README's whole
//    point for the parameter. ExitCodeMappingTests pins what happens when the
//    configured path cannot spawn; nothing proved the spawn goes to the
//    configured path when it CAN run. Each of the three spawn sites is
//    covered separately (buffered `exec` in Methods.swift, the
//    `extractStream` producer Task, and the `search` producer Task — each
//    builds its own Process and sets `executableURL` from `binaryPath` on its
//    own code path, so a template edit could honor the override in one and
//    lose it in another). The proof is a capture file only the stub can
//    write, plus a provenance marker in the payload that must survive the
//    SDK's decode: if the SDK ever ignored the override and spawned a
//    PATH-discovered `pdftract` instead, no capture exists and no marker
//    decodes — the test fails either way, including in environments where a
//    real binary does sit on PATH.
//
//    The stub's filename is deliberately NOT "pdftract" (and its fresh
//    temporary directory is on no PATH), because PATH discovery scans for
//    entries named exactly `pdftract`. A binary the discovery scan could
//    never select can only have been spawned through the verbatim custom
//    path, so the pin is airtight by construction rather than by environment
//    (a CI gate image with no pdftract installed would otherwise also pass a
//    broken override).
//
// 2. A missing or non-executable custom path fails the STREAMING spawn sites
//    in a defined way: the iteration finishes by throwing, yields nothing,
//    and never hangs. The buffered sites wrap a never-spawned child into the
//    SDK lifecycle error — base `PdftractError`, exit code `-1`,
//    `Failed to execute pdftract:` prefix — and that contract is already
//    pinned by ExitCodeMappingTests' lifecycle section for every buffered
//    method; it is not repeated here. The streaming producers have their own
//    `try process.run()` and their own catch, which re-throws the raw
//    Foundation spawn error into the stream instead of wrapping it. That is
//    the behavior pinned here — including the fact that it is NOT a
//    `PdftractError`, so the README's own
//    `catch let error as PdftractError` example would not catch it. Pinning
//    the current shape is deliberate: when a regeneration changes the
//    streaming wrapping (to match the buffered path or otherwise), this test
//    fails loudly and forces a conscious update of both the pin and the
//    README paragraph that documents it.
//
// All payloads are stub-supplied, so no real pdftract binary is needed and
// none is consulted: the whole suite runs in any environment, including the
// CI build gate's containers.
//

import XCTest
@testable import Pdftract

final class BinaryPathOverrideTests: XCTestCase {
    // MARK: Argv-capturing stub

    /// Provenance markers baked into the stub payloads — values a real
    /// pdftract run would not be expected to produce, so a decoded marker
    /// proves the caller consumed the STUB's stdout, not some other binary's.
    private static let markerPageCount = 4213
    private static let markerPageIndex = 7
    private static let markerMatchPage = 3
    private static let markerMatchText = "custom-binary-marker"

    /// `Document` JSON the buffered-path stub prints. The marker `page_count`
    /// must survive `JSONDecoder` into `Document.metadata.pageCount`.
    private static let markerDocumentJSON =
        #"{"schema_version":"1.0","pages":[],"metadata":{"page_count":4213}}"#

    /// One `Page` NDJSON line the `extractStream` stub prints, with the marker
    /// `page_index`. The yielded page must carry it.
    private static let markerPageNDJSON =
        #"{"page_index":7,"width":612,"height":792,"rotation":0,"spans":[],"blocks":[]}"#

    /// One `Match` NDJSON line the `search` stub prints, with the marker text
    /// and page. The yielded match must carry both.
    private static let markerMatchNDJSON =
        #"{"text":"custom-binary-marker","page":3,"bbox":[1.0,2.0,3.0,4.0],"context":{"before":"a ","after":" b"}}"#

    /// A stub executable plus its capture state.
    private struct Stub {
        let directory: URL
        let binaryPath: String
        let capturePath: String
    }

    /// Writes an executable stub whose filename is deliberately NOT
    /// "pdftract" into a fresh temporary directory (on no PATH), records its
    /// argv one argument per line into `<directory>/captured-argv.txt`, prints
    /// `payload` on stdout, and exits 0. The capture path is baked into this
    /// stub instance, so concurrent tests never share capture state.
    private static func writeArgCapturingStub(payload: String) throws -> Stub {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-binarypath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let captureURL = directory.appendingPathComponent("captured-argv.txt")
        // Not named "pdftract": PATH discovery looks for entries named exactly
        // "pdftract", so only the verbatim custom path can ever launch this.
        let binaryPath = directory
            .appendingPathComponent("pdftract-under-test-\(UUID().uuidString)").path

        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > '\(captureURL.path)'\n"
        // Quoted delimiter: the payload must pass through untouched.
        script += "cat <<'PDFTRACT_STUB_EOF'\n\(payload)\nPDFTRACT_STUB_EOF\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return Stub(directory: directory, binaryPath: binaryPath, capturePath: captureURL.path)
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

    // MARK: The custom path is the binary spawned — buffered site

    /// `extract` must spawn the binary at the caller's path, not run PATH
    /// discovery. Proven twice over: the decoded `Document` carries the
    /// stub's marker `page_count` (the output came from this stub), and the
    /// capture file holds exactly the buffered-path argv (the process came
    /// from this stub — nothing else writes it).
    func testCustomPathIsSpawnedByExtract() async throws {
        let stub = try Self.writeArgCapturingStub(payload: Self.markerDocumentJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let document = try await Pdftract(binaryPath: stub.binaryPath)
            .extract(.path("document.pdf"))

        XCTAssertEqual(
            document.metadata.pageCount,
            Self.markerPageCount,
            "extract() must decode the stub's stdout — a \(document.metadata.pageCount) page count means another binary answered"
        )
        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["extract", "--json", "--", "document.pdf"],
            "the capture file must hold the buffered-path argv — its existence proves the custom-path binary itself was spawned"
        )
    }

    // MARK: The custom path is the binary spawned — streaming sites

    /// `extractStream` builds its Process on its own code path; the override
    /// must reach it there too. The page is consumed before the capture is
    /// read, so the child demonstrably ran to completion.
    func testCustomPathIsSpawnedByExtractStream() async throws {
        let stub = try Self.writeArgCapturingStub(payload: Self.markerPageNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        var pages: [Page] = []
        for try await page in Pdftract(binaryPath: stub.binaryPath)
            .extractStream(.path("document.pdf"))
        {
            pages.append(page)
        }

        XCTAssertEqual(pages.count, 1, "the stub emitted one Page; the stream must consume it")
        XCTAssertEqual(
            pages.first?.pageIndex,
            Self.markerPageIndex,
            "the streamed page must carry the stub's marker page_index — another binary's page would not"
        )
        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["extract", "--ndjson", "--", "document.pdf"],
            "the capture file must hold the streaming-path argv — its existence proves the custom-path binary itself was spawned"
        )
    }

    /// `search` is the third spawn site (second streaming producer); same
    /// proof with the stub's marker match text and page.
    func testCustomPathIsSpawnedBySearch() async throws {
        let stub = try Self.writeArgCapturingStub(payload: Self.markerMatchNDJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        var matches: [Match] = []
        for try await match in Pdftract(binaryPath: stub.binaryPath)
            .search(.path("document.pdf"), "needle")
        {
            matches.append(match)
        }

        XCTAssertEqual(matches.count, 1, "the stub emitted one Match; the stream must consume it")
        XCTAssertEqual(
            matches.first?.text,
            Self.markerMatchText,
            "the streamed match must carry the stub's marker text — another binary's match would not"
        )
        XCTAssertEqual(
            matches.first?.page,
            Self.markerMatchPage,
            "the streamed match must carry the stub's marker page"
        )
        XCTAssertEqual(
            try Self.capturedArguments(from: stub.capturePath),
            ["grep", "--", "needle", "document.pdf"],
            "search() must send the documented grep argv to the custom-path binary"
        )
    }

    // MARK: Unusable custom path — the streaming sites' spawn failure

    /// Drives one streaming call to completion-or-throw and returns what
    /// happened: the yielded count and the error (nil if the iteration
    /// finished normally).
    private func runStream<C: Sendable>(
        _ makeStream: (Pdftract) -> PdftractStream<C>
    ) async -> (yielded: Int, thrown: Error?) {
        let client = Pdftract(binaryPath: "/nonexistent/pdftract-\(UUID().uuidString)")
        var count = 0
        do {
            for try await _ in makeStream(client) {
                count += 1
            }
            return (count, nil)
        } catch {
            return (count, error)
        }
    }

    /// Asserts the streaming spawn-failure contract: the iteration finishes
    /// by throwing (a silent normal completion would read as "the PDF had no
    /// pages"), yields nothing (the child never existed to produce anything),
    /// and the thrown error is the raw spawn failure — NOT a `PdftractError`.
    ///
    /// The negative type assertion is the divergence pin: the buffered path
    /// wraps the same failure into base `PdftractError` (exit code `-1`,
    /// pinned by ExitCodeMappingTests), while the streaming producers
    /// re-throw the Foundation spawn error as-is — which the README's own
    /// `catch let error as PdftractError` example would not catch. If a
    /// regeneration aligns the streaming paths with the buffered wrapping,
    /// this assertion fails and forces a conscious update of this pin and
    /// the README paragraph documenting the behavior.
    private func assertStreamingSpawnFailure(
        _ result: (yielded: Int, thrown: Error?),
        _ scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let thrown = result.thrown else {
            return XCTFail(
                "\(scenario): the stream finished normally instead of throwing — a never-spawned child must fail the iteration loudly",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            result.yielded,
            0,
            "\(scenario): nothing can be yielded when the child never spawned",
            file: file,
            line: line
        )
        XCTAssertFalse(
            thrown is CancellationError,
            "\(scenario): must throw the spawn failure, not cancellation",
            file: file,
            line: line
        )
        XCTAssertFalse(
            thrown is PdftractError,
            "\(scenario): today the streaming paths surface the raw Foundation spawn error (\(type(of: thrown))), not a PdftractError — if the SDK now wraps it, update this pin and the README paragraph together",
            file: file,
            line: line
        )
    }

    /// `extractStream` around a nonexistent custom path: throws, no yields,
    /// no hang. The path is randomized so a stray `pdftract` appearing at
    /// that literal location can never flip the test to a real spawn.
    func testNonexistentCustomPathFinishesExtractStreamWithoutYields() async throws {
        assertStreamingSpawnFailure(
            await runStream { $0.extractStream(.path("document.pdf")) },
            "nonexistent binaryPath (extractStream)"
        )
    }

    /// Same contract when the path exists but has no execute bit. Root cannot
    /// exec it either — the kernel denies execve on a file with no x bit set
    /// (verified 2026-11-24 in swift:5.10-jammy, the root-user CI gate image,
    /// by ExitCodeMappingTests) — so the EACCES spawn failure this test pins
    /// holds in the gate too.
    func testNonExecutableCustomPathFinishesExtractStreamWithoutYields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-stream-non-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryPath = directory
            .appendingPathComponent("pdftract-under-test-\(UUID().uuidString)").path
        try "#!/bin/sh\necho this file must never run\n".write(
            toFile: binaryPath,
            atomically: true,
            encoding: .utf8
        )
        // 0644: readable but not executable. If the SDK ever started this
        // file, the shebang would make the failure loud instead of silent.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binaryPath)

        var count = 0
        do {
            for try await _ in Pdftract(binaryPath: binaryPath)
                .extractStream(.path("document.pdf"))
            {
                count += 1
            }
            assertStreamingSpawnFailure((count, nil), "non-executable binaryPath (extractStream)")
        } catch {
            assertStreamingSpawnFailure((count, error), "non-executable binaryPath (extractStream)")
        }
    }

    /// `search`'s producer Task owns the third `try process.run()`; same
    /// contract there.
    func testNonexistentCustomPathFinishesSearchWithoutYields() async throws {
        let client = Pdftract(binaryPath: "/nonexistent/pdftract-\(UUID().uuidString)")
        var count = 0
        do {
            for try await _ in client.search(.path("document.pdf"), "needle") {
                count += 1
            }
            assertStreamingSpawnFailure((count, nil), "nonexistent binaryPath (search)")
        } catch {
            assertStreamingSpawnFailure((count, error), "nonexistent binaryPath (search)")
        }
    }
}
