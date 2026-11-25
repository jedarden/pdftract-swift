//
// Shared lifecycle test harness for the SDK's process-spawn suites.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones) — the
// same standing as BinaryPathOverrideTests.swift. Keep it that way.
//
// Built by pdfswift-10bba538 (parent pdfswift-b64f41eb, slice 1 of 3) as the
// shared harness the sibling slices reuse: slice 2 (early-dropped
// extractStream/search streams) and slice 3 (exec `timeout:` semantics) drive
// the same stub modes and the same bounded process-table assertions.
//
// What the harness provides:
//
// 1. A fake `pdftract` binary (a shell script — the process the SDK spawns,
//    and the pid its pidfile records, is the shell) written fresh per test
//    into its own temporary directory, so concurrent tests never share state.
//    Four modes cover every lifecycle scenario:
//
//    - `.sleepUntilSignaled` (default): stays alive until signalled. Only the
//      SDK's lifecycle machinery can end it, so a reap proves the SDK did it.
//    - `.printAndExit`: prints scripted stdout and exits 0 immediately — the
//      child that finishes inside a deadline.
//    - `.ignoreSigterm`: receives SIGTERM, records that it did, and keeps
//      living — the child that refuses to die.
//    - `.floodStdoutUntilSignaled`: writes continuously until signalled —
//      output that dwarfs the OS pipe buffer (~64KiB on Linux).
//
// 2. Process-table probes: the spawned pid is captured from the pidfile and
//    "terminated AND reaped" is asserted against a bounded deadline. A live
//    child answers `kill(pid, 0)` and so does a zombie (killed but never
//    `waitUntilExit()`-ed) — only a reaped child leaves the process table
//    entirely, which is exactly the strictness the README promises ("no
//    orphaned pdftract process is left behind").
//
// 3. Bounded call observation: the call under test is awaited from a
//    detached helper and polled, so a regression that leaves the caller
//    blocked (the deadlock class this harness exists to catch) fails an
//    assertion instead of wedging the whole suite.
//
// Harness notes — every shape below earned its place as a real failure mode
// observed on swift:5.10-jammy, 2026-11-25 (parent pdfswift-b64f41eb):
//
// - The child's sleep is backgrounded and redirects stdout/stderr to
//   /dev/null. The fake is a shell script, so the sleep the shell forks
//   would otherwise outlive the killed shell while *holding the stdout/stderr
//   pipe write ends*: the SDK's drains would block on EOF for the sleep's
//   full budget, so a cancelled or timed-out call could not return at all
//   (each such test ran the child's full sleep).
// - The background pid is captured from `$!` into a variable BEFORE the trap
//   is registered, and the trap kills that pid: a trap-exited shell that
//   leaves an orphan behind is one Foundation never reaps — `waitUntilExit()`
//   never returned (>19 min in-process), hanging the whole suite. Job specs
//   (`kill %1`) do not resolve in a non-interactive dash trap (tested: the
//   `%1` variant left the sleep alive; the `$!` variant left none).
// - The TERM trap exits 0 PROMPTLY, so a signal-delivered child takes the
//   natural-exit reaping path. Without it the shell dies *by signal*, and
//   Foundation on this platform completed that child's reaping only at about
//   the child's natural-expiry moment (`waitUntilExit()` hung ~60s with the
//   zombie sitting in the process table the whole time). The trap writes a
//   marker file first — a natural exit never writes it, so the marker is the
//   timing-independent proof the SDK (not the sleep's expiry) ended the
//   child.
// - `wait` is the interruptible builtin the TERM trap fires in, so the
//   trapped TERM runs promptly.
// - The TERM trap is the FIRST thing a trap-using stub does, before its
//   pidfile. Order is load-bearing: the pidfile is what the tests observe,
//   so any SDK signal that follows the test's pidfile observation can only
//   arrive once the trap is armed. With the pidfile written first, the fork
//   of the background sleep sat in the window between the pidfile and the
//   armed trap — a signal landing there killed the stub un-trapped while
//   its orphaned sleep went on holding Foundation's internal spawn-socket
//   write end, so the SDK's exit detection never fired and the caller
//   wedged for the sleep's full budget. Trap first, a stub that dies before
//   the pidfile exists has forked no children yet — nothing left behind and
//   nothing the tests can mistake for a lifecycle result.
// - A dash parked in a no-argument `wait` can MISS a child's natural death
//   on this platform outright (sigsuspend never returns; probe-verified
//   2026-11-25, pdfswift-b64f41eb/10bba538: a `sleep 2` died on schedule,
//   the trap-armed shell sat in sigsuspend forever, the zombie was never
//   reaped, the shell held the pipe write ends, the SDK's producer blocked
//   on a read that never EOFed, and the whole suite froze). No mode here
//   relies on a natural exit through `wait`: `.sleepUntilSignaled` exits
//   only via its trapped TERM (a delivered signal wakes sigsuspend
//   reliably), `.printAndExit` never reaches `wait`, `.ignoreSigterm` is
//   ended by the test's SIGKILL, and `.floodStdoutUntilSignaled` has no
//   sleep at all. Sibling slices: keep it that way — never park this
//   harness's stubs in `wait` across a natural death, and give any
//   naturally-ended stub a plain foreground sleep instead.
// - Foundation detects child exit by EOF on an internal spawn socket, and
//   EVERY forked child inherits that socket (visible as an extra fd far
//   above the redirected stdout/stderr — fd 37 in the probe). Any forked
//   child that outlives the stub keeps exit detection from firing:
//   `waitUntilExit()` parks on a dead child, the child sits unreaped as a
//   zombie, and the caller wedges. This is the single mechanism behind
//   "reaping completed only at the orphan's natural-expiry moment", the
//   >19min hangs, and the missed-natural-death wedge above (there the
//   still-alive shell was the holder). Harness rule: every stub forks at
//   most once, records that pid before anything else runs, and never
//   re-forks after its trap — killing the shell and the recorded sleep
//   (what `killStub`/`dispose` do) then kills every socket holder there
//   is. Sibling slices: the same rule applies to any stub you add.
//

import XCTest
@testable import Pdftract

/// Namespace for the shared lifecycle harness. No instances; every member is
/// static so suites call it as `ProcessLifecycleHarness.xxx`.
enum ProcessLifecycleHarness {
    /// Generous enough for a loaded CI box, short enough that a deadlock or
    /// orphan fails fast instead of hanging the suite.
    static let watchdogSeconds: UInt64 = 10

    // MARK: - Stub binary

    /// A stub executable plus its observation state.
    struct Stub {
        /// The temporary directory holding the stub and its state files.
        /// Removed by `dispose(_:)`.
        let directory: String
        /// The path to configure via `Pdftract(binaryPath:)`. Deliberately
        /// NOT named "pdftract" and on no PATH: PATH discovery scans for
        /// entries named exactly "pdftract" (see
        /// BinaryPathOverrideTests.swift), so a captured pid can only have
        /// come from the verbatim custom path.
        let binaryPath: String
        /// File the stub writes its own pid (`$$`) into at startup.
        let pidPath: String
        /// File the stub writes the pid of its background sleep into — the
        /// process `dispose(_:)` must also kill, since a shell's death does
        /// not end its backgrounded sleep.
        let sleepPidPath: String
        /// File the stub's SIGTERM trap writes before the stub stops running.
        /// A natural exit never writes it, so its existence is the
        /// timing-independent proof the SDK delivered SIGTERM.
        let termMarkerPath: String
    }

    /// How the stub binary behaves once launched.
    enum StubMode {
        /// Records its pid, prints `stdoutLines`, then sleeps `sleepSeconds`
        /// (far past every watchdog in the suites) until the SDK's SIGTERM
        /// trap ends it — the child only the SDK's lifecycle machinery can
        /// end.
        case sleepUntilSignaled(stdoutLines: [String], sleepSeconds: Int)
        /// Prints `stdoutLines` and exits 0 immediately — the child that
        /// finishes inside a deadline.
        case printAndExit(stdoutLines: [String])
        /// Records its pid and then ignores SIGTERM forever: the trap records
        /// the signal's delivery (so the test can prove the SDK sent it) but
        /// does not stop the stub. Pins what the SDK does — and does not do —
        /// against a child that refuses to die.
        case ignoreSigterm(sleepSeconds: Int)
        /// Writes ~200-byte lines on stdout in a tight loop until signalled —
        /// output that passes the OS pipe buffer (~64KiB on Linux) many times
        /// over.
        case floodStdoutUntilSignaled(line: String)
    }

    /// Writes the executable stub for `mode` into a fresh temporary directory
    /// and returns its observation state.
    static func writeStub(_ mode: StubMode) throws -> Stub {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory
            .appendingPathComponent("pdftract-under-test-\(UUID().uuidString)").path
        let pidPath = directory.appendingPathComponent("pid").path
        let sleepPidPath = directory.appendingPathComponent("sleep-pid").path
        let termMarkerPath = directory.appendingPathComponent("sigterm").path

        var script = "#!/bin/sh\n"

        switch mode {
        case .sleepUntilSignaled(let stdoutLines, let sleepSeconds):
            // Trap BEFORE the pidfile — see the harness notes at the top of
            // this file for why the order is load-bearing. At trap time
            // `$SLEEP_PID` is still unset, so a signal in the sub-microsecond
            // window before the sleep forks no-ops the kill (silenced) and
            // still writes the marker and exits.
            script += "trap 'kill $SLEEP_PID 2>/dev/null; echo killed > \(termMarkerPath); exit 0' TERM\n"
            script += "echo $$ > '\(pidPath)'\n"
            for line in stdoutLines {
                script += "echo '\(line)'\n"
            }
            // Backgrounded + /dev/null'd + pid captured from `$!` (job specs
            // do not resolve in a non-interactive dash trap).
            script += "sleep \(sleepSeconds) > /dev/null 2>&1 &\n"
            script += "SLEEP_PID=$!\n"
            script += "echo \"$SLEEP_PID\" > '\(sleepPidPath)'\n"
            script += "wait\n"
            script += "exit 0\n"

        case .printAndExit(let stdoutLines):
            script += "echo $$ > '\(pidPath)'\n"
            for line in stdoutLines {
                script += "echo '\(line)'\n"
            }
            script += "exit 0\n"

        case .ignoreSigterm(let sleepSeconds):
            // The trap records the delivery but does not stop the stub, and
            // the shell then parks in `wait` for the rest of its life: a
            // child that refuses to die while still being alive. FORK
            // EXACTLY ONCE and never loop — this is load-bearing, not
            // laziness. Foundation detects child exit by EOF on an internal
            // spawn socket, and EVERY forked child inherits that socket
            // (fd inheritance survives fork; the stdout/stderr redirects
            // below cover only themselves). A shell that re-forks after a
            // trap (a relaunching `while` loop) leaves every superseded
            // sleep alive holding the socket: the test kills the shell and
            // the one recorded pid, the superseded sleep keeps the socket
            // open, Foundation's exit detection never fires,
            // `waitUntilExit()` parks forever on a live-socket dead child,
            // and the caller wedges (probe-verified 2026-11-25: two sleeps
            // forked, killStub killed the recorded pair, the orphaned first
            // sleep held the socket 10+s, zombie shell in the table, test
            // failed). One fork, recorded before anything else can run:
            // killing the shell and that pid kills every socket holder.
            script += "trap 'echo signalled > \(termMarkerPath)' TERM\n"
            script += "echo $$ > '\(pidPath)'\n"
            script += "sleep \(sleepSeconds) > /dev/null 2>&1 &\n"
            script += "SLEEP_PID=$!\n"
            script += "echo \"$SLEEP_PID\" > '\(sleepPidPath)'\n"
            script += "wait\n"

        case .floodStdoutUntilSignaled(let line):
            // `echo` is a dash builtin, so the flood runs in the shell
            // itself: no children are forked, none can be orphaned, and the
            // shell's trap-exit EOFs the SDK's pipes immediately. A pending
            // TERM is serviced between iterations; if the write ever blocked
            // for good (a drain regression), the trap would never run and
            // the caller's bounded watchdog would fail the test.
            script += "trap 'echo killed > \(termMarkerPath); exit 0' TERM\n"
            script += "echo $$ > '\(pidPath)'\n"
            script += "while :; do echo '\(line)'; done\n"
        }

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return Stub(
            directory: directory.path,
            binaryPath: binaryPath,
            pidPath: pidPath,
            sleepPidPath: sleepPidPath,
            termMarkerPath: termMarkerPath
        )
    }

    /// SIGKILLs the stub shell and its background sleep, then removes the
    /// temporary directory. Belt and braces for failure paths: a test that
    /// fails mid-run must not leak a sleeping child into later test cases.
    static func dispose(_ stub: Stub) {
        killStub(stub)
        try? FileManager.default.removeItem(atPath: stub.directory)
    }

    /// SIGKILLs the stub shell (and its background sleep) without removing
    /// anything — for the test that must make the child die by means the SDK
    /// did not supply, then keep observing the SDK's behavior.
    static func killStub(_ stub: Stub) {
        for path in [stub.pidPath, stub.sleepPidPath] {
            if let pid = readPid(from: path) {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Process-table probes

    /// Reads the pid a stub recorded. Newline-free file, so the parse is
    /// lossless.
    static func readPid(from path: String) -> Int32? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// Whether anything answers the signal probe. A live child answers
    /// `kill(pid, 0)`, and so does a zombie that was killed but never
    /// `waitUntilExit()`-ed — only a reaped child yields ESRCH. The pid
    /// recorded by a stub can only belong to that stub within these suites'
    /// bounded windows (fresh short-lived containers), so ESRCH means reaped.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Whether the stub's SIGTERM trap has run — the timing-independent proof
    /// the SDK delivered SIGTERM (a natural exit never writes the marker).
    static func termWasDelivered(_ stub: Stub) -> Bool {
        FileManager.default.fileExists(atPath: stub.termMarkerPath)
    }

    /// Polls until the stub's pidfile exists (the spawn happened), so a
    /// regression that never spawns fails the test instead of waiting on a
    /// pid that will never appear.
    static func waitForSpawnedPid(_ stub: Stub) async throws -> Int32 {
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(watchdogSeconds) * 20
        var ticks = 0
        while true {
            if let pid = readPid(from: stub.pidPath) {
                return pid
            }
            if ticks >= maxTicks {
                XCTFail("stub never spawned (no pidfile at \(stub.pidPath))")
                return -1
            }
            try await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
    }

    /// Fails unless the child left the process table within the deadline —
    /// i.e. it was both terminated and reaped. A leaked orphan or an unreaped
    /// zombie keeps answering `kill(pid, 0)` and trips this.
    static func assertReaped(
        _ pid: Int32,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(watchdogSeconds) * 20
        var ticks = 0
        while isProcessAlive(pid) {
            if ticks >= maxTicks {
                XCTFail(
                    "\(label): child \(pid) still in the process table after "
                        + "\(watchdogSeconds)s — not terminated and reaped",
                    file: file,
                    line: line
                )
                return
            }
            try? await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
    }

    // MARK: - Bounded call observation

    /// What an awaited call did: completed (`returned`, with `error` set when
    /// it threw) or was still running when the window closed.
    struct Outcome {
        var returned = false
        var error: Error?
    }

    /// Handoff for the detached awaiter's outcome. An actor (not a locked
    /// struct) so the polling loop can await it without blocking a
    /// cooperative thread.
    private actor OutcomeBox {
        private var stored: Outcome?

        func store(_ outcome: Outcome) {
            guard stored == nil else { return }
            stored = outcome
        }

        var outcome: Outcome? { stored }
    }

    /// Awaits `task` from a detached helper and polls for its completion
    /// within `maxWaitSeconds`, so a regression that leaves the call blocked
    /// (the deadlock this harness guards against) reads as `returned == false`
    /// instead of wedging the suite. The detached awaiter keeps awaiting the
    /// task after the window closes either way, so a caller that completes
    /// late is still drained rather than leaked.
    static func awaitOutcome<Value>(
        of task: Task<Value, Error>,
        maxWaitSeconds: UInt64 = watchdogSeconds
    ) async -> Outcome {
        let box = OutcomeBox()
        Task.detached {
            var outcome = Outcome()
            do {
                _ = try await task.value
            } catch {
                outcome.error = error
            }
            outcome.returned = true
            await box.store(outcome)
        }

        let tickNanos: UInt64 = 50_000_000
        let maxTicks = Int(maxWaitSeconds) * 20
        var ticks = 0
        while true {
            if let outcome = await box.outcome {
                return outcome
            }
            if ticks >= maxTicks {
                return Outcome()
            }
            try? await Task.sleep(nanoseconds: tickNanos)
            ticks += 1
        }
        // `awaiter` is deliberately not awaited here: this poll returns the
        // moment the outcome lands (the box holds it), and on a timeout the
        // detached awaiter must keep draining the still-running call so no
        // child-facing state outlives the test's interest in it.
    }
}
