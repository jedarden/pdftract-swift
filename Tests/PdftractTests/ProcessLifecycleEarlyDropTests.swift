//
// Streaming early-drop lifecycle: the README's "Cancellation and timeouts"
// contract (pdfswift-b64f41eb slice 2) proved by test.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as BinaryPathOverrideTests.swift and the sibling lifecycle
// suites. Keep it that way.
//
// Contract under test: dropping an `extractStream` / `search` sequence early
// — breaking out of the consuming loop, dropping it unconsumed, or cancelling
// the consuming Task — must terminate the child (SIGTERM) and reap it, and
// must never leave a caller suspended on a pipe that will not close. The
// mechanism is the sequence's `onTermination`, which the generated producer
// wires to `terminate()` + `reap()` before the child even launches (Methods.swift,
// "Lifecycle: a dropped or cancelled sequence must terminate (SIGTERM) and
// reap the child"), with a launch guard that never spawns a child for a
// sequence that is already gone. Four properties are pinned:
//
// 1. Take-then-break. Iterating until N values have arrived and then breaking
//    must end the still-sleeping child within a bounded deadline: the break
//    returns promptly, the pid leaves the process table entirely (a live
//    child OR an unreaped zombie keeps answering `kill(pid, 0)`, so only a
//    real reap satisfies the probe), and the stub's TERM marker proves the
//    SDK's onTermination — not an expiry — ended the child. Pinned for both
//    streaming spawn sites (`extractStream` and `search`), so a regeneration
//    cannot fix one producer and silently lose the other.
//
// 2. Immediate drop. Acquiring the sequence and dropping it before consuming
//    anything must leave no orphan. Two interleavings are legal and both are
//    safe: the producer task loses the race (the launch guard sees
//    stop-requested and never spawns — no pidfile ever appears), or it wins
//    it (the child exists and must be terminated and reaped by the registered
//    onTermination). The test pins whichever interleaving it observes, and
//    the pidfile branch is the tripwire for a removed guard: a child spawned
//    for a dead sequence cannot be reaped by anything and trips the watchdog.
//
// 3. No pipe wedge. A child flooding stdout far past the OS pipe buffer
//    (~64KiB on Linux) must not hold the drop path hostage: the consuming
//    Task ends within a bounded window even with the pipe saturated and
//    values actively flowing — the flood's death EOFs the producer's read,
//    so the producer cannot stay wedged on a pipe that never closes. (This
//    is the streaming twin of slice 1's buffered flood test. The flood line
//    is a decodable Page, so values genuinely flow while the pipe is
//    saturated; the drop is driven by cancelling the consuming Task — the
//    documented cancellation ending of the sequence.)
//
// 4. What a child that refuses SIGTERM gets on early drop. The sequence's
//    onTermination sends SIGTERM — exactly the README's signal — and does NOT
//    escalate to SIGKILL: the child keeps living and the dropping caller
//    keeps waiting (reap() parks in `waitUntilExit()`), the same
//    no-escalation contract slice 1 pinned for buffered calls. Once such a
//    child dies by other means, the dropping Task unblocks with
//    `CancellationError` and the child is reaped. When a regeneration adds
//    kill escalation, this test fails and forces a conscious update of the
//    pin together with the README paragraph.
//
// Everything runs against stub binaries via `Pdftract(binaryPath:)` — no
// real pdftract binary is needed and none is consulted, so the whole suite
// passes in any environment, including the CI build gate's containers. The
// stub modes, the process-table probes, and the bounded-call observation all
// live in ProcessLifecycleHarness.swift, shared with the sibling lifecycle
// suites (buffered cancellation, exec timeouts). The harness rules that keep
// its stubs reapable (fork exactly once, trap before pidfile, never park in
// `wait` across a natural death) are honored by using its modes verbatim.
//

import XCTest
@testable import Pdftract

final class ProcessLifecycleEarlyDropTests: XCTestCase {
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

    /// One NDJSON line the streaming decoder accepts as a `Page` (every
    /// `Page` field is non-optional, so every key is required).
    private static let pageNDJSON =
        #"{"page_index":0,"width":612.0,"height":792.0,"rotation":0,"spans":[],"blocks":[]}"#

    /// One NDJSON line the streaming decoder accepts as a `Match` (every
    /// `Match` field is non-optional, so every key is required).
    private static let matchNDJSON =
        #"{"text":"needle","page":0,"bbox":[1.0,2.0,3.0,4.0],"context":{"before":"a ","after":" b"}}"#

    /// How long the immediate-drop tests wait for the producer Task to lose
    /// or win the launch race before concluding "nothing spawned". Long
    /// enough for a loaded CI box to schedule the producer many times over,
    /// short enough that the pass path stays fast; a child that spawns
    /// inside the window cannot be reaped by anything and trips the
    /// watchdog in the pidfile branch.
    private static let launchRaceGraceSeconds: UInt64 = 2

    /// The bounded window the no-escalation observation runs in. Short
    /// enough to keep the suite fast, long enough that any kill escalation
    /// (which would follow the drop immediately) lands inside it. Same value
    /// as slice 1's buffered pin.
    private static let noEscalationWindowSeconds: UInt64 = 2

    /// Thread-safe counter for values the consumer collected — the loop runs
    /// on the consuming Task while the test polls the task from outside, so
    /// a plain local read back would race (the same shape as
    /// ExtractStreamConformanceTests.SkippedLineCollector).
    private final class CountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: - Take-then-break terminates and reaps the child (both streaming spawn sites)

    /// Iterates the sequence produced by `makeStream` against the stub until
    /// `take` values have arrived, then breaks. The consuming Task must
    /// return promptly (the break is a clean end, not an error), the
    /// sleeping child must be terminated AND reaped, and the TERM marker
    /// must prove the SDK's onTermination did it.
    private func assertBreakingOutReapsChild<Element: Sendable>(
        _ makeStream: @escaping (Pdftract) -> AsyncThrowingStream<Element, Error>,
        stubMode: ProcessLifecycleHarness.StubMode,
        take: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stub = track(try ProcessLifecycleHarness.writeStub(stubMode))
        let client = Pdftract(binaryPath: stub.binaryPath)
        let collected = CountBox()

        // The consumer runs on its own Task so a regression that wedges the
        // break (a drop path stuck on a pipe that never closes) reads as
        // `returned == false` instead of hanging the suite.
        let consumer = Task {
            for try await _ in makeStream(client) {
                collected.increment()
                if collected.count >= take {
                    break
                }
            }
        }

        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: consumer)
        guard outcome.returned else {
            return XCTFail(
                "\(label): breaking out of the loop never returned — the early-drop path is wedged",
                file: file,
                line: line
            )
        }
        guard outcome.error == nil else {
            return XCTFail(
                "\(label): a clean break must not throw, got \(outcome.error!)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            collected.count,
            take,
            "\(label): the loop must stop at the \(take) taken values",
            file: file,
            line: line
        )

        // Terminated AND reaped: gone from the process table within the
        // watchdog — a live child or an unreaped zombie keeps answering
        // kill(pid, 0) and trips this.
        await ProcessLifecycleHarness.assertReaped(pid, label: label, file: file, line: line)

        // The child slept far past the watchdog, and a natural exit never
        // writes the marker — its presence is the timing-independent proof
        // the SDK's onTermination delivered SIGTERM.
        XCTAssertTrue(
            ProcessLifecycleHarness.termWasDelivered(stub),
            "\(label): child was reaped but never received SIGTERM — the break did not reach the process",
            file: file,
            line: line
        )
    }

    func testBreakingOutOfExtractStreamTerminatesAndReapsChild() async throws {
        try await assertBreakingOutReapsChild(
            { client in client.extractStream(.path("/does/not/matter.pdf")) },
            // Three lines are printed so the loop can take two and still
            // break on a child that is mid-sleep, not at EOF: the break —
            // not the child's natural end — must be what ends it.
            stubMode: .sleepUntilSignaled(
                stdoutLines: [Self.pageNDJSON, Self.pageNDJSON, Self.pageNDJSON],
                sleepSeconds: 60
            ),
            take: 2,
            label: "extractStream break"
        )
    }

    func testBreakingOutOfSearchTerminatesAndReapsChild() async throws {
        try await assertBreakingOutReapsChild(
            { client in client.search(.path("/does/not/matter.pdf"), "needle") },
            stubMode: .sleepUntilSignaled(
                stdoutLines: [Self.matchNDJSON, Self.matchNDJSON, Self.matchNDJSON],
                sleepSeconds: 60
            ),
            take: 2,
            label: "search break"
        )
    }

    // MARK: - Immediate drop: no orphan from a sequence nobody consumed

    /// Drops the sequence produced by `makeStream` before consuming anything,
    /// then pins whichever launch interleaving occurred:
    ///
    /// - Producer lost the race (expected: the drop is synchronous with the
    ///   creation, so onTermination's stop request lands before the spawn):
    ///   the launch guard must have prevented the spawn entirely — no
    ///   pidfile appears within the grace window.
    /// - Producer won the race (a child exists): it must be terminated AND
    ///   reaped, with the TERM marker proving the SDK did it.
    ///
    /// The pidfile branch is the tripwire for a removed launch guard: a
    /// child spawned for a sequence that is already gone has no reaper, and
    /// the watchdog fails the test instead of leaking an orphan.
    private func assertImmediateDropLeavesNoOrphan<Element: Sendable>(
        _ makeStream: @escaping (Pdftract) -> AsyncThrowingStream<Element, Error>,
        stubMode: ProcessLifecycleHarness.StubMode,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stub = track(try ProcessLifecycleHarness.writeStub(stubMode))
        let client = Pdftract(binaryPath: stub.binaryPath)

        // Acquire and drop without consuming: the last reference dies here,
        // firing onTermination — either synchronously on an already-finished
        // continuation (the producer has not run yet) or on the live one.
        do {
            _ = makeStream(client)
        }

        var spawnedPid: Int32?
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(Self.launchRaceGraceSeconds) * 20
        var ticks = 0
        while ticks < maxTicks {
            if let pid = ProcessLifecycleHarness.readPid(from: stub.pidPath) {
                spawnedPid = pid
                break
            }
            try await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }

        if let pid = spawnedPid {
            await ProcessLifecycleHarness.assertReaped(
                pid,
                label: "\(label) (launch won the race)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                ProcessLifecycleHarness.termWasDelivered(stub),
                "\(label): the dropped sequence's child was reaped but never received SIGTERM "
                    + "— the early drop did not reach the process",
                file: file,
                line: line
            )
        } else {
            // Producer lost the race: the guard must have prevented the
            // spawn — nothing to observe, which is the pass.
        }
    }

    func testImmediateDropOfExtractStreamSpawnsNothingOrReapsSpawnedChild() async throws {
        try await assertImmediateDropLeavesNoOrphan(
            { client in client.extractStream(.path("/does/not/matter.pdf")) },
            stubMode: .sleepUntilSignaled(stdoutLines: [Self.pageNDJSON], sleepSeconds: 60),
            label: "extractStream immediate drop"
        )
    }

    func testImmediateDropOfSearchSpawnsNothingOrReapsSpawnedChild() async throws {
        try await assertImmediateDropLeavesNoOrphan(
            { client in client.search(.path("/does/not/matter.pdf"), "needle") },
            stubMode: .sleepUntilSignaled(stdoutLines: [Self.matchNDJSON], sleepSeconds: 60),
            label: "search immediate drop"
        )
    }

    // MARK: - No pipe wedge: flooding output cannot hold the drop path

    /// The stub floods stdout far past the OS pipe buffer until signalled,
    /// with a decodable line, so pages genuinely flow while the pipe is
    /// saturated. The consumer drops the sequence by cancelling its Task
    /// once at least one value has arrived. The consuming Task must still
    /// end within the bounded window with `CancellationError` — the drop
    /// path is not hostage to output nobody fully consumed — and the
    /// flooding child must be terminated and reaped. A drain regression
    /// wedges the producer on a pipe that never closes and fails here with
    /// the watchdog instead of hanging the suite.
    func testDroppedStreamCannotBeHeldHostageByFloodingChild() async throws {
        let stub = track(
            try ProcessLifecycleHarness.writeStub(.floodStdoutUntilSignaled(line: Self.pageNDJSON))
        )
        let client = Pdftract(binaryPath: stub.binaryPath)
        let collected = CountBox()

        let consumer = Task {
            for try await _ in client.extractStream(.path("/does/not/matter.pdf")) {
                collected.increment()
            }
        }

        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        // Wait until the stream is actively yielding — the drop must race a
        // live, flowing sequence, not a producer still warming up.
        let tickNanos: UInt64 = 50_000_000
        var ticks = 0
        while collected.count == 0 {
            if ticks >= Int(ProcessLifecycleHarness.watchdogSeconds) * 20 {
                return XCTFail("the flooding stream never yielded a page — producer cannot keep up with a flood")
            }
            try await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }

        // Let the flood run long enough to fill the OS pipe buffer many
        // times over before dropping — the point is to drop while the pipe
        // is saturated, not immediately after the first value.
        try await Task.sleep(nanoseconds: 300_000_000)

        consumer.cancel()

        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: consumer)
        guard outcome.returned else {
            return XCTFail(
                "the dropped stream never returned while the child flooded stdout — "
                    + "the drop path is wedged on the pipe"
            )
        }
        XCTAssertTrue(
            outcome.error is CancellationError,
            "expected CancellationError from the cancelled consumer, got \(String(describing: outcome.error))"
        )
        XCTAssertGreaterThanOrEqual(
            collected.count,
            1,
            "the stream must have been yielding before the drop"
        )

        await ProcessLifecycleHarness.assertReaped(pid, label: "flood-drop")
        XCTAssertTrue(
            ProcessLifecycleHarness.termWasDelivered(stub),
            "flooding child was reaped but never received SIGTERM — the drop did not reach the process"
        )
    }

    // MARK: - A child that refuses SIGTERM is waited for, not killed

    /// Pins today's documented semantics end to end for the stream early-drop
    /// path against a child that ignores SIGTERM (the streaming twin of
    /// slice 1's buffered pin):
    ///
    /// 1. the SDK delivers SIGTERM (the stub's marker proves delivery);
    /// 2. the SDK does NOT escalate to SIGKILL — the child is still alive
    ///    after the bounded window, and the dropping Task is still waiting
    ///    (reap() parks in `waitUntilExit()`). The README documents SIGTERM,
    ///    nothing more; when the implementation grows kill escalation, this
    ///    assertion fails and the pin and the README paragraph move together;
    /// 3. once that child dies by other means, the dropping Task unblocks
    ///    promptly with `CancellationError` — no caller is left blocked on a
    ///    dead child's pipes — and the child is reaped.
    func testSigtermIgnoringChildIsNotEscalatedOnStreamEarlyDrop() async throws {
        let stub = track(try ProcessLifecycleHarness.writeStub(.ignoreSigterm(sleepSeconds: 60)))
        let client = Pdftract(binaryPath: stub.binaryPath)

        let consumer = Task {
            var pages = 0
            for try await _ in client.extractStream(.path("/does/not/matter.pdf")) {
                pages += 1
            }
            return pages
        }

        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        // Cancelling the consumer is one of the documented sequence endings:
        // next() throws CancellationError, the iterator is dropped, and
        // onTermination terminates (SIGTERM) and reaps — reaping parks until
        // the child actually ends.
        consumer.cancel()

        let early = await ProcessLifecycleHarness.awaitOutcome(
            of: consumer,
            maxWaitSeconds: Self.noEscalationWindowSeconds
        )
        if early.returned {
            XCTFail(
                "the dropping Task finished inside the no-escalation window despite a SIGTERM-ignoring "
                    + "child (error: \(String(describing: early.error))) — the SDK terminated a child "
                    + "that refused SIGTERM, i.e. it escalated beyond the documented signal"
            )
        } else {
            XCTAssertTrue(
                ProcessLifecycleHarness.isProcessAlive(pid),
                "SIGTERM-ignoring child \(pid) is gone — the SDK escalated to a kill the README does not document"
            )
            XCTAssertTrue(
                ProcessLifecycleHarness.termWasDelivered(stub),
                "the child ignored SIGTERM and the marker was never written — SIGTERM was not delivered, "
                    + "so the SDK's termination never reached the process"
            )

            // The child dies by means the SDK did not supply (an operator's
            // kill, in production terms). The dropping Task must unblock,
            // throw CancellationError, and reap the child.
            ProcessLifecycleHarness.killStub(stub)

            let final = await ProcessLifecycleHarness.awaitOutcome(of: consumer)
            guard final.returned else {
                return XCTFail(
                    "the SIGTERM-ignoring child died but the dropping Task is still blocked on its pipes"
                )
            }
            XCTAssertTrue(
                final.error is CancellationError,
                "expected CancellationError once the child died, got \(String(describing: final.error))"
            )
            await ProcessLifecycleHarness.assertReaped(pid, label: "stream-sigterm-ignored")
        }
    }
}
