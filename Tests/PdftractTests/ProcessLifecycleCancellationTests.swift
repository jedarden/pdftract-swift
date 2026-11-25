//
// Buffered-call cancellation: the README's "Cancellation and timeouts"
// contract (pdfswift-b64f41eb slice 1) proved by test.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as BinaryPathOverrideTests.swift. Keep it that way.
//
// Contract under test (README "Cancellation and timeouts"): cancelling the
// Swift Task around a buffered call terminates the child (SIGTERM) and reaps
// it — no orphaned process, no unreaped zombie — and the call throws
// `CancellationError` instead of hanging. Three properties are pinned:
//
// 1. Termination + reap. Cancelling a call whose child is mid-sleep must end
//    that child within a bounded deadline: the call throws
//    `CancellationError`, the pid leaves the process table entirely (a live
//    child OR an unreaped zombie keeps answering `kill(pid, 0)`, so the
//    assertion is only satisfied by a real reap), and the stub's TERM marker
//    proves the SDK delivered the signal — the child could not have died of
//    anything else inside the window. Pinned for `extract`, `extractText`,
//    and `hash` — three distinct buffered methods, so a template edit cannot
//    fix one spawn site and silently lose another: they share `exec` today,
//    and these tests fail loudly if a regeneration ever forks their lifecycle
//    behavior.
//
// 2. No pipe wedge. A child that floods stdout far past the OS pipe buffer
//    (~64KiB on Linux) must not hold the cancelled caller hostage: completion
//    is bounded in time and does not depend on anyone consuming the child's
//    output. The drains run concurrently with the call, and the terminated
//    child's death EOFs them — pinning both the concurrent-drain shape and
//    the kill-and-reap that unblocks it. (A caller whose SDK waited for exit
//    before draining would wedge forever the moment 64KiB filled; this test
//    exists so that regression fails here, in the gate, not in a user's
//    process.)
//
// 3. What a child that refuses SIGTERM gets. The implementation sends
//    SIGTERM — exactly the signal the README documents — and does NOT
//    escalate to SIGKILL: a child that ignores TERM keeps living and the
//    cancelled caller keeps waiting (the README promises no orphan *once the
//    child ends*, not a forced kill of a child that declines to end). The
//    test pins today's no-escalation behavior deliberately: when a
//    regeneration adds kill escalation, this test fails and forces a
//    conscious update of the pin together with the README paragraph. It also
//    pins the other half of the contract: once such a child dies by other
//    means, the wedged caller unblocks with `CancellationError` and the child
//    is reaped — no caller is left blocked on a dead child's pipes.
//
// The suite earned its keep before it ever passed green: on swift:5.10-jammy
// (2026-11-25) five of these tests hung against the then-current SDK, and the
// diagnosis — pushed down to the Foundation level with isolated probes —
// exposed a real implementation gap, not a test artifact. posix_spawn
// inherits the launching thread's signal mask and Foundation sets no
// `POSIX_SPAWN_SETSIGMASK`; Swift concurrency's cooperative threads run with
// SIGTERM blocked; and every SDK spawn site runs on one. A cancelled call
// therefore SIGTERMed a child that could never receive the signal:
// `kill(pid, SIGTERM)` returned success while the signal sat pending in the
// child's mask (`/proc/<pid>/status` SigBlk bit 15) and the caller wedged
// until the child died of natural causes. The fix
// (`runWithDeliverableTermination` in the generated client, mirrored from
// the pdftract generator template) unblocks SIGTERM for the spawn window
// alone; these tests are its regression gate. They spawn from inside a Task
// — the same cooperative context every real caller uses — which is why the
// stubs are driven through the public buffered API and never through a
// hand-launched Process.
//
// A cancellation that races the launch is pinned too: whichever interleaving
// wins (cancel before registration, before `run()`, or after launch), the
// call must still throw `CancellationError` and never leave a spawned child
// behind — the launch-safe `SpawnedProcess` stop-request path.
//
// Everything runs against stub binaries via `Pdftract(binaryPath:)` — no
// real pdftract binary is needed and none is consulted, so the whole suite
// passes in any environment, including the CI build gate's containers. The
// stub modes, the process-table probes, and the bounded-call observation all
// live in ProcessLifecycleHarness.swift, shared with the sibling lifecycle
// suites (early-dropped streams, exec timeouts).
//

import XCTest
@testable import Pdftract

final class ProcessLifecycleCancellationTests: XCTestCase {
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
    /// a cancelled call, but it keeps the fake realistic.
    private static let documentJSON =
        #"{"schema_version":"1.0","pages":[{"page_index":0,"width":612.0,"height":792.0,"rotation":0,"spans":[],"blocks":[]}],"metadata":{"page_count":1}}"#

    /// A line long enough that the flood test passes the OS pipe buffer
    /// (~64KiB on Linux) within a fraction of a second.
    private static let floodLine = String(repeating: "flood ", count: 32) // 192 bytes

    /// The bounded window the no-escalation observation runs in. Short
    /// enough to keep the suite fast, long enough that any kill escalation
    /// (which would follow the cancel immediately) lands inside it.
    private static let noEscalationWindowSeconds: UInt64 = 2

    // MARK: - Cancellation terminates and reaps the child (buffered methods)

    private func assertCancelledCallThrowsAndReapsChild(
        _ call: (Pdftract) -> Task<Void, Error>,
        stubMode: ProcessLifecycleHarness.StubMode,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stub = track(try ProcessLifecycleHarness.writeStub(stubMode))

        let task = call(Pdftract(binaryPath: stub.binaryPath))
        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        task.cancel()

        // The cancelled call must return promptly with CancellationError —
        // not ride out the child's full sleep, and not hang on the child's
        // pipes.
        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail(
                "\(label): cancelled call never returned; cancellation did not reach the process",
                file: file,
                line: line
            )
        }
        guard let error = outcome.error else {
            return XCTFail(
                "\(label): cancelled call must throw, not return normally",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            error is CancellationError,
            "\(label): expected CancellationError, got \(error)",
            file: file,
            line: line
        )

        // Terminated AND reaped: gone from the process table within the
        // watchdog — a live child or an unreaped zombie keeps answering
        // kill(pid, 0) and trips this.
        await ProcessLifecycleHarness.assertReaped(pid, label: label, file: file, line: line)

        // The marker is the timing-independent proof the child ended via the
        // SDK's SIGTERM: the sleep cannot have expired inside the watchdog,
        // and a natural exit never writes the marker.
        XCTAssertTrue(
            ProcessLifecycleHarness.termWasDelivered(stub),
            "\(label): child was reaped but never received SIGTERM — cancellation did not reach the process",
            file: file,
            line: line
        )
    }

    func testCancelledExtractTerminatesAndReapsChild() async throws {
        try await assertCancelledCallThrowsAndReapsChild(
            { client in Task { try await client.extract(.path("/does/not/matter.pdf")) } },
            stubMode: .sleepUntilSignaled(stdoutLines: [Self.documentJSON], sleepSeconds: 60),
            label: "extract"
        )
    }

    func testCancelledExtractTextTerminatesAndReapsChild() async throws {
        try await assertCancelledCallThrowsAndReapsChild(
            { client in Task { try await client.extractText(.path("/does/not/matter.pdf")) } },
            stubMode: .sleepUntilSignaled(stdoutLines: ["stub text"], sleepSeconds: 60),
            label: "extractText"
        )
    }

    func testCancelledHashTerminatesAndReapsChild() async throws {
        try await assertCancelledCallThrowsAndReapsChild(
            { client in Task { try await client.hash(.path("/does/not/matter.pdf")) } },
            stubMode: .sleepUntilSignaled(stdoutLines: ["stub-fingerprint"], sleepSeconds: 60),
            label: "hash"
        )
    }

    // MARK: - A cancellation racing the launch still cleans up

    /// The cancel can land before the cancellation handler is registered,
    /// before `Process.run()`, or after the child exists. Whatever
    /// interleaving wins, the call must throw `CancellationError`, and a
    /// child that DID launch must still be terminated and reaped — the
    /// stop-requested-after-launch path may not strand it.
    func testCancellationRacingTheLaunchStillThrowsAndReapsAnySpawnedChild() async throws {
        let stub = track(
            try ProcessLifecycleHarness.writeStub(
                .sleepUntilSignaled(stdoutLines: [Self.documentJSON], sleepSeconds: 60)
            )
        )

        let client = Pdftract(binaryPath: stub.binaryPath)
        let task = Task { try await client.extract(.path("/does/not/matter.pdf")) }
        // Cancel before the task has had any chance to run — the launch race
        // is decided inside `exec`, not here.
        task.cancel()

        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail("a cancelled call must always return, even when the cancel raced the launch")
        }
        XCTAssertTrue(
            outcome.error is CancellationError,
            "expected CancellationError, got \(String(describing: outcome.error))"
        )

        // The safety property, whichever way the race went: if the launch won
        // (pidfile exists), that child must be terminated and reaped; if the
        // cancel won, nothing ever spawned and there is no pid to check.
        if let pid = ProcessLifecycleHarness.readPid(from: stub.pidPath) {
            await ProcessLifecycleHarness.assertReaped(pid, label: "race-won-by-launch")
            XCTAssertTrue(
                ProcessLifecycleHarness.termWasDelivered(stub),
                "launched child was reaped but never received SIGTERM — the post-launch stop-request path did not terminate it"
            )
        }
    }

    // MARK: - No pipe wedge: flooding output cannot hold the caller

    /// The stub writes far past the OS pipe buffer until signalled, and the
    /// caller never consumes a byte of it. Cancelling must still return
    /// promptly with `CancellationError`: the SDK drains concurrently while
    /// the child runs, and the terminated child's death EOFs the drains —
    /// completion is bounded in time and independent of consuming child
    /// output. (A drain regression wedges the caller the moment 64KiB fills:
    /// the child blocks on write, its trap never runs, nothing EOFs — this
    /// test fails with the watchdog instead of hanging.)
    func testCancelledCallCompletesWhileChildFloodsStdoutPastThePipeBuffer() async throws {
        let stub = track(
            try ProcessLifecycleHarness.writeStub(.floodStdoutUntilSignaled(line: Self.floodLine))
        )

        let client = Pdftract(binaryPath: stub.binaryPath)
        let task = Task { try await client.extractText(.path("/does/not/matter.pdf")) }
        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        // Let the flood run long enough to fill the OS pipe buffer many
        // times over before cancelling — the point is to cancel while the
        // pipe is saturated, not immediately after spawn.
        try await Task.sleep(nanoseconds: 300_000_000)

        task.cancel()

        let outcome = await ProcessLifecycleHarness.awaitOutcome(of: task)
        guard outcome.returned else {
            return XCTFail(
                "cancelled call never returned while the child flooded stdout — the caller is wedged on the pipe"
            )
        }
        XCTAssertTrue(
            outcome.error is CancellationError,
            "expected CancellationError, got \(String(describing: outcome.error))"
        )

        await ProcessLifecycleHarness.assertReaped(pid, label: "flood")
        XCTAssertTrue(
            ProcessLifecycleHarness.termWasDelivered(stub),
            "flooding child was reaped but never received SIGTERM — cancellation did not reach the process"
        )
    }

    // MARK: - A child that refuses SIGTERM is waited for, not killed

    /// Pins today's documented semantics end to end against a child that
    /// ignores SIGTERM:
    ///
    /// 1. the SDK delivers SIGTERM (the stub's marker proves delivery);
    /// 2. the SDK does NOT escalate to SIGKILL — the child is still alive
    ///    after the bounded window, and the cancelled caller is still
    ///    waiting. The README documents SIGTERM, nothing more; when the
    ///    implementation grows kill escalation, this assertion fails and the
    ///    pin and the README paragraph move together;
    /// 3. once that child dies by other means, the wedged caller unblocks
    ///    promptly with `CancellationError` — a caller is never left blocked
    ///    on a dead child's pipes — and the child is reaped.
    func testSigtermIgnoringChildIsNotEscalatedToKillAndCallerUnblocksWhenItDies() async throws {
        let stub = track(try ProcessLifecycleHarness.writeStub(.ignoreSigterm(sleepSeconds: 60)))

        let client = Pdftract(binaryPath: stub.binaryPath)
        let task = Task { try await client.extract(.path("/does/not/matter.pdf")) }
        let pid = try await ProcessLifecycleHarness.waitForSpawnedPid(stub)

        task.cancel()

        let early = await ProcessLifecycleHarness.awaitOutcome(
            of: task,
            maxWaitSeconds: Self.noEscalationWindowSeconds
        )
        if early.returned {
            XCTFail(
                "the call finished inside the no-escalation window despite a SIGTERM-ignoring child "
                    + "(error: \(String(describing: early.error))) — the SDK terminated a child that "
                    + "refused SIGTERM, i.e. it escalated beyond the documented signal"
            )
        } else {
            XCTAssertTrue(
                ProcessLifecycleHarness.isProcessAlive(pid),
                "SIGTERM-ignoring child \(pid) is gone — the SDK escalated to a kill the README does not document"
            )
            XCTAssertTrue(
                ProcessLifecycleHarness.termWasDelivered(stub),
                "the child ignored SIGTERM and the marker was never written — SIGTERM was not delivered, so the SDK's termination never reached the process"
            )

            // The child dies by means the SDK did not supply (an operator's
            // kill, in production terms). The wedged call must unblock,
            // throw CancellationError, and reap the child.
            ProcessLifecycleHarness.killStub(stub)

            let final = await ProcessLifecycleHarness.awaitOutcome(of: task)
            guard final.returned else {
                return XCTFail(
                    "the SIGTERM-ignoring child died but the cancelled caller is still blocked on its pipes"
                )
            }
            XCTAssertTrue(
                final.error is CancellationError,
                "expected CancellationError once the child died, got \(String(describing: final.error))"
            )
            await ProcessLifecycleHarness.assertReaped(pid, label: "sigterm-ignored")
        }
    }
}
