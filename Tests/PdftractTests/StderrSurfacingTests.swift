//
// Regression tests for the README "Where the CLI's stderr goes" contract
// (Error handling section, pdfswift-d9111a58).
//
// The README promises a precise answer to "what does the caller see when the
// pdftract binary fails": every exit-code error's message IS the child's
// stderr, verbatim — no SDK-written prefix, no truncation, no reformatting,
// and no separate `stderr` field — reachable as `message`,
// `localizedDescription`, and `errorDescription` alike. Three failure kinds
// deliberately carry no CLI stderr: a spawn failure (no child ran), a
// `TimeoutError` (this SDK killed the child, so its partial stderr describes
// an interrupted run, not a reported failure and is discarded), and a
// non-zero exit with nothing on stderr (the message is the empty string).
//
// `ExitCodeMappingTests` already pins stderr *presence* on `.message` for
// every exit-code row, and `StreamingStderrRegressionTests` pins full drain
// past the pipe buffer; the assertions unique to this suite are verbatim
// equality (which fails on any prefix/suffix/trim the SDK might add), the
// `localizedDescription`/`errorDescription` accessors the README examples
// actually print, the empty-stderr edge, and the timeout discard.
//
// Hand-written, not generated: like ExitCodeMappingTests, this file is not a
// codegen template output, so `pdftract sdk codegen` leaves it alone (the
// generator only writes files that exist in templates/sdk-skeleton/swift and
// never deletes unknown ones). Keep it that way — it pins the README's
// promise to callers.
//
// The tests drive stub `pdftract` binaries that write scripted stderr and
// exit, so no real pdftract (and no fixture PDF) is needed and the whole
// contract runs in any environment — including the CI build gate.
//

import XCTest
@testable import Pdftract

final class StderrSurfacingTests: XCTestCase {
    /// Three distinct stderr lines. Exact-equality expectations (not
    /// `contains`) are the point: `mapError` must hand the child's stderr to
    /// the error untouched, so a prefix, suffix, trim, or reflow anywhere in
    /// the drain → mapError → message path fails these tests.
    private static let stderrLines = [
        "pdftract-stderr-line-alpha",
        "pdftract-stderr-line-bravo",
        "pdftract-stderr-line-charlie",
    ]

    /// What the child wrote, byte for byte: one `\n` per line, trailing
    /// newline included. The README promises verbatim carry, and verbatim
    /// means the trailing newline the child wrote survives too.
    private static let expectedStderr = stderrLines.joined(separator: "\n") + "\n"

    /// A line only the timeout stub writes; the TimeoutError message must
    /// not contain it (README: the killed child's partial stderr is
    /// discarded, and the message is the SDK's own sentence).
    private static let timeoutStderrMarker = "pdftract-timeout-partial-stderr-marker"

    /// Writes an executable stub `pdftract` that prints `stderrLines` to
    /// stderr (nothing when the list is empty — the empty-stderr case needs a
    /// child that stayed silent, not one that merely printed elsewhere) and
    /// exits with `exitCode`. Modeled on the stubs in ExitCodeMappingTests:
    /// arguments are ignored, so tests pass a nonexistent source path and no
    /// fixture PDF exists anywhere.
    private static func writeStubBinary(
        stderrLines: [String],
        exitCode: Int
    ) throws -> (directory: URL, binaryPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-stderr-surfacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        if !stderrLines.isEmpty {
            // `printf '%s\n' a b c` emits exactly one line per argument,
            // trailing newline included — no echo quirks to reason about
            // when the test asserts byte-exact equality.
            let quoted = stderrLines.map { "'\($0)'" }.joined(separator: " ")
            script += "printf '%s\\n' \(quoted) >&2\n"
        }
        script += "exit \(exitCode)\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath)
    }

    /// Writes an executable stub `pdftract` that records its shell pid in a
    /// pidfile, writes one marker line to stderr, then sleeps past the test's
    /// `timeout:` — so only the SDK's deadline machinery can end it. Mirrors
    /// the fake binaries in ProcessLifecycleTests; the pidfile lets the test
    /// SIGKILL any leftover child so a failure path can never leak a sleeper
    /// into later suites. The sleep's stdout/stderr are redirected to
    /// /dev/null: the stub is a shell script, so the shell it forks would
    /// otherwise outlive the SIGTERM-killed stub holding the stderr pipe
    /// write end — the SDK's drain would then block on EOF for the sleep's
    /// full budget before the deadline error could carry the marker. (The
    /// sleep carries no trap: this suite pins the timeout path, and the
    /// deadline's SIGTERM is what ends the stub.) The sleep is 5s — well past
    /// the 1s deadline, which still fires first (the TimeoutError plus the
    /// verbatim stderr prove the SDK ended the call); the SDK awaits the
    /// drains before reaping, so the SIGTERM-killed shell's EOF ends the call
    /// promptly at the deadline rather than at the sleep's natural expiry.
    private static func writeSleepingStubBinary() throws -> (directory: URL, binaryPath: String, pidPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-stderr-surfacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory.appendingPathComponent("pdftract").path
        let pidPath = directory.appendingPathComponent("pid").path

        var script = "#!/bin/sh\n"
        script += "echo $$ > '\(pidPath)'\n"
        script += "echo '\(timeoutStderrMarker)' >&2\n"
        script += "sleep 5 > /dev/null 2>&1\n"
        script += "exit 0\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath, pidPath)
    }

    /// SIGKILLs a leftover sleeping stub, if any. Belt and braces for the
    /// failure path: a test that fails before the SDK's deadline fired must
    /// not leave a sleeper behind.
    private static func killStub(pidPath: String) {
        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        kill(pid, SIGKILL)
    }

    // MARK: Verbatim carry on a CLI-reported failure

    /// The README's core promise, pinned through every documented accessor:
    /// catching the error the README example's `catch let error as
    /// PdftractError` binds, all three string surfaces return the child's
    /// stderr byte for byte. Exact equality (against the trailing newline
    /// included) is what makes this a verbatim pin — `ExitCodeMappingTests`'
    /// `contains` checks would tolerate an SDK-written wrapper; this cannot.
    func testCaughtErrorCarriesStderrVerbatimThroughEveryDocumentedAccessor() async throws {
        let stub = try Self.writeStubBinary(stderrLines: Self.stderrLines, exitCode: 2)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        var caught: PdftractError?
        do {
            _ = try await client.extract(.path("document.pdf"))
        } catch let error as PdftractError {
            caught = error
        } catch {
            XCTFail("exit 2 threw \(type(of: error)), which the README example's `catch let error as PdftractError` would not catch")
        }

        guard let error = caught else {
            return XCTFail("exit 2: extract returned instead of throwing")
        }
        XCTAssertTrue(error is CorruptPdfError, "exit 2 should throw CorruptPdfError, got \(type(of: error))")
        XCTAssertEqual(error.exitCode, 2)
        XCTAssertEqual(error.message, Self.expectedStderr)
        // The README examples print `localizedDescription`; the
        // `errorDescription`/LocalizedError path is what NSError bridging
        // surfaces to Objective-C callers. All three must agree — and with
        // the stderr itself, not an SDK-composed sentence around it.
        XCTAssertEqual(error.localizedDescription, Self.expectedStderr)
        XCTAssertEqual(error.errorDescription, Self.expectedStderr)
    }

    /// An unmapped exit code takes the same path through the base type: the
    /// catch-all row's error carries stderr just as verbatim as the
    /// documented subclasses do, because the carry lives in `mapError`'s
    /// argument, not in any one row.
    func testUnmappedExitCodeAlsoCarriesStderrVerbatim() async throws {
        let stub = try Self.writeStubBinary(stderrLines: Self.stderrLines, exitCode: 99)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        var caught: PdftractError?
        do {
            _ = try await client.extract(.path("document.pdf"))
        } catch let error as PdftractError {
            caught = error
        } catch {
            XCTFail("exit 99 threw \(type(of: error)), which the README example would not catch")
        }

        guard let error = caught else {
            return XCTFail("exit 99: extract returned instead of throwing")
        }
        XCTAssertTrue(
            type(of: error) == PdftractError.self,
            "exit 99 must be the plain base type, not a documented subclass, got \(type(of: error))"
        )
        XCTAssertEqual(error.exitCode, 99)
        XCTAssertEqual(error.message, Self.expectedStderr)
        XCTAssertEqual(error.localizedDescription, Self.expectedStderr)
    }

    // MARK: The empty-stderr edge

    /// A non-zero exit with nothing on stderr throws an error whose message
    /// is the empty string — the README documents this (with verify-receipt's
    /// mismatch exits as the worked example) and tells callers to render
    /// `exitCode` alongside. Pinning it here means an SDK "fix" that
    /// synthesizes a message for silent children would fail these tests
    /// until the README is changed with it: the empty message is a contract,
    /// not an accident.
    func testEmptyStderrLeavesAnEmptyMessage() async throws {
        let stub = try Self.writeStubBinary(stderrLines: [], exitCode: 2)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        var caught: PdftractError?
        do {
            _ = try await client.extract(.path("document.pdf"))
        } catch let error as PdftractError {
            caught = error
        } catch {
            XCTFail("exit 2 threw \(type(of: error)), which the README example would not catch")
        }

        guard let error = caught else {
            return XCTFail("exit 2: extract returned instead of throwing")
        }
        XCTAssertEqual(error.exitCode, 2)
        XCTAssertEqual(error.message, "", "a silent child must leave the message empty (README: empty-stderr edge)")
        XCTAssertEqual(error.localizedDescription, "")
        XCTAssertEqual(error.errorDescription, "")
    }

    // MARK: The timeout discard

    /// A timed-out call's error is the SDK's own sentence, not the child's
    /// partial stderr: the README promises the killed child's stderr is
    /// drained (to unblock the reap) and then discarded, because it describes
    /// a run this SDK interrupted rather than a failure the CLI reported.
    /// `ProcessLifecycleTests` pins that the child is reaped; this pins what
    /// the caller's caught error says — and runs in the CI gate, which skips
    /// the lifecycle suite.
    func testTimeoutErrorMessageExcludesTheChildsPartialStderr() async throws {
        let stub = try Self.writeSleepingStubBinary()
        defer {
            Self.killStub(pidPath: stub.pidPath)
            try? FileManager.default.removeItem(at: stub.directory)
        }

        let client = Pdftract(binaryPath: stub.binaryPath)

        var caught: Error?
        do {
            _ = try await client.extract(.path("document.pdf"), timeout: 1.0)
        } catch {
            caught = error
        }

        guard let timeoutError = caught as? TimeoutError else {
            return XCTFail("expected TimeoutError, got \(String(describing: caught))")
        }
        XCTAssertEqual(timeoutError.exitCode, -1, "TimeoutError carries the client-side exit code -1")
        XCTAssertTrue(
            timeoutError.message.hasPrefix("pdftract did not finish within"),
            "TimeoutError's message must be the SDK's own sentence, got: \(timeoutError.message)"
        )
        XCTAssertTrue(
            timeoutError.message.hasSuffix("and was terminated"),
            "TimeoutError's message must end with the documented sentence, got: \(timeoutError.message)"
        )
        XCTAssertFalse(
            timeoutError.message.contains(Self.timeoutStderrMarker),
            "TimeoutError leaked the killed child's partial stderr into its message: \(timeoutError.message)"
        )
    }
}
