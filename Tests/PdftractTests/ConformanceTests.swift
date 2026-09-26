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
///
/// The watchdog polls a detached consumer rather than awaiting it in a task
/// group, because a consumer wedged in the blocking `readData(ofLength:)`
/// never finishes and `withTaskGroup` cannot return until every child does —
/// so `group.next()` and the implicit group drain hang forever. The wedged
/// task never observes its cancellation either (it is stuck in a blocking
/// read, not a suspension point), which is why the `cancelAll()` fallback
/// could not save the old harness: the stream's `onTermination`, and with it
/// `process.terminate()`, is never reached. Instead the watchdog SIGKILLs the
/// fake child (via the pidfile it writes) once the budget is spent: the shell
/// is the only holder of the SDK's stdout write end — its wedged pipeline
/// children redirect theirs away — so its death EOFs the deadlocked read and
/// unwedges the leaked consumer after the test case has already failed.
/// SIGKILL rather than SIGTERM because only SIGKILL cannot be deferred or
/// blocked; dash dies to either, but nothing guarantees that of a future fake.
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
    /// by `stderrTailMarker`), and exits with `exitCode`. The child records its
    /// shell pid in a pidfile so the watchdog can SIGKILL it if it deadlocks.
    /// It ignores its arguments entirely, so tests can pass any `Source`.
    private static func writeFakeBinary(
        stdoutLines: [String],
        trailingStderrMarker: Bool,
        exitCode: Int
    ) throws -> (directory: URL, binaryPath: String, pidPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-stderr-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory.appendingPathComponent("pdftract").path
        let pidPath = directory.appendingPathComponent("pid").path

        var script = "#!/bin/sh\n"
        script += "echo $$ > '\(pidPath)'\n"
        for line in stdoutLines {
            script += "echo '\(line)'\n"
        }
        script += "head -c \(stderrKiB * 1024) /dev/zero | tr '\\0' 'a' >&2\n"
        if trailingStderrMarker {
            script += "echo '\(stderrTailMarker)' >&2\n"
        }
        script += "exit \(exitCode)\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath, pidPath)
    }

    private struct DrainOutcome {
        var valueCount = 0
        /// The terminal error, when the stream finished by throwing.
        var error: Error?
        /// False when the watchdog fired first — the stream never finished.
        var finished = true
    }

    /// Handoff for the detached consumer's outcome. An actor (not a locked
    /// struct) so the polling loop can await it without blocking a cooperative
    /// thread.
    private actor DrainBox {
        private var stored: DrainOutcome?

        func store(_ outcome: DrainOutcome) {
            guard stored == nil else { return }
            stored = outcome
        }

        var outcome: DrainOutcome? { stored }
    }

    /// Best-effort SIGKILL of the fake child through its pidfile. SIGKILL, not
    /// SIGTERM: dash defers the latter while it is stuck in write() (see the
    /// class comment), while SIGKILL cannot be blocked. Killing the shell is
    /// enough — it is the only holder of the SDK's stdout write end, so its
    /// death EOFs the deadlocked read and unblocks the leaked consumer task.
    private static func killFakeChild(pidPath: String) {
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        kill(pid, SIGKILL)
    }

    /// Consumes `stream` to completion and reports how many values it yielded
    /// plus its terminal error, guarded by a watchdog. A stderr backpressure
    /// deadlock surfaces as `finished == false` rather than hanging the suite:
    /// the consumer runs detached (a deadlocked one can be neither joined nor
    /// cancelled) and the watchdog kills the fake child before returning.
    private static func drain<T>(
        _ makeStream: @escaping () -> AsyncThrowingStream<T, Error>,
        killChild: @escaping @Sendable () -> Void
    ) async -> DrainOutcome {
        let box = DrainBox()
        Task.detached {
            var outcome = DrainOutcome()
            do {
                for try await _ in makeStream() {
                    outcome.valueCount += 1
                }
            } catch {
                outcome.error = error
            }
            await box.store(outcome)
        }

        // Poll instead of awaiting the consumer so a deadlock returns control
        // to the test case and fails an assertion instead of wedging the run.
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(watchdogSeconds) * 20
        var ticks = 0
        while await box.outcome == nil {
            if ticks >= maxTicks {
                killChild()
                return DrainOutcome(finished: false)
            }
            try? await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
        return await box.outcome!
    }

    func testExtractStreamDrainsStderrOverPipeBuffer() async throws {
        let fake = try Self.writeFakeBinary(
            stdoutLines: Self.pageLines(count: 3),
            trailingStderrMarker: false,
            exitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let outcome = await Self.drain(
            { client.extractStream(.path("/does/not/matter.pdf")) },
            killChild: { Self.killFakeChild(pidPath: fake.pidPath) }
        )

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
        let outcome = await Self.drain(
            { client.search(.path("/does/not/matter.pdf"), "needle") },
            killChild: { Self.killFakeChild(pidPath: fake.pidPath) }
        )

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
        let outcome = await Self.drain(
            { client.extractStream(.path("/does/not/matter.pdf")) },
            killChild: { Self.killFakeChild(pidPath: fake.pidPath) }
        )

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
        let outcome = await Self.drain(
            { client.search(.path("/does/not/matter.pdf"), "needle") },
            killChild: { Self.killFakeChild(pidPath: fake.pidPath) }
        )

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

/// Regression tests for Task-cancellation and timeout lifecycle semantics.
///
/// Contract (README "Cancellation and timeouts"): cancelling the Task around
/// a buffered call, expiring `timeout:`, or dropping a stream must terminate
/// (SIGTERM) *and reap* the spawned pdftract child — never leave an orphaned
/// process, an unreaped zombie, or a caller wedged on a pipe that never
/// closes. A sequence dropped before the child even launches must not spawn
/// one at all, and must not trip `Process.terminate()`'s not-launched trap.
///
/// Each test drives a fake `pdftract` that records its shell pid in a
/// pidfile, prints any scripted stdout, then sleeps far past every deadline —
/// so only the SDK's lifecycle machinery can end it. "Killed and reaped" is
/// observable as `kill(pid, 0) != 0`: a live child answers the probe and so
/// does a zombie (killed but never `waitUntilExit()`-ed) — only a reaped
/// child leaves the process table entirely. Every wait is bounded by a
/// watchdog so a revived defect fails an assertion instead of hanging the
/// suite.
final class ProcessLifecycleTests: XCTestCase {
    /// Generous enough for a loaded CI box, short enough that a deadlock or
    /// orphan fails fast instead of hanging the suite.
    private static let watchdogSeconds: UInt64 = 10

    /// Minimal valid `Document` JSON for a fake child to print.
    private static let documentJSON =
        #"{"schema_version":"1.0","pages":[{"page_index":0,"width":612.0,"height":792.0,"rotation":0,"spans":[],"blocks":[]}],"metadata":{"page_count":1}}"#

    /// NDJSON `Page` line for a fake `extract --ndjson` child.
    private static func pageJSON(index: Int) -> String {
        "{\"page_index\":\(index),\"width\":612.0,\"height\":792.0,\"rotation\":0,\"spans\":[],\"blocks\":[]}"
    }

    /// NDJSON `Match` line for a fake `grep` child.
    private static func matchJSON(page: Int) -> String {
        "{\"text\":\"needle\",\"page\":\(page),\"bbox\":[0.0,0.0,10.0,10.0],\"context\":{\"before\":\"a\",\"after\":\"b\"}}"
    }

    private struct FakeBinary {
        var directory: URL
        var binaryPath: String
        var pidPath: String
    }

    /// Writes an executable fake `pdftract` that records its shell pid in a
    /// pidfile, prints `stdoutLines` on stdout, then sleeps `sleepSeconds` —
    /// far past every deadline in this suite, so only the SDK's lifecycle
    /// machinery (not natural exit) can end it. Ignores its arguments
    /// entirely, so tests can pass any `Source`.
    private static func writeFakeBinary(
        stdoutLines: [String],
        sleepSeconds: Int
    ) throws -> FakeBinary {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory.appendingPathComponent("pdftract").path
        let pidPath = directory.appendingPathComponent("pid").path

        var script = "#!/bin/sh\n"
        script += "echo $$ > '\(pidPath)'\n"
        for line in stdoutLines {
            script += "echo '\(line)'\n"
        }
        script += "sleep \(sleepSeconds)\n"
        script += "exit 0\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return FakeBinary(directory: directory, binaryPath: binaryPath, pidPath: pidPath)
    }

    /// SIGKILLs any leftover fake child and removes the temp dir. Belt and
    /// braces for failure paths: a test that fails mid-run must not leak a
    /// sleeping child into later test cases.
    private static func dispose(_ fake: FakeBinary) {
        if let pid = readPid(from: fake.pidPath) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: fake.directory)
    }

    private static func readPid(from path: String) -> Int32? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// A live child answers `kill(pid, 0)`; so does a zombie that was killed
    /// but never reaped. Only a reaped child yields ESRCH.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Polls until the fake child's pidfile exists (the spawn happened), so a
    /// regression that never spawns fails the test instead of hanging it.
    private static func waitForSpawnedPid(_ pidPath: String) async throws -> Int32 {
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(watchdogSeconds) * 20
        var ticks = 0
        while true {
            if let pid = readPid(from: pidPath) {
                return pid
            }
            if ticks >= maxTicks {
                XCTFail("fake child never spawned (no pidfile at \(pidPath))")
                return -1
            }
            try await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
    }

    /// Fails unless the child left the process table within the deadline —
    /// i.e. it was both terminated and reaped. A leaked orphan or an unreaped
    /// zombie keeps answering `kill(pid, 0)` and trips this.
    private static func assertReaped(_ pid: Int32) async throws {
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(watchdogSeconds) * 20
        var ticks = 0
        while isProcessAlive(pid) {
            if ticks >= maxTicks {
                XCTFail(
                    "child \(pid) still in the process table after \(watchdogSeconds)s "
                        + "— not terminated and reaped"
                )
                return
            }
            try await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
    }

    private struct CallOutcome {
        var returned = false
        var error: Error?
    }

    /// Handoff for the detached awaiter's outcome. An actor (not a locked
    /// struct) so the polling loop can await it without blocking a
    /// cooperative thread.
    private actor OutcomeBox {
        private var stored: CallOutcome?

        func store(_ outcome: CallOutcome) {
            guard stored == nil else { return }
            stored = outcome
        }

        var outcome: CallOutcome? { stored }
    }

    /// Awaits `task` from a detached helper and polls for its completion, so
    /// a regression that leaves the call blocked (the deadlock this suite
    /// guards against) fails an assertion instead of wedging the run.
    private static func awaitOutcome<Value>(
        of task: Task<Value, Error>
    ) async -> CallOutcome {
        let box = OutcomeBox()
        Task.detached {
            var outcome = CallOutcome()
            do {
                _ = try await task.value
            } catch {
                outcome.error = error
            }
            outcome.returned = true
            await box.store(outcome)
        }

        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(watchdogSeconds) * 20
        var ticks = 0
        while true {
            if let outcome = await box.outcome {
                return outcome
            }
            if ticks >= maxTicks {
                return CallOutcome()
            }
            try? await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
    }

    func testCancelledExtractTerminatesAndReapsChild() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [], sleepSeconds: 60)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let task = Task { try await client.extract(.path("/does/not/matter.pdf")) }
        let pid = try await Self.waitForSpawnedPid(fake.pidPath)

        task.cancel()

        // The cancelled call must return promptly with CancellationError —
        // not ride out the child's full sleep.
        let outcome = await Self.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail("cancelled extract never returned; cancellation did not reach the process")
        }
        XCTAssertTrue(
            outcome.error is CancellationError,
            "expected CancellationError, got \(String(describing: outcome.error))"
        )

        try await Self.assertReaped(pid)
    }

    func testTimedOutExtractThrowsTimeoutErrorAndReapsChild() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [], sleepSeconds: 60)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let task = Task { try await client.extract(.path("/does/not/matter.pdf"), timeout: 1.0) }
        let pid = try await Self.waitForSpawnedPid(fake.pidPath)

        let outcome = await Self.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail("timed-out extract never returned; the deadline did not reach the process")
        }
        XCTAssertTrue(
            outcome.error is TimeoutError,
            "expected TimeoutError, got \(String(describing: outcome.error))"
        )

        try await Self.assertReaped(pid)
    }

    /// Negative control for the timeout test: a child that finishes inside
    /// the budget must be unaffected by it.
    func testExtractInsideTimeoutCompletes() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.documentJSON], sleepSeconds: 0)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let doc = try await client.extract(.path("/does/not/matter.pdf"), timeout: 30.0)

        XCTAssertEqual(doc.pages.count, 1)
    }

    func testDroppedExtractStreamTerminatesAndReapsChild() async throws {
        // One page, then the child holds stdout open and sleeps — the
        // consumer drops the sequence while the child is still live.
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.pageJSON(index: 0)], sleepSeconds: 60)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)

        var sawPage = false
        for try await _ in client.extractStream(.path("/does/not/matter.pdf")) {
            sawPage = true
            break
        }
        XCTAssertTrue(sawPage, "fake child's first page never arrived")

        let pid = try XCTUnwrap(Self.readPid(from: fake.pidPath), "fake child never spawned")
        try await Self.assertReaped(pid)
    }

    func testDroppedSearchStreamTerminatesAndReapsChild() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.matchJSON(page: 0)], sleepSeconds: 60)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)

        var sawMatch = false
        for try await _ in client.search(.path("/does/not/matter.pdf"), "needle") {
            sawMatch = true
            break
        }
        XCTAssertTrue(sawMatch, "fake child's first match never arrived")

        let pid = try XCTUnwrap(Self.readPid(from: fake.pidPath), "fake child never spawned")
        try await Self.assertReaped(pid)
    }

    /// A sequence dropped before its (unstructured) producer task ever runs
    /// must not spawn a child at all — and must not trap in
    /// `Process.terminate()`'s not-launched guard, which is exactly what the
    /// old unconditional onTermination did here. No await sits between
    /// creating and dropping the stream, so termination deterministically
    /// wins the race against the launch.
    func testExtractStreamDroppedBeforeIterationSpawnsNothing() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [], sleepSeconds: 60)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)

        // Optional so the `= nil` below compiles: assigning nil is the drop,
        // and it releases the sequence right here, deterministically before
        // the sleep.
        var stream: AsyncThrowingStream<Page, Error>? = client.extractStream(.path("/does/not/matter.pdf"))
        stream = nil

        // Give any buggy late spawn ample time to show up.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fake.pidPath),
            "a stream dropped before iteration still spawned the pdftract child"
        )
    }
}
