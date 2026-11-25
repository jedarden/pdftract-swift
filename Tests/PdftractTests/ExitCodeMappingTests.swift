//
// Regression tests for the README "Error handling" section contract.
//
// The section makes two promises. First, the exit-code table: a failing
// pdftract invocation surfaces as the documented error type for each
// documented exit code (pinned by the rows below). Second, its closing note
// that some errors "come from the SDK instead" of from CLI exit codes —
// process-lifecycle failures where no CLI exit code exists to map. The
// lifecycle half is pinned here too: a `binaryPath` that cannot be spawned
// (nonexistent, or present without an execute bit) throws the SDK's own
// lifecycle error, never a mapped CLI code.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone (the generator only writes files that
// exist in templates/sdk-skeleton/swift and never deletes unknown ones). Keep
// it that way — the mapping it pins is the README's promise to callers.
//
// Committed by the pdfswift-4c6b8017 pre-flight after the authoring dispatch
// left it untracked; compile+run verified against swift:5.10.1 (the
// swift:5.10-jammy CI gate image) on 2026-09-23: `swift build`,
// `swift build --build-tests`, and all 6 tests pass. The SDK-side lifecycle
// section is the pdfswift-e83b1b91 addition (re-verified in the same image).
//

import XCTest
@testable import Pdftract

/// Pins the README error table to `Pdftract.mapError`, and the section's
/// SDK-side lifecycle errors to the `exec` spawn path.
///
/// README.md promises a precise contract: a failing pdftract invocation must
/// surface as the documented error type for each documented exit code —
/// 2 `CorruptPdfError`, 3 `EncryptionError`, 4 `SourceUnreachableError`,
/// 5 `RemoteFetchInterruptedError`, 6 `TlsError`, 10 `ReceiptVerifyError` —
/// and *any other* code as the base `PdftractError`. This repo already shipped
/// one untested-contract defect (the PascalCase naming bug) because nothing
/// compiled the package; a mapping drift would be the same class of failure
/// one level deeper, compiling cleanly while misclassifying every CLI error.
///
/// The table's rows only cover children that actually ran. A child that never
/// spawns — the configured `binaryPath` does not exist, or exists without an
/// execute bit — has no exit code to map, and is exactly where the README's
/// closing note points: the error "comes from the SDK instead". Those tests
/// live in the lifecycle section at the bottom of this class.
///
/// The tests drive a stub `pdftract` binary that writes a recognizable line to
/// stderr and exits with the code under test, so no real pdftract (and no
/// fixture PDF) is needed and the whole table runs in any environment —
/// including the CI build gate. Every API family is covered because the README
/// presents the table as "All methods ... can throw": the buffered path
/// (`extract`, `verifyReceipt`) and both streaming paths (`extractStream`,
/// `search`), the latter mapping the exit code when the stream finishes.
final class ExitCodeMappingTests: XCTestCase {
    /// Text the stub binary writes to stderr. The thrown error's message must
    /// carry it, proving the child's stderr (not an empty string) feeds the
    /// error the caller sees.
    private static func stubStderr(exitCode: Int) -> String {
        "stub pdftract failure for exit code \(exitCode)"
    }

    /// One row of the README error table, with the dynamic-type check the row
    /// promises. The documented error classes are `final`, so `is` is an exact
    /// type test for them; the base-class row needs `type(of:) ==` because
    /// `is PdftractError` would also match any subclass.
    private struct Row {
        let exitCode: Int
        let expectedTypeName: String
        let matches: (Error) -> Bool
    }

    /// The README table, plus two "other" codes pinning the catch-all row.
    private static let rows: [Row] = [
        Row(exitCode: 2, expectedTypeName: "CorruptPdfError") { $0 is CorruptPdfError },
        Row(exitCode: 3, expectedTypeName: "EncryptionError") { $0 is EncryptionError },
        Row(exitCode: 4, expectedTypeName: "SourceUnreachableError") { $0 is SourceUnreachableError },
        Row(exitCode: 5, expectedTypeName: "RemoteFetchInterruptedError") { $0 is RemoteFetchInterruptedError },
        Row(exitCode: 6, expectedTypeName: "TlsError") { $0 is TlsError },
        Row(exitCode: 10, expectedTypeName: "ReceiptVerifyError") { $0 is ReceiptVerifyError },
        // "other": the README's catch-all row. 1 is the classic generic CLI
        // failure, 99 is well outside the documented block — neither may land
        // on a documented subclass, and both must be the plain base type.
        Row(exitCode: 1, expectedTypeName: "PdftractError") { type(of: $0) == PdftractError.self },
        Row(exitCode: 99, expectedTypeName: "PdftractError") { type(of: $0) == PdftractError.self },
    ]

    /// Writes an executable stub `pdftract` that ignores its arguments, writes
    /// one line to stderr, and exits with `exitCode`. Modeled on the fake
    /// binaries in StreamingStderrRegressionTests, minus the stderr volume:
    /// the mapping tests care about *what mapError returns*, not how much
    /// stderr is captured, and a few bytes cannot revive the old pipe
    /// deadlock the regression suite guards.
    private static func writeStubBinary(exitCode: Int) throws -> (directory: URL, binaryPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-exit-code-mapping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        script += "echo '\(stubStderr(exitCode: exitCode))' >&2\n"
        script += "exit \(exitCode)\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath)
    }

    /// Asserts a thrown `error` satisfies its README row: the documented
    /// dynamic type, the row's exit code on the `PdftractError` base (the
    /// property the README example prints), and the child's stderr as the
    /// message. The source path handed to the client is intentionally a
    /// nonexistent file — the stub ignores its arguments, and if the SDK ever
    /// started statting the path itself, these tests would say so.
    private func assertRow(
        _ row: Row,
        threw error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            row.matches(error),
            "exit code \(row.exitCode) should throw \(row.expectedTypeName), got \(type(of: error)): \(error)"
        )
        guard let pdftractError = error as? PdftractError else {
            // The README example only binds through `as PdftractError`; a
            // non-subtype would break every caller that copies it.
            return XCTFail(
                "exit code \(row.exitCode) threw \(type(of: error)), which does not bind as PdftractError",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            pdftractError.exitCode,
            row.exitCode,
            "\(row.expectedTypeName) carried exit code \(pdftractError.exitCode), expected \(row.exitCode)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            pdftractError.message.contains(Self.stubStderr(exitCode: row.exitCode)),
            "\(row.expectedTypeName).message lost the child's stderr: \(pdftractError.message)",
            file: file,
            line: line
        )
    }

    /// Drains a stream to completion and returns its terminal error, failing
    /// the test if the stream finished without throwing (or without finishing,
    /// which cannot happen for a stub that exits immediately but would surface
    /// the suite timeout rather than a wedge).
    private func terminalError<T>(
        _ makeStream: () -> PdftractStream<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error? {
        var outcome: Error?
        do {
            for try await _ in makeStream() {}
        } catch {
            outcome = error
        }
        if outcome == nil {
            XCTFail("expected the stream to finish by throwing, but it completed cleanly", file: file, line: line)
        }
        return outcome
    }

    // MARK: Buffered exec path

    /// The README example, verbatim shape, for every table row: `extract`
    /// around a `do`/`catch let error as PdftractError`, asserting the bound
    /// error is the row's documented type carrying the row's exit code.
    func testExtractMapsEveryDocumentedExitCodeThroughReadmeCatch() async throws {
        for row in Self.rows {
            let stub = try Self.writeStubBinary(exitCode: row.exitCode)
            defer { try? FileManager.default.removeItem(at: stub.directory) }

            let client = Pdftract(binaryPath: stub.binaryPath)

            var caught: PdftractError?
            do {
                _ = try await client.extract(.path("document.pdf"))
            } catch let error as PdftractError {
                // The README example path: this cast is the whole contract.
                caught = error
            } catch {
                XCTFail("exit code \(row.exitCode) threw \(type(of: error)), which the README example's `catch let error as PdftractError` would not catch")
            }

            guard let error = caught else {
                return XCTFail("exit code \(row.exitCode): extract returned instead of throwing")
            }
            assertRow(row, threw: error)
        }
    }

    /// The catch-all row must stay a *catch-all*: an undocumented code must
    /// not be caught by any concrete documented type, i.e. `as CorruptPdfError`
    /// and friends must not match where the README promises plain
    /// `PdftractError`. The `type(of:) ==` check in the row pins the dynamic
    /// type; this test pins what a caller's concrete `catch` clauses see.
    func testUndocumentedExitCodesAreNotCaughtAsDocumentedSubtypes() async throws {
        for row in Self.rows where row.expectedTypeName == "PdftractError" {
            let stub = try Self.writeStubBinary(exitCode: row.exitCode)
            defer { try? FileManager.default.removeItem(at: stub.directory) }

            let client = Pdftract(binaryPath: stub.binaryPath)

            do {
                _ = try await client.extract(.path("document.pdf"))
                return XCTFail("exit code \(row.exitCode): extract returned instead of throwing")
            } catch is CorruptPdfError {
                return XCTFail("exit code \(row.exitCode) was caught as CorruptPdfError; the README catch-all must not specialize")
            } catch is EncryptionError {
                return XCTFail("exit code \(row.exitCode) was caught as EncryptionError; the README catch-all must not specialize")
            } catch is SourceUnreachableError {
                return XCTFail("exit code \(row.exitCode) was caught as SourceUnreachableError; the README catch-all must not specialize")
            } catch is RemoteFetchInterruptedError {
                return XCTFail("exit code \(row.exitCode) was caught as RemoteFetchInterruptedError; the README catch-all must not specialize")
            } catch is TlsError {
                return XCTFail("exit code \(row.exitCode) was caught as TlsError; the README catch-all must not specialize")
            } catch is ReceiptVerifyError {
                return XCTFail("exit code \(row.exitCode) was caught as ReceiptVerifyError; the README catch-all must not specialize")
            } catch let error as PdftractError {
                XCTAssertEqual(error.exitCode, row.exitCode)
            } catch {
                return XCTFail("exit code \(row.exitCode) threw \(type(of: error)), which the README example would not catch")
            }
        }
    }

    // MARK: Streaming paths

    /// `extractStream` finishes by throwing the row's documented type.
    func testExtractStreamMapsEveryDocumentedExitCode() async throws {
        for row in Self.rows {
            let stub = try Self.writeStubBinary(exitCode: row.exitCode)
            defer { try? FileManager.default.removeItem(at: stub.directory) }

            let client = Pdftract(binaryPath: stub.binaryPath)
            let error = await terminalError { client.extractStream(.path("document.pdf")) }
            guard let error else { continue }
            assertRow(row, threw: error)
        }
    }

    /// `search` finishes by throwing the row's documented type.
    func testSearchMapsEveryDocumentedExitCode() async throws {
        for row in Self.rows {
            let stub = try Self.writeStubBinary(exitCode: row.exitCode)
            defer { try? FileManager.default.removeItem(at: stub.directory) }

            let client = Pdftract(binaryPath: stub.binaryPath)
            let error = await terminalError { client.search(.path("document.pdf"), "needle") }
            guard let error else { continue }
            assertRow(row, threw: error)
        }
    }

    // MARK: Other methods named by the README ("All methods ... can throw")

    /// `verifyReceipt` maps exit 10 (its own documented row) and every other
    /// row through the same table — the mapping lives in `mapError`, not in
    /// any single method.
    func testVerifyReceiptMapsEveryDocumentedExitCode() async throws {
        for row in Self.rows {
            let stub = try Self.writeStubBinary(exitCode: row.exitCode)
            defer { try? FileManager.default.removeItem(at: stub.directory) }

            let client = Pdftract(binaryPath: stub.binaryPath)

            var caught: Error?
            do {
                _ = try await client.verifyReceipt("document.pdf", receipt: Receipt(data: "stub"))
            } catch {
                caught = error
            }

            guard let error = caught else {
                return XCTFail("exit code \(row.exitCode): verifyReceipt returned instead of throwing")
            }
            assertRow(row, threw: error)
        }
    }

    /// `extractText`, `extractMarkdown`, `getMetadata`, `hash`, and
    /// `classify` share the buffered `exec` path with `extract`; one
    /// representative row proves they route through the same table rather
    /// than re-deriving an error.
    func testRemainingBufferedMethodsShareTheMapping() async throws {
        let row = Self.rows[0] // exit 2 -> CorruptPdfError
        let stub = try Self.writeStubBinary(exitCode: row.exitCode)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        do {
            _ = try await client.extractText(.path("document.pdf"))
            return XCTFail("extractText returned instead of throwing")
        } catch {
            assertRow(row, threw: error)
        }
        do {
            _ = try await client.extractMarkdown(.path("document.pdf"))
            return XCTFail("extractMarkdown returned instead of throwing")
        } catch {
            assertRow(row, threw: error)
        }
        do {
            _ = try await client.getMetadata(.path("document.pdf"))
            return XCTFail("getMetadata returned instead of throwing")
        } catch {
            assertRow(row, threw: error)
        }
        do {
            _ = try await client.hash(.path("document.pdf"))
            return XCTFail("hash returned instead of throwing")
        } catch {
            assertRow(row, threw: error)
        }
        do {
            _ = try await client.classify(.path("document.pdf"))
            return XCTFail("classify returned instead of throwing")
        } catch {
            assertRow(row, threw: error)
        }
    }

    // MARK: SDK-side lifecycle errors (README: errors that "come from the SDK instead")

    /// The README error-handling section's closing note separates the errors
    /// the CLI itself reports (the table above, all routed through
    /// `mapError`) from lifecycle errors the SDK throws itself. The most
    /// basic lifecycle failure is a child that never spawns at all: a
    /// `binaryPath` that does not exist, or exists without an execute bit.
    /// No CLI process ran, so there is no exit code to map and nothing the
    /// CLI printed to carry — the documented contract is the SDK's
    /// client-side shape, the same one `TimeoutError` documents for its own
    /// client-side failure ("`exitCode` is `-1`, like the SDK's other
    /// client-side errors"):
    ///
    /// - the *plain base* `PdftractError` — not `TimeoutError`, which is
    ///   reserved for children that ran and were killed for time, and would
    ///   send a deadline-aware caller into an unjustified retry;
    /// - `exitCode == -1`, the client-side convention;
    /// - a message prefixed `Failed to execute pdftract:`, the SDK-owned
    ///   marker (with the underlying Foundation spawn error appended) that
    ///   distinguishes this failure from any CLI-reported stderr.
    ///
    /// The buffered `exec` path wraps the Foundation spawn error into exactly
    /// that shape; these tests pin it so a regeneration cannot silently
    /// re-throw the raw NSError (uncatchable by the README's own
    /// `catch let error as PdftractError` example) or mislabel the failure.
    private func assertSdkLifecycleError(
        _ error: Error,
        _ scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let pdftractError = error as? PdftractError else {
            // The README example only binds through `as PdftractError`; a
            // raw Foundation error would break every caller that copies it.
            return XCTFail(
                "\(scenario): threw \(type(of: error)), which the README example's `catch let error as PdftractError` would not catch",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            type(of: pdftractError) == PdftractError.self,
            "\(scenario): expected the plain base PdftractError, got \(type(of: pdftractError)) — a subclass (e.g. TimeoutError) mislabels a never-spawned child",
            file: file,
            line: line
        )
        XCTAssertEqual(
            pdftractError.exitCode,
            -1,
            "\(scenario): SDK-side lifecycle failure must carry the client-side exit code -1, got \(pdftractError.exitCode)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            pdftractError.message.hasPrefix("Failed to execute pdftract:"),
            "\(scenario): message must identify the SDK as the thrower via the 'Failed to execute pdftract:' prefix, got: \(pdftractError.message)",
            file: file,
            line: line
        )
    }

    /// `extract` around a `binaryPath` pointing at a file that does not
    /// exist. The path is randomized so a stray `pdftract` appearing at that
    /// literal location can never flip the test to a real spawn.
    func testNonexistentBinaryPathThrowsSdkLifecycleErrorOnExtract() async throws {
        let client = Pdftract(binaryPath: "/nonexistent/pdftract-\(UUID().uuidString)")

        do {
            _ = try await client.extract(.path("document.pdf"))
            return XCTFail("extract returned instead of throwing for a nonexistent binaryPath")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath")
        }
    }

    /// `extract` around a `binaryPath` pointing at an existing file with no
    /// execute bit. Root cannot exec it either — the kernel denies execve on
    /// a file with no x bit set (verified 2026-11-24 in swift:5.10-jammy, the
    /// root-user CI gate image: `chmod 644 x && ./x` → "Permission denied") —
    /// so the EACCES spawn failure this test pins holds in the gate too.
    func testNonExecutableBinaryPathThrowsSdkLifecycleErrorOnExtract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-non-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryPath = directory.appendingPathComponent("pdftract").path
        try "#!/bin/sh\necho this file must never run\n".write(
            toFile: binaryPath,
            atomically: true,
            encoding: .utf8
        )
        // 0644: readable but not executable. If the SDK ever started this
        // file, the shebang would make the failure loud instead of silent.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binaryPath)

        let client = Pdftract(binaryPath: binaryPath)

        do {
            _ = try await client.extract(.path("document.pdf"))
            return XCTFail("extract returned instead of throwing for a non-executable binaryPath")
        } catch {
            assertSdkLifecycleError(error, "non-executable binaryPath")
        }
    }

    /// Every remaining buffered method shares the single `exec` path with
    /// `extract` (`verifyReceipt` included), so one lifecycle scenario proves
    /// they all wrap a never-spawned child identically rather than letting
    /// the raw Foundation error escape per-method.
    func testRemainingBufferedMethodsShareTheSdkLifecycleError() async throws {
        let client = Pdftract(binaryPath: "/nonexistent/pdftract-\(UUID().uuidString)")

        do {
            _ = try await client.extractText(.path("document.pdf"))
            return XCTFail("extractText returned instead of throwing")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath (extractText)")
        }
        do {
            _ = try await client.extractMarkdown(.path("document.pdf"))
            return XCTFail("extractMarkdown returned instead of throwing")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath (extractMarkdown)")
        }
        do {
            _ = try await client.getMetadata(.path("document.pdf"))
            return XCTFail("getMetadata returned instead of throwing")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath (getMetadata)")
        }
        do {
            _ = try await client.hash(.path("document.pdf"))
            return XCTFail("hash returned instead of throwing")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath (hash)")
        }
        do {
            _ = try await client.classify(.path("document.pdf"))
            return XCTFail("classify returned instead of throwing")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath (classify)")
        }
        do {
            _ = try await client.verifyReceipt("document.pdf", receipt: Receipt(data: "stub"))
            return XCTFail("verifyReceipt returned instead of throwing")
        } catch {
            assertSdkLifecycleError(error, "nonexistent binaryPath (verifyReceipt)")
        }
    }
}
