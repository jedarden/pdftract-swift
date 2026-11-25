//
// Buffered-call timeout lifecycle: the README's "Cancellation and timeouts"
// contract (pdfswift-b64f41eb slice 3, pdfswift-2cd84c21) proved by test.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as BinaryPathOverrideTests.swift and the sibling lifecycle
// suites. Keep it that way.
//
// Contract under test (README "Cancellation and timeouts"): the buffered
// methods take an optional `timeout:` in seconds; on expiry the child is
// terminated (SIGTERM) and reaped and the call throws `TimeoutError`. The
// `timeout:` bounds the whole invocation from the caller's side — independent
// of the CLI-level `--timeout` flag inside the binary — and "a non-positive
// or non-finite `timeout:` throws `TimeoutError` without spawning anything."
// Four properties are pinned:
//
// 1. Deadline expiry kills and reaps. A call whose child hangs past a short
//    deadline must end that child within a bounded time: the call throws
//    `TimeoutError` (never a mapped CLI error — the child's nonzero exit
//    status after a timed-out run is the kill signal, not a failure to
//    report), the pid leaves the process table entirely (a live child OR an
//    unreaped zombie keeps answering `kill(pid, 0)`, so only a real reap
//    satisfies the probe), and the stub's TERM marker proves the SDK's
//    deadline — not the child's own expiry — ended it. Pinned for `extract`
//    and `verifyReceipt` — two distinct buffered methods, the latter the one
//    whose API docs name the `timeout:` parameter explicitly — so a
//    regeneration cannot fix one spawn site and silently lose the other:
//    they share `exec` today, and these tests fail loudly if a regeneration
//    ever forks their lifecycle behavior. (The generic `extract` shape is
//    additionally pinned by ConformanceTests'
//    `testTimedOutExtractThrowsTimeoutErrorAndReapsChild`, against this
//    suite's older private fake writer; the two suites keep each other
//    honest.)
//
// 2. Invalid timeouts never spawn. `0`, a negative value, and the
//    non-finite values (+.infinity, -.infinity, .nan) must throw
//    `TimeoutError` immediately — before any process exists. Proven
//    negatively: after the throw, no pidfile ever appears within a bounded
//    window (a spawned stub writes its pid first thing, so a validation
//    regression that reached `Process.run()` cannot hide) and the TERM
//    marker never appears (nothing was ever signalled). This also pins the
//    rejection's ordering: the guard runs before `Process` construction, so
//    the failure mode "spawn, then reject" is unobservable by construction
//    — and the test holds the implementation to it.
//
// 3. Cancellation outranks a pending deadline. Cancelling the Task while a
//    (still-unexpired) `timeout:` is pending surfaces `CancellationError` —
//    explicitly NOT `TimeoutError` — and still terminates and reaps the
//    child via the cancellation handler. The implementation checks
//    cancellation before its timed-out flag after the reap
//    (Methods.swift `exec`), so this precedence is deterministic; the test
//    pins it so a reordering that starts reporting deadline expiry for a
//    caller-cancelled call fails here.
//
// 4. Every wait is bounded. The same watchdog discipline as the sibling
//    suites: a regression that leaves the caller blocked, the child alive,
//    or the child unreaped fails an assertion instead of wedging the suite.
//
// Everything runs against stub binaries via `Pdftract(binaryPath:)` — no
// real pdftract binary is needed and none is consulted, so the whole suite
// passes in any environment, including the CI build gate's containers. The
// stub modes, the process-table probes, and the bounded-call observation all
// live in ProcessLifecycleHarness.swift, shared with the sibling lifecycle
// suites (buffered cancellation, early-dropped streams). The `.nan` case has
// one extra tooth: unvalidated, it would reach
// `Task.sleep(nanoseconds: UInt64(nan * 1e9))` and trap the process — so
// this suite failing on the `.nan` cases means the validation guard moved
// off its pre-launch position, not merely that an error type changed.
//

import XCTest
@testable import Pdftract

final class ProcessLifecycleTimeoutTests: XCTestCase {
    /// The stubs this test created, for `defer`-free cleanup in `tearDown`.
    /// Stubs are also disposed inline on the happy path; this is the net for
    /// assertions that bail early.
    private var openStubs: [ProcessLifecycleHarness.Stub] = []

    override func tearDown() {
        for stub in openStubs {
            ProcessLifecycleHarness.dispose(stub)
        }
        openStubs = []
        super.tearDown()
    }

    private func track(_ stub: ProcessLifecycleHarness.Stub) -> ProcessLifecycleHarness.Stub {
        openStubs.append(stub)
        return stub
    }

    /// Minimal valid `Document` JSON — the stub's stdout is never decoded on
    /// a timed-out or rejected call, but it keeps the fake realistic.
    private static let documentJSON =
        #"{"schema_version":"1.0","pages":[{"page_index":0,"width":612.0,"height":792.0,"rotation":0,"spans":[],"blocks":[]}],"metadata":{"page_count":1}}"#

    /// Short enough that the expiry lands well inside the harness watchdog;
    /// long enough that scheduling jitter never fires it before the spawned
    /// child is observed.
    private static let shortDeadline: TimeInterval = 1.0

    /// A deadline that cannot expire inside the watchdog — for the
    /// timeout-vs-cancel test, where the deadline must stay pending while
    /// the cancellation wins.
    private static let pendingDeadline: TimeInterval = 60.0

    /// How long the no-spawn probe watches for a pidfile before concluding
    /// nothing was spawned. A spawned stub writes its pid before anything
    /// else (the harness guarantees the trap-then-pidfile order), so any
    /// validation regression that reached `Process.run()` is visible within
    /// this window.
    private static let noSpawnWindowSeconds: UInt64 = 2

    // MARK: - Deadline expiry terminates and reaps the child

    private func assertDeadlineExpiryThrowsTimeoutErrorAndReapsChild(
        _ call: (Pdftract) -> Task<Void, Error>,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stub = track(
            try ProcessLifecycleHarness.writeStub(
                .sleepUntilSignaled(stdoutLines: [Self.documentJSON], sleepSeconds: 60)
            )
        )

        let task = call(Pdftract(binaryPath: stub.binaryPath))
        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        // The timed-out call must return promptly with TimeoutError — not
        // ride out the child's full sleep, and not hang on the child's pipes.
        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail(
                "\(label): call with a \(Self.shortDeadline)s deadline never returned; the deadline did not reach the process",
                file: file,
                line: line
            )
        }
        guard let error = outcome.error else {
            return XCTFail(
                "\(label): a call whose deadline expired must throw, not return normally",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            error is TimeoutError,
            "\(label): expected TimeoutError, got \(error)",
            file: file,
            line: line
        )

        // Terminated AND reaped: gone from the process table within the
        // watchdog — a live child or an unreaped zombie keeps answering
        // kill(pid, 0) and trips this. The stub's own trap takes its
        // background sleep along; `dispose` is the net for failure paths.
        await ProcessLifecycleHarness.assertReaped(pid, label: label, file: file, line: line)

        // The marker is the timing-independent proof the child ended via the
        // SDK's SIGTERM: the 60s sleep cannot have expired inside the
        // watchdog, and a natural exit never writes the marker.
        XCTAssertTrue(
            ProcessLifecycleHarness.termWasDelivered(stub),
            "\(label): child was reaped but never received SIGTERM — the deadline did not reach the process",
            file: file,
            line: line
        )
    }

    func testTimedOutExtractThrowsTimeoutErrorAndReapsChild() async throws {
        try await assertDeadlineExpiryThrowsTimeoutErrorAndReapsChild(
            { client in Task { try await client.extract(.path("/does/not/matter.pdf"), timeout: Self.shortDeadline) } },
            label: "extract"
        )
    }

    func testTimedOutVerifyReceiptThrowsTimeoutErrorAndReapsChild() async throws {
        try await assertDeadlineExpiryThrowsTimeoutErrorAndReapsChild(
            { client in
                Task {
                    try await client.verifyReceipt(
                        "/does/not/matter.pdf",
                        receipt: Receipt(data: "/does/not/matter.receipt.json"),
                        timeout: Self.shortDeadline
                    )
                }
            },
            label: "verifyReceipt"
        )
    }

    // MARK: - Invalid timeouts are rejected without spawning

    /// Watches the stub's pidfile for `noSpawnWindowSeconds` and fails if a
    /// pid ever appears (a spawn writes it before anything else) or the TERM
    /// marker ever appears (nothing valid was ever signalled). Runs after
    /// the rejected call has already returned, so the window measures "no
    /// spawn ever happened", not "no spawn yet".
    private func assertNothingWasEverSpawned(
        _ stub: ProcessLifecycleHarness.Stub,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(Self.noSpawnWindowSeconds) * 20
        for _ in 0..<maxTicks {
            if ProcessLifecycleHarness.readPid(from: stub.pidPath) != nil {
                XCTFail(
                    "\(label): the invalid timeout spawned a process (pidfile present) — validation did not run before launch",
                    file: file,
                    line: line
                )
                return
            }
            if ProcessLifecycleHarness.termWasDelivered(stub) {
                XCTFail(
                    "\(label): SIGTERM was delivered although no valid timeout ever launched a child",
                    file: file,
                    line: line
                )
                return
            }
            try? await Task.sleep(nanoseconds: tickNanos)
        }
    }

    private func assertInvalidTimeoutThrowsWithoutSpawning(
        _ call: (Pdftract, TimeInterval) -> Task<Void, Error>,
        timeout: TimeInterval,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stub = track(
            try ProcessLifecycleHarness.writeStub(
                .sleepUntilSignaled(stdoutLines: [Self.documentJSON], sleepSeconds: 60)
            )
        )

        let outcome = await ProcessLifecycleHarness.awaitOutcome(
            of: call(Pdftract(binaryPath: stub.binaryPath), timeout)
        )
        guard outcome.returned else {
            return XCTFail(
                "\(label): invalid timeout \(timeout) left the caller blocked — the rejection never ran",
                file: file,
                line: line
            )
        }
        guard let error = outcome.error else {
            return XCTFail(
                "\(label): invalid timeout \(timeout) must throw, not return normally",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            error is TimeoutError,
            "\(label): expected TimeoutError for invalid timeout \(timeout), got \(error)",
            file: file,
            line: line
        )
        if let timeoutError = error as? TimeoutError {
            XCTAssertEqual(
                timeoutError.exitCode, -1,
                "\(label): the client-side TimeoutError carries exit code -1",
                file: file,
                line: line
            )
        }

        await assertNothingWasEverSpawned(stub, label: label, file: file, line: line)
    }

    private static let nonPositiveTimeouts: [TimeInterval] = [0.0, -0.5]

    private static let nonFiniteTimeouts: [TimeInterval] = [.infinity, -.infinity, .nan]

    func testExtractRejectsNonPositiveTimeoutWithoutSpawning() async throws {
        for timeout in Self.nonPositiveTimeouts {
            try await assertInvalidTimeoutThrowsWithoutSpawning(
                { client, timeout in Task { try await client.extract(.path("/does/not/matter.pdf"), timeout: timeout) } },
                timeout: timeout,
                label: "extract timeout=\(timeout)"
            )
        }
    }

    func testExtractRejectsNonFiniteTimeoutWithoutSpawning() async throws {
        for timeout in Self.nonFiniteTimeouts {
            try await assertInvalidTimeoutThrowsWithoutSpawning(
                { client, timeout in Task { try await client.extract(.path("/does/not/matter.pdf"), timeout: timeout) } },
                timeout: timeout,
                label: "extract timeout=\(timeout)"
            )
        }
    }

    func testVerifyReceiptRejectsInvalidTimeoutWithoutSpawning() async throws {
        // One representative of each rejection class, through the second
        // method the README names: the validation lives in the shared `exec`,
        // and this keeps the pin on it from being extract-only.
        for timeout in [Self.nonPositiveTimeouts[0], Self.nonFiniteTimeouts[2]] {
            try await assertInvalidTimeoutThrowsWithoutSpawning(
                { client, timeout in
                    Task {
                        try await client.verifyReceipt(
                            "/does/not/matter.pdf",
                            receipt: Receipt(data: "/does/not/matter.receipt.json"),
                            timeout: timeout
                        )
                    }
                },
                timeout: timeout,
                label: "verifyReceipt timeout=\(timeout)"
            )
        }
    }

    // MARK: - Cancellation outranks a pending deadline

    /// Cancelling while a `timeout:` is still pending must surface
    /// `CancellationError` — explicitly NOT `TimeoutError` — and still
    /// terminate and reap the child. The deadline here is 60s, far past the
    /// watchdog, so it can never fire first: whatever error surfaces is the
    /// cancellation path's. Pins the implementation's precedence (the
    /// cancellation check precedes the timed-out check after the reap in
    /// `exec`), so a reordering that reports a pending deadline's expiry for
    /// a caller-cancelled call fails here.
    func testCancelWhileTimeoutPendingSurfacesCancellationErrorAndReapsChild() async throws {
        let stub = track(
            try ProcessLifecycleHarness.writeStub(
                .sleepUntilSignaled(stdoutLines: [Self.documentJSON], sleepSeconds: 60)
            )
        )

        let client = Pdftract(binaryPath: stub.binaryPath)
        let task = Task {
            try await client.extract(.path("/does/not/matter.pdf"), timeout: Self.pendingDeadline)
        }
        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        task.cancel()

        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail(
                "cancelled call with a pending deadline never returned; cancellation did not reach the process"
            )
        }
        guard let error = outcome.error else {
            return XCTFail("a cancelled call must throw, not return normally")
        }
        XCTAssertFalse(
            error is TimeoutError,
            "a caller-cancelled call surfaced TimeoutError (\(error)) — the pending deadline outranked the cancellation"
        )
        XCTAssertTrue(
            error is CancellationError,
            "expected CancellationError for a call cancelled while its deadline was pending, got \(error)"
        )

        // Terminated AND reaped: the cancellation handler's SIGTERM ended the
        // child (marker) and the operation path reaped it.
        await ProcessLifecycleHarness.assertReaped(pid, label: "cancel-vs-timeout")
        XCTAssertTrue(
            ProcessLifecycleHarness.termWasDelivered(stub),
            "child was reaped but never received SIGTERM — cancellation did not reach the process"
        )
    }
}
