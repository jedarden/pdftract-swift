//
// Passthrough tests for the `verifyReceipt` argument path — the invocation
// shape README.md documents in "Verify receipt" (pdfswift-e7f9930c). That
// section states three facts a caller could otherwise only learn from
// Methods.swift: `Receipt(data:)` must be the path of a receipt JSON file and
// reaches the CLI verbatim as the `verify-receipt` `RECEIPT.json` positional
// argument, the call runs in `--json` mode, and a failed verification throws
// rather than returning a `valid == false` result — the CLI's structured
// failure report on stdout is discarded when the SDK maps the non-zero exit.
//
// Hand-written, not generated: this file is not a codegen template output, so
// `pdftract sdk codegen` leaves it alone — the same standing as
// ExitCodeMappingTests.swift and SourceBytesPassthroughTests.swift. Keep it
// that way.
//
// What is pinned:
//
//   1. Argv. `verifyReceipt("doc.pdf", receipt: Receipt(data: p))` spawns
//      exactly ["verify-receipt", "doc.pdf", p, "--json"] — the receipt
//      string is neither spilled to a temporary file (contrast Source.bytes,
//      which always spills) nor re-encoded: an absolute path with a space and
//      a relative path both arrive byte-for-byte. A regeneration that moved
//      to the CLI's `--inline` form, reordered the positional arguments, or
//      dropped `--json` (the structured decode behind ReceiptVerificationResult)
//      fails here loudly instead of silently changing what the call means.
//   2. Success decode. The CLI's success JSON — `error` key absent, as its
//      serializer skips it on "ok" — decodes to `valid == true`, `reason ==
//      nil`, and the IoU/hash fields, i.e. the README's "a returned result is
//      always `valid`" promise holds for the only shape the CLI emits on the
//      success path.
//   3. Failure shape. A mismatch JSON on stdout with exit 10 surfaces as a
//      thrown `ReceiptVerifyError`, never a decoded result — pinning that the
//      failure report is discarded (README's "call the CLI directly when you
//      need the per-check detail").
//
// Exit-code → error-type mapping for every documented row is
// ExitCodeMappingTests' `testVerifyReceiptMapsEveryDocumentedExitCode`; this
// file does not re-drive that table, only the argv shape and the two decode
// outcomes the README section asserts.
//
// No real pdftract binary is needed and none is consulted: the stub answers
// for it, so the whole suite runs in any environment, including the CI build
// gate's containers.
//

import XCTest
@testable import Pdftract

final class ReceiptArgvPassthroughTests: XCTestCase {
    // MARK: Fixture

    /// The CLI's `verify-receipt --json` success output: `error` omitted —
    /// its serializer `skip_serializing_if`s it on the ok path, and the
    /// decoder maps that absence to `reason == nil`.
    private static let successJSON =
        #"{"status":"ok","pdf_fingerprint":"pdftract-v1:abc123","page_index":14,"best_iou":0.97,"expected_content_hash":"sha256:9b21","actual_content_hash":"sha256:9b21"}"#

    /// The CLI's fingerprint-mismatch JSON: same schema plus `error`, printed
    /// to stdout before the non-zero exit. The SDK must throw rather than
    /// decode it into a returned result.
    private static let mismatchJSON =
        #"{"status":"fingerprint_mismatch","pdf_fingerprint":"pdftract-v1:def456","page_index":14,"best_iou":0.0,"expected_content_hash":"pdftract-v1:abc123","actual_content_hash":"pdftract-v1:def456","error":"Expected fingerprint pdftract-v1:abc123, got pdftract-v1:def456"}"#

    // MARK: Argv-capturing stub (SourceBytesPassthroughTests pattern)

    /// Writes an executable stub `pdftract` that records its argv one argument
    /// per line into `<directory>/captured-argv.txt`, prints `stdout`, and
    /// exits with `exitCode`. The capture path is baked into this stub
    /// instance, so concurrent tests never share capture state.
    private static func writeArgCapturingStub(
        stdout: String,
        exitCode: Int = 0
    ) throws -> (directory: URL, binaryPath: String, capturePath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftract-receipt-passthrough-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let captureURL = directory.appendingPathComponent("captured-argv.txt")
        let binaryPath = directory.appendingPathComponent("pdftract").path

        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > '\(captureURL.path)'\n"
        // Quoted delimiter: stdout must pass through untouched.
        script += "cat <<'PDFTRACT_STUB_EOF'\n\(stdout)\nPDFTRACT_STUB_EOF\n"
        script += "exit \(exitCode)\n"

        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        return (directory, binaryPath, captureURL.path)
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

    // MARK: Argv shape — the README's path contract

    /// The receipt string reaches the child verbatim as the third argument —
    /// the `RECEIPT.json` positional — after the PDF path and before `--json`.
    /// Absolute-with-space and relative paths pin no-mangling and no-spill:
    /// unlike `Source.bytes`, nothing about a receipt is written to disk by
    /// the SDK, and `--inline`/stdin are not used.
    func testVerifyReceiptPassesReceiptPathVerbatim() async throws {
        for receiptPath in ["/tmp/receipt dir/span-14.receipt.json", "receipts/valid.receipt.json"] {
            let stub = try Self.writeArgCapturingStub(stdout: Self.successJSON)
            defer { try? FileManager.default.removeItem(at: stub.directory) }

            let client = Pdftract(binaryPath: stub.binaryPath)
            _ = try await client.verifyReceipt("doc.pdf", receipt: Receipt(data: receiptPath))

            XCTAssertEqual(
                try Self.capturedArguments(from: stub.capturePath),
                ["verify-receipt", "doc.pdf", receiptPath, "--json"],
                "receipt \(receiptPath) must reach the CLI verbatim as the RECEIPT.json positional"
            )
        }
    }

    // MARK: Success decode — "a returned result is always `valid`"

    /// The success shape decodes with `valid == true`, `reason == nil`, and
    /// the mapped IoU/hash fields — the only return shape the CLI's ok exit
    /// can produce.
    func testSuccessJSONDecodesValidResult() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.successJSON)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)
        let result = try await client.verifyReceipt("doc.pdf", receipt: Receipt(data: "/tmp/r.json"))

        XCTAssertTrue(result.valid)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.bestIou, 0.97, accuracy: 1e-12)
        XCTAssertEqual(result.expectedContentHash, "sha256:9b21")
        XCTAssertEqual(result.actualContentHash, "sha256:9b21")
    }

    // MARK: Failure shape — "every failed verification throws"

    /// Mismatch JSON on stdout plus exit 10 throws `ReceiptVerifyError` — the
    /// structured failure report is discarded, never decoded into a returned
    /// `valid == false` result.
    func testMismatchJSONWithExit10ThrowsInsteadOfReturning() async throws {
        let stub = try Self.writeArgCapturingStub(stdout: Self.mismatchJSON, exitCode: 10)
        defer { try? FileManager.default.removeItem(at: stub.directory) }

        let client = Pdftract(binaryPath: stub.binaryPath)

        do {
            _ = try await client.verifyReceipt("doc.pdf", receipt: Receipt(data: "/tmp/r.json"))
            XCTFail("exit 10 with mismatch JSON: verifyReceipt returned instead of throwing")
        } catch let error as ReceiptVerifyError {
            XCTAssertEqual(error.exitCode, 10)
        }
    }
}
