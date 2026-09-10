//
// Conformance test suite for pdftract Swift SDK
// Auto-generated - do not edit manually
//

import XCTest
@testable import Pdftract

final class ConformanceTests: XCTestCase {
    var client: Pdftract!
    var suite: [String: Any]?

    override func setUp() {
        client = Pdftract()

        let suitePath = ProcessInfo.processInfo.environment["CONFORMANCE_SUITE"] ?? "tests/sdk-conformance/cases.json"

        if let data = try? Data(contentsOf: URL(fileURLWithPath: suitePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            suite = json
        }
    }

    func testBinaryAvailable() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "pdftract --version"]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "pdftract binary not found on PATH")
    }

    func testConformance() async throws {
        guard let suite = suite,
              let cases = suite["cases"] as? [[String: Any]] else {
            throw XCTSkip("No conformance suite loaded")
        }

        for testCase in cases {
            let id = testCase["id"] as? String ?? "unknown"
            let method = testCase["method"] as? String ?? "unknown"

            try await runTestCase(testCase, fixturePath: "fixtures/\(testCase["fixture"] as? String ?? "")")
        }
    }

    private func runTestCase(_ testCase: [String: Any], fixturePath: String) async throws {
        guard let method = testCase["method"] as? String else {
            throw XCTSkip("No method specified")
        }

        switch method {
        case "extract":
            try await testExtract(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "extract_text":
            try await testExtractText(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "extract_markdown":
            try await testExtractMarkdown(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "get_metadata":
            try await testGetMetadata(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "hash":
            try await testHash(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "classify":
            try await testClassify(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "verify_receipt":
            try await testVerifyReceipt(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "search":
            try await testSearch(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "extract_stream":
            try await testExtractStream(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        default:
            throw XCTSkip("Method not yet implemented: \(method)")
        }
    }

    private func testExtract(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let doc = try await client.extract(.path(fixturePath))

        if let pageCount = assertions?["page_count"] as? Int {
            XCTAssertEqual(doc.pages.count, pageCount)
        }

        if let hasTitle = assertions?["has_title"] as? Bool, hasTitle {
            XCTAssertNotNil(doc.metadata.title)
        }
    }

    private func testExtractText(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let text = try await client.extractText(.path(fixturePath))

        if let minLen = assertions?["min_length"] as? Int {
            XCTAssertGreaterThanOrEqual(text.count, minLen)
        }

        if let contains = assertions?["contains"] as? [String] {
            for substr in contains {
                XCTAssertTrue(text.contains(substr), "Expected text to contain: \(substr)")
            }
        }
    }

    private func testExtractMarkdown(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let md = try await client.extractMarkdown(.path(fixturePath))

        if let minLen = assertions?["min_length"] as? Int {
            XCTAssertGreaterThanOrEqual(md.count, minLen)
        }
    }

    private func testGetMetadata(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let metadata = try await client.getMetadata(.path(fixturePath))

        if let pageCount = assertions?["page_count"] as? Int {
            XCTAssertEqual(metadata.pageCount, pageCount)
        }
    }

    private func testHash(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let fingerprint = try await client.hash(.path(fixturePath))

        XCTAssertEqual(fingerprint.hash.count, 64)
        XCTAssertEqual(fingerprint.fastHash.count, 64)

        if let pageCount = assertions?["page_count"] as? Int {
            XCTAssertEqual(fingerprint.pageCount, pageCount)
        }
    }

    private func testClassify(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let classification = try await client.classify(.path(fixturePath))

        XCTAssertFalse(classification.category.isEmpty)
        XCTAssertTrue(classification.confidence >= 0 && classification.confidence <= 1)
    }

    private func testVerifyReceipt(_ fixturePath: String, assertions: [String: Any]?) async throws {
        guard let receipt = assertions?["receipt"] as? String else {
            throw XCTSkip("Receipt not provided in assertions")
        }

        let receiptStruct = Receipt(data: receipt)
        let result = try await client.verifyReceipt(fixturePath, receipt: receiptStruct)

        if let expectedValid = assertions?["valid"] as? Bool {
            XCTAssertEqual(result.valid, expectedValid)
        }
    }

    private func testSearch(_ fixturePath: String, assertions: [String: Any]?) async throws {
        guard let pattern = assertions?["pattern"] as? String else {
            throw XCTSkip("Pattern not provided in assertions")
        }

        var matchCount = 0
        for try await _ in client.search(.path(fixturePath), pattern) {
            matchCount += 1
            if let maxResults = assertions?["max_results"] as? Int, matchCount >= maxResults {
                break
            }
        }

        if let minMatches = assertions?["min_matches"] as? Int {
            XCTAssertGreaterThanOrEqual(matchCount, minMatches)
        }
    }

    private func testExtractStream(_ fixturePath: String, assertions: [String: Any]?) async throws {
        var pageCount = 0
        for try await _ in client.extractStream(.path(fixturePath)) {
            pageCount += 1
        }

        if let expectedPages = assertions?["page_count"] as? Int {
            XCTAssertEqual(pageCount, expectedPages)
        }
    }
}

/// Regression tests for stderr backpressure in the streaming APIs.
///
/// `extractStream` and `search` read stdout line-by-line; they used to read
/// stderr only after the process exited. A child that writes more than the OS
/// pipe buffer (~64KB on Linux) to stderr then blocks in write() while the SDK
/// blocks on stdout, so the stream never finishes and the caller hangs. Each
/// test drives a fake `pdftract` binary that emits 128 KiB of stderr — twice
/// the pipe buffer — and asserts the stream still drains. A watchdog turns a
/// revived deadlock into a failed assertion instead of a wedged test run.
final class StreamingStderrRegressionTests: XCTestCase {
    /// KiB of stderr the fake binaries emit: 2x the ~64KB Linux pipe buffer.
    private static let stderrKiB = 128

    /// Sentinel written after the stderr filler. Only stderr captured in full —
    /// not just whatever fit in the pipe buffer — can contain it.
    private static let stderrTailMarker = "STDERR_TAIL_MARKER_6bc41168"

    /// Generous enough for a loaded CI box, short enough that a deadlock fails
    /// fast instead of hanging the suite.
    private static let watchdogSeconds: UInt64 = 30

    /// NDJSON `Page` lines for a fake `extract --ndjson` child.
    private static func pageLines(count: Int) -> [String] {
        (0..<count).map { index in
            "{\"page_index\":\(index),\"width\":612.0,\"height\":792.0,\"rotation\":0,\"spans\":[],\"blocks\":[]}"
        }
    }

    /// NDJSON `Match` lines for a fake `grep` child.
    private static func matchLines(count: Int) -> [String] {
        (0..<count).map { index in
            "{\"text\":\"needle\",\"page\":\(index),\"bbox\":[0.0,0.0,10.0,10.0],\"context\":{\"before\":\"a\",\"after\":\"b\"}}"
        }
    }

    /// Writes an executable fake `pdftract` that prints `stdoutLines` on
    /// stdout, writes `stderrKiB` KiB of filler to stderr (optionally followed
    /// by `stderrTailMarker`), and exits with `exitCode`. The child ignores its
    /// arguments entirely, so tests can pass any `Source`.
    private static func writeFakeBinary(
        stdoutLines: [String],
        trailingStderrMarker: Bool,
        exitCode: Int
    ) throws -> (directory: URL, binaryPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-stderr-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var script = "#!/bin/sh\n"
        for line in stdoutLines {
            script += "echo '\(line)'\n"
        }
        script += "head -c \(stderrKiB * 1024) /dev/zero | tr '\\0' 'a' >&2\n"
        if trailingStderrMarker {
            script += "echo '\(stderrTailMarker)' >&2\n"
        }
        script += "exit \(exitCode)\n"

        let binaryPath = directory.appendingPathComponent("pdftract").path
        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath)
    }

    private struct DrainOutcome {
        var valueCount = 0
        /// The terminal error, when the stream finished by throwing.
        var error: Error?
        /// False when the watchdog fired first — the stream never finished.
        var finished = true
    }

    /// Consumes `stream` to completion and reports how many values it yielded
    /// plus its terminal error, guarded by a watchdog. A stderr backpressure
    /// deadlock surfaces as `finished == false` rather than hanging the suite.
    private static func drain<T>(
        _ makeStream: @escaping () -> AsyncThrowingStream<T, Error>
    ) async -> DrainOutcome {
        await withTaskGroup(of: DrainOutcome.self) { group in
            group.addTask {
                var outcome = DrainOutcome()
                do {
                    for try await _ in makeStream() {
                        outcome.valueCount += 1
                    }
                } catch {
                    outcome.error = error
                }
                return outcome
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000)
                return DrainOutcome(finished: false)
            }
            let first = await group.next() ?? DrainOutcome(finished: false)
            group.cancelAll()
            return first
        }
    }

    func testExtractStreamDrainsStderrOverPipeBuffer() async throws {
        let fake = try Self.writeFakeBinary(
            stdoutLines: Self.pageLines(count: 3),
            trailingStderrMarker: false,
            exitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let outcome = await Self.drain { client.extractStream(.path("/does/not/matter.pdf")) }

        XCTAssertTrue(outcome.finished, "extractStream hung: >64KiB of stderr deadlocked the stream")
        XCTAssertNil(outcome.error, "exit code 0 should not throw: \(String(describing: outcome.error))")
        XCTAssertEqual(outcome.valueCount, 3, "expected all 3 pages despite 128KiB of stderr")
    }

    func testSearchDrainsStderrOverPipeBuffer() async throws {
        let fake = try Self.writeFakeBinary(
            stdoutLines: Self.matchLines(count: 3),
            trailingStderrMarker: false,
            exitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let outcome = await Self.drain { client.search(.path("/does/not/matter.pdf"), "needle") }

        XCTAssertTrue(outcome.finished, "search hung: >64KiB of stderr deadlocked the stream")
        XCTAssertNil(outcome.error, "exit code 0 should not throw: \(String(describing: outcome.error))")
        XCTAssertEqual(outcome.valueCount, 3, "expected all 3 matches despite 128KiB of stderr")
    }

    func testExtractStreamMapsCapturedStderrOnNonzeroExit() async throws {
        let fake = try Self.writeFakeBinary(
            stdoutLines: [],
            trailingStderrMarker: true,
            exitCode: 2
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let outcome = await Self.drain { client.extractStream(.path("/does/not/matter.pdf")) }

        XCTAssertTrue(outcome.finished, "extractStream hung: >64KiB of stderr deadlocked the stream")
        guard let error = outcome.error else {
            return XCTFail("expected a terminal error for exit code 2")
        }
        guard let corruptPdfError = error as? CorruptPdfError else {
            return XCTFail("expected CorruptPdfError, got \(type(of: error))")
        }
        // The marker follows 128KiB of filler, so only a full concurrent drain
        // can hand it to mapError — a prefix read would stop at the pipe buffer.
        XCTAssertTrue(
            corruptPdfError.message.contains(Self.stderrTailMarker),
            "stderr handed to mapError was truncated; it ended with: \(corruptPdfError.message.suffix(64))"
        )
        XCTAssertEqual(corruptPdfError.exitCode, 2)
    }

    func testSearchMapsCapturedStderrOnNonzeroExit() async throws {
        let fake = try Self.writeFakeBinary(
            stdoutLines: [],
            trailingStderrMarker: true,
            exitCode: 3
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let outcome = await Self.drain { client.search(.path("/does/not/matter.pdf"), "needle") }

        XCTAssertTrue(outcome.finished, "search hung: >64KiB of stderr deadlocked the stream")
        guard let error = outcome.error else {
            return XCTFail("expected a terminal error for exit code 3")
        }
        guard let encryptionError = error as? EncryptionError else {
            return XCTFail("expected EncryptionError, got \(type(of: error))")
        }
        XCTAssertTrue(
            encryptionError.message.contains(Self.stderrTailMarker),
            "stderr handed to mapError was truncated; it ended with: \(encryptionError.message.suffix(64))"
        )
        XCTAssertEqual(encryptionError.exitCode, 3)
    }
}
