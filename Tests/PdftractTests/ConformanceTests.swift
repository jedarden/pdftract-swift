//
// Conformance test suite for pdftract Swift SDK
// Auto-generated - do not edit manually
//

import XCTest
@testable import Pdftract

final class ConformanceTests: XCTestCase {
    var client: Pdftract!
    var suite: [String: Any]?

    // MARK: Binary guard

    /// Resolves the pdftract binary the same way the client's PATH scan does,
    /// or throws XCTSkip when none can be resolved. Mirrors `Pdftract`'s
    /// resolution (`isExecutableFile`, not `fileExists`) so "skip" and
    /// "spawn" can never disagree about whether a binary is available.
    ///
    /// Without this guard a bare `swift test` on a machine without pdftract
    /// installed *fails* on the binary-dependent tests instead of skipping
    /// them — the reason the generated suite could only ever run under a
    /// `--filter` that excluded it. Every test below that needs the real
    /// binary throws the skip from here. The suites that drive their own
    /// fake/stub binaries (`StreamingStderrRegressionTests`,
    /// `ProcessLifecycleTests`, and any exit-code table the template emits)
    /// never call it and always run.
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
        throw XCTSkip("pdftract binary not found on PATH; the conformance tests need a real binary")
    }

    override func setUp() {
        client = Pdftract()

        let suitePath = ProcessInfo.processInfo.environment["CONFORMANCE_SUITE"] ?? "tests/sdk-conformance/cases.json"

        if let data = try? Data(contentsOf: URL(fileURLWithPath: suitePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            suite = json
        }
    }

    /// The availability smoke test: an executable named `pdftract` on PATH
    /// must actually run. The CLI registers no `--version` flag, so the probe
    /// is `--help` — the cheapest invocation every pdftract build answers
    /// with exit 0. (The `--version` probe this test once asserted exited
    /// non-zero on every real binary: clap usage error 2, "unexpected
    /// argument" — which is why the suite never passed anywhere a real
    /// binary was installed, either.)
    func testBinaryAvailable() async throws {
        let binary = try Self.requireBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--help"]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "pdftract binary at \(binary) failed --help")
    }

    func testConformance() async throws {
        guard let suite = suite,
              let cases = suite["cases"] as? [[String: Any]] else {
            throw XCTSkip("No conformance suite loaded")
        }

        // The suite file is present, so every case below would drive the
        // real binary — skip rather than fail when none can be resolved.
        _ = try Self.requireBinary()

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
        _ makeStream: @escaping () -> PdftractStream<T>,
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

    /// Pins the documented page-indexing convention for search matches: the
    /// README's search section states `match.page` is zero-based — the same
    /// convention as `Page.pageIndex` — and shows `match.page + 1` for
    /// human-readable page numbers. The fake child emits the raw wire values
    /// `page: 0,1,2`, so this assertion fails if the decode path shifts the
    /// index (a `+1` here would make the docs lie about the wire contract) or
    /// if the README and the code drift apart on the convention. Kept in sync
    /// by construction: the fake's `matchLines` emits indices, not page
    /// numbers, exactly what the wire format documents ("0-based page index;
    /// human output flips to 1-based").
    func testSearchMatchPageIsZeroBasedAsDocumented() async throws {
        let fake = try Self.writeFakeBinary(
            stdoutLines: Self.matchLines(count: 3),
            trailingStderrMarker: false,
            exitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        var pages: [Int] = []
        for try await match in client.search(.path("/does/not/matter.pdf"), "needle") {
            pages.append(match.page)
        }

        XCTAssertEqual(
            pages, [0, 1, 2],
            "Match.page must stay zero-based as documented (README: same convention as Page.pageIndex; display match.page + 1)"
        )
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
/// closes. A sequence dropped before the child even launches usually spawns
/// nothing at all; if the producer wins the launch race on a multi-core host,
/// the launched child must still leave the process table — and neither
/// interleaving may trip `Process.terminate()`'s not-launched trap.
///
/// Platform truths this suite is built around (all probe-measured on
/// swift:5.10-jammy, 2026-11-25, pdfswift-b64f41eb):
/// - `waitUntilExit()` called from a Swift-concurrency thread and parked
///   across the child's death only ever returns when something *other than
///   the direct child* fires: the expiry of an orphan the fake forked
///   (~60s for a 60s sleep, zombie in the table throughout), never a plain
///   prompt reap. A call made after the child has already exited takes a
///   fast path that always returns promptly. This is why the SDK's buffered
///   exec awaits both pipe drains (EOF = the child is gone) BEFORE reaping,
///   and why every fake in this suite leaves no orphan behind.
/// - Abandoning a streaming sequence — a `for`-loop `break`, or dropping it
///   before iterating — cannot be observed on the inner
///   `AsyncThrowingStream` at all: its producer task holds the continuation
///   (and so the stream's storage) alive for the child's whole lifetime, so
///   no deinit-driven termination can fire on it, and its `onTermination`
///   answers only cancellation and producer finish. The SDK therefore
///   returns `PdftractStream`, a class wrapper whose iterator and sequence
///   `deinit`s run the cleanup themselves (see `PdftractStream`) — break and
///   drop terminate the child through SDK-owned deinit code, cancellation
///   through the inner stream's `onTermination`. The drop tests assert the
///   properties that hold under either mechanism (caller unblocked; child
///   leaves the process table) with a short-sleep fake, and no SIGTERM
///   marker either way — on a platform where the deinit cleanup is not
///   reached the child's short natural exit still empties the table; the
///   marker teeth live on the cancellation and timeout tests, whose
///   triggers are reliable on every platform.
///
/// Each cancellation/timeout test drives a fake `pdftract` — a shell
/// script, so the process the SDK spawns (and the pidfile's `$$` records)
/// is the shell — that records its pid, prints any scripted stdout, traps
/// SIGTERM by writing a marker file and exiting 0, then sleeps far past
/// every deadline. The marker is what makes "the SDK terminated the child"
/// observable independently of timing: a natural exit never writes it, and
/// the reaping behaviors above cannot separate "terminated" from "expired"
/// inside a watchdog by liveness alone. The trapped TERM makes the shell
/// exit 0 promptly — a no-orphan natural exit, which reaps promptly — while
/// the marker proves the SDK delivered the signal. The trap also kills the
/// background sleep by its captured pid (`kill %1` does not resolve job
/// specs in a non-interactive dash trap): a trap-exited shell that left the
/// sleep orphaned is a shape this Foundation never reaps at all
/// (`waitUntilExit()` never returned; that exact fake hung the suite >19
/// min). "Reaped" stays observable as `kill(pid, 0) != 0`: a live child
/// answers the probe and so does a zombie (killed but never
/// `waitUntilExit()`-ed) — only a reaped child leaves the process table
/// entirely. Every wait is bounded by a watchdog so a revived defect fails
/// an assertion instead of hanging the suite.
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
        var markerPath: String
    }

    /// How a fake child is meant to end, which decides its script shape.
    private enum EndsBy {
        /// The SDK's SIGTERM ends it. The trap records the delivery in the
        /// marker, kills the backgrounded sleep by its `$!`-captured pid, and
        /// exits 0 promptly — the natural-exit reaping path, which is prompt.
        /// Used by the cancellation and timeout tests, whose fake must stay
        /// alive until the SDK's signal arrives; a delivered signal wakes
        /// dash's `wait` deterministically and runs the trap.
        case sigterm
        /// Nothing ever signals it: a plain FOREGROUND `sleep`, then
        /// `exit 0`. Used by the drop tests and the inside-the-deadline
        /// control, whose child must end by itself. The backgrounded shape
        /// above is deadly here: dash parks its no-argument `wait` in
        /// sigsuspend, and on this platform that park can miss a child's
        /// NATURAL death outright (probe-verified 2026-11-25,
        /// pdfswift-b64f41eb/10bba538: a `sleep 2` died on schedule while
        /// the shell sat in sigsuspend forever — the zombie was never
        /// reaped, no trap fired to break the park, the shell held the pipe
        /// write ends open, the SDK's producer blocked on a read that never
        /// EOFed, and the whole suite froze). A foreground sleep needs no
        /// wait at all — dash blocks in waitpid on the sleep, its death
        /// returns, and the shell exits; nothing here depends on signals.
        case naturalExit
    }

    /// Writes an executable fake `pdftract` that records its shell pid in a
    /// pidfile, prints `stdoutLines` on stdout, and then sleeps
    /// `sleepSeconds` — 60 in the cancellation/timeout tests (far past every
    /// deadline, so only the SDK's lifecycle machinery, not natural exit,
    /// can end it) and 2 or 0 in the naturally-ended tests (a natural exit
    /// that still lands inside the watchdog). The `endsBy` shape decides
    /// everything else — see the `EndsBy` cases. Ignores its arguments
    /// entirely, so tests can pass any `Source`.
    private static func writeFakeBinary(
        stdoutLines: [String],
        sleepSeconds: Int,
        endsBy: EndsBy
    ) throws -> FakeBinary {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory.appendingPathComponent("pdftract").path
        let pidPath = directory.appendingPathComponent("pid").path
        let markerPath = directory.appendingPathComponent("sigterm").path

        var script = "#!/bin/sh\n"
        script += "echo $$ > '\(pidPath)'\n"
        for line in stdoutLines {
            script += "echo '\(line)'\n"
        }
        switch endsBy {
        case .sigterm:
            // Harness notes — every line here earned its place as a real
            // failure mode observed on swift:5.10-jammy, 2026-11-25:
            // - The sleep is backgrounded and redirects stdout/stderr to
            //   /dev/null. This fake is a shell script, so the sleep the
            //   shell forks would otherwise outlive the killed shell while
            //   *holding the stdout/stderr pipe write ends*: the SDK's
            //   drains would block on EOF for the sleep's full budget, so a
            //   cancelled or timed-out call could not return at all (each
            //   dropped-stream test ran 60s).
            // - SLEEP_PID is captured from $! BEFORE the trap is registered,
            //   and the trap kills that pid. Two traps (both hit) on this
            //   platform: (a) a trap-exited shell that leaves an orphan
            //   behind is one Foundation never reaps — `waitUntilExit()`
            //   never returned (>19 min in-process), hanging the whole
            //   suite — so the trap must take the sleep with it and leave no
            //   orphan at all; (b) `kill %1` job specs do not resolve in a
            //   non-interactive dash trap, so the pid must be captured into
            //   a variable (tested: the `%1` variant left the sleep alive;
            //   the `$!` variant left none).
            // - The TERM trap writes the marker and exits 0 PROMPTLY, so a
            //   signal-delivered child takes the natural-exit reaping path.
            //   Without it the shell dies by signal, and Foundation on this
            //   platform completes that child's reaping only at about the
            //   child's natural-expiry moment: `waitUntilExit()` hung ~60s
            //   and the zombie sat in the process table the whole time,
            //   blowing every watchdog.
            // - `wait` is the interruptible builtin the TERM trap fires in,
            //   so the trapped TERM runs promptly (verified on the jammy
            //   image's /bin/sh: marker written, shell reaped in ~0ms, zero
            //   lingering sleeps). The no-argument `wait` is safe HERE and
            //   only here: every exit from this shape is a trapped-signal
            //   exit, and a signal wakes sigsuspend reliably. A natural
            //   death while parked in it is the wedge the `.naturalExit`
            //   shape exists to avoid.
            script += "sleep \(sleepSeconds) > /dev/null 2>&1 &\n"
            script += "SLEEP_PID=$!\n"
            script += "trap 'kill $SLEEP_PID 2>/dev/null; echo killed > \(markerPath); exit 0' TERM\n"
            script += "wait\n"
            script += "exit 0\n"
        case .naturalExit:
            // Foreground sleep, redirected away from the pipes the SDK
            // drains (the pipe write ends must die with the shell, not sit
            // with a child the shell outlives). No trap: nothing signals
            // this fake, and a trap-armed dash parked in `wait` is the
            // missed-natural-death wedge described in the `EndsBy` case
            // comment. dash waits on the foreground sleep via waitpid, so
            // the death is a plain return, not a signal delivery.
            script += "sleep \(sleepSeconds) > /dev/null 2>&1\n"
            script += "exit 0\n"
        }

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return FakeBinary(directory: directory, binaryPath: binaryPath, pidPath: pidPath, markerPath: markerPath)
    }

    /// Whether the fake child received (and trapped) SIGTERM. A natural exit
    /// never writes the marker, so this is the timing-independent proof that
    /// the SDK — not the sleep's expiry — ended the child.
    private static func markerExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
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
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.documentJSON], sleepSeconds: 60, endsBy: .sigterm)
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
        // The marker is the timing-independent proof the child ended via the
        // SDK's SIGTERM: the 60s sleep cannot have expired inside the
        // watchdog, and a natural exit never writes the marker.
        XCTAssertTrue(
            Self.markerExists(fake.markerPath),
            "child was reaped but never received SIGTERM — cancellation did not reach the process"
        )
    }

    func testTimedOutExtractThrowsTimeoutErrorAndReapsChild() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.documentJSON], sleepSeconds: 60, endsBy: .sigterm)
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
        XCTAssertTrue(
            Self.markerExists(fake.markerPath),
            "child was reaped but never received SIGTERM — the deadline did not reach the process"
        )
    }

    /// Negative control for the timeout test: a child that finishes inside
    /// the budget must be unaffected by it.
    func testExtractInsideTimeoutCompletes() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.documentJSON], sleepSeconds: 0, endsBy: .naturalExit)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)
        let doc = try await client.extract(.path("/does/not/matter.pdf"), timeout: 30.0)

        XCTAssertEqual(doc.pages.count, 1)
    }

    /// Dropping a sequence mid-iteration must leave the caller unblocked and
    /// the child's pid gone from the process table — the two properties that
    /// hold on every platform. The fake sleeps only 2s, so a child the SDK
    /// could not terminate still exits naturally (and is reaped by the
    /// producer's EOF-then-reap path) well inside the watchdog: on
    /// the child is terminated by the `PdftractStream` iterator's deinit
    /// (SDK code — see `PdftractStream` for why the cleanup cannot live on
    /// the inner `AsyncThrowingStream`: its producer task holds the
    /// continuation alive for the child's whole lifetime, so no
    /// deinit-driven termination can fire on it). The child's death EOFs the
    /// producer, whose post-EOF reap empties the process table. No SIGTERM
    /// marker is asserted here — the marker teeth live on the cancellation
    /// and timeout tests, whose triggers are reliable on every platform.
    func testDroppedExtractStreamLeavesNoChildBehind() async throws {
        // One page, then the child holds stdout open briefly — the consumer
        // drops the sequence while the child is still live.
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.pageJSON(index: 0)], sleepSeconds: 2, endsBy: .naturalExit)
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

    func testDroppedSearchStreamLeavesNoChildBehind() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [Self.matchJSON(page: 0)], sleepSeconds: 2, endsBy: .naturalExit)
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
    /// must not leave a child behind — and must not trap in
    /// `Process.terminate()`'s not-launched guard, which is exactly what the
    /// old unconditional onTermination did here. The drop usually wins the
    /// race against the launch (no await sits between creating and dropping
    /// the stream), but the producer task is unstructured: on a multi-core
    /// host it can run concurrently and launch first. That interleaving is
    /// bound by the same safety contract — the launched child must leave the
    /// process table — so the assertion is "no child left behind", not
    /// "no spawn": either the pidfile never appears, or its pid leaves the
    /// process table. (Asserting "no spawn" unconditionally was racy on
    /// multi-core containers and failed even when the SDK had correctly
    /// killed and reaped the raced launch, observed 2026-11-25.) The 2s fake
    /// keeps even the raced-launch interleaving inside the watchdog: the
    /// drop runs the `PdftractStream` sequence-deinit cleanup (see
    /// `PdftractStream`), which terminates a child that did launch; the
    /// producer's post-EOF reap then empties the process table. No SIGTERM
    /// marker is asserted here — same rationale as the dropped-stream
    /// tests.
    func testExtractStreamDroppedBeforeIterationLeavesNoChild() async throws {
        let fake = try Self.writeFakeBinary(stdoutLines: [], sleepSeconds: 2, endsBy: .naturalExit)
        defer { Self.dispose(fake) }

        let client = Pdftract(binaryPath: fake.binaryPath)

        // Optional so the `= nil` below compiles: assigning nil is the drop,
        // and it releases the sequence right here, synchronously registering
        // termination before any await.
        var stream: PdftractStream<Page>? = client.extractStream(.path("/does/not/matter.pdf"))
        stream = nil

        // Give any late spawn ample time to show up.
        try await Task.sleep(nanoseconds: 500_000_000)
        if let pid = Self.readPid(from: fake.pidPath) {
            // The producer won the launch race: the child existed, so it must
            // leave the process table (terminated where the platform can, or
            // reaped after its short natural exit where it cannot).
            try await Self.assertReaped(pid)
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fake.pidPath),
            "a stream dropped before iteration still spawned the pdftract child"
        )
    }
}
