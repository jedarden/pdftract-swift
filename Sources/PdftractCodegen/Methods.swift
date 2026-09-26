//
// This file is auto-generated. Do not edit manually.
//

#if os(Linux)
import Foundation
#else
import Foundation
#endif

/// Main Pdftract client for extracting data from PDFs.
/// Uses the bundled pdftract binary via Process spawning.
public struct Pdftract {
    private let binaryPath: String

    /// Creates a new Pdftract client.
    /// - Parameter binaryPath: Path to the pdftract binary. If nil, searches PATH.
    public init(binaryPath: String? = nil) {
        if let binaryPath = binaryPath {
            self.binaryPath = binaryPath
        } else {
            // Resolve pdftract on PATH (cached for the process lifetime).
            self.binaryPath = Self.resolvedBinaryPath ?? "pdftract"
        }
    }

    /// Resolved pdftract binary path, scanned from PATH exactly once and cached
    /// for the lifetime of the process. PATH does not change mid-process for
    /// typical server-side use, so the scan runs a single time and its result
    /// (including "not found") is reused across every instance rather than
    /// re-statting each PATH entry on every `init`. `static let` initialization
    /// is atomically lazy in Swift, so the lookup is also thread-safe.
    private static let resolvedBinaryPath: String? = {
        #if os(Linux)
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = envPath.split(separator: ":")
        #else
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = envPath.split(separator: ";")
        #endif

        for path in paths {
            let binaryPath = NSString.path(withComponents: [String(path), "pdftract"])
            // isExecutableFile (not fileExists) so a non-executable file with the
            // right name on PATH is not selected only to fail confusingly at exec().
            if FileManager.default.isExecutableFile(atPath: binaryPath) {
                return binaryPath
            }
        }
        return nil
    }()

    /// Executes the pdftract binary with the given arguments.
    /// - Parameters:
    ///   - args: Command-line arguments to pass.
    ///   - timeout: Maximum seconds to let the child run. On expiry the child
    ///     is terminated (SIGTERM) and reaped, and `TimeoutError` is thrown.
    ///     `nil` (the default) waits indefinitely.
    /// - Returns: The stdout output as a String.
    /// - Throws: `PdftractError` if the process fails, `TimeoutError` when the
    ///   deadline expires, `CancellationError` if the surrounding Task is
    ///   cancelled (the child is terminated and reaped either way).
    private func exec(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
        if let timeout {
            guard timeout > 0, timeout.isFinite else {
                throw TimeoutError("timeout must be a finite number of seconds > 0, got \(timeout)", -1)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.arguments = args

        let spawned = SpawnedProcess()

        do {
            return try await withTaskCancellationHandler {
                guard !Task.isCancelled else { throw CancellationError() }

                try process.run()
                spawned.didLaunch(process)

                // A cancellation that landed between handler registration and
                // launch was a launch-safe no-op inside the handler. Honor it
                // now so a cancelled caller never leaves the child running.
                if spawned.isStopRequested() {
                    spawned.terminate()
                }

                // Deadline watchdog: sleeps out the budget, then terminates the
                // child — which is exactly what unblocks the reap below. It is
                // cancelled with the run, so a child that finishes in time
                // never pays for the timer. Clamped to what UInt64 nanoseconds
                // can express; anything past ~292 years is "forever" anyway.
                let timeoutTask: Task<Void, Never>? = timeout.map { deadline in
                    Task {
                        let clamped = min(deadline, Double(Int64.max) / 1_000_000_000)
                        try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        spawned.deadlineFired()
                    }
                }
                defer { timeoutTask?.cancel() }

                // Drain stdout/stderr concurrently while the process runs.
                // Reading them only after waitUntilExit() deadlocks on large
                // output: once the OS pipe buffer (~64KB on Linux) fills, the
                // child blocks on write() while we block waiting for it to
                // exit. Mirrors the streaming methods' concurrent reads. On
                // the cancellation/timeout paths the terminated child's death
                // EOFs both drains, so awaiting them cannot block.
                let stdoutTask = Task { outPipe.fileHandleForReading.readDataToEndOfFile() }
                let stderrTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }

                // Blocks only until the child exits — naturally, or promptly
                // once cancellation/timeout has terminated it — and reaps the
                // child exactly once.
                spawned.reap()

                let outData = await stdoutTask.value
                let errData = await stderrTask.value

                // Order matters: a cancelled or timed-out run was killed by
                // this SDK, so its nonzero exit status is the kill signal, not
                // a CLI error to map.
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
                if spawned.isTimedOut() {
                    throw TimeoutError(
                        "pdftract did not finish within \(timeout ?? 0) seconds and was terminated",
                        -1
                    )
                }

                let output = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    throw mapError(stderr, Int(process.terminationStatus))
                }

                return output
            } onCancel: {
                // Launch-safe: SIGTERMs the child if (and only if) it is live.
                // Reaping happens on the operation path, which the kill
                // unblocks; a cancelled call still runs to its throw, so no
                // zombie is left behind.
                spawned.terminate()
            }
        } catch let error as PdftractError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw PdftractError("Failed to execute pdftract: \(error.localizedDescription)", -1)
        }
    }

    /// Maps CLI exit codes to Swift errors.
    /// - Parameters:
    ///   - stderr: The stderr output from the process.
    ///   - exitCode: The exit code.
    /// - Returns: A `PdftractError` subclass.
    private func mapError(_ stderr: String, _ exitCode: Int) -> PdftractError {
        switch exitCode {
        
        
        case 2:
            return CorruptPdfError(stderr, exitCode)
        
        
        
        case 3:
            return EncryptionError(stderr, exitCode)
        
        
        
        case 4:
            return SourceUnreachableError(stderr, exitCode)
        
        
        
        case 5:
            return RemoteFetchInterruptedError(stderr, exitCode)
        
        
        
        case 6:
            return TlsError(stderr, exitCode)
        
        
        
        case 10:
            return ReceiptVerifyError(stderr, exitCode)
        
        
        default:
            return PdftractError(stderr, exitCode)
        }
    }

    
    
    /// Extracts structured data from a PDF.
    /// - Parameters:
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Extraction options.
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Returns: The complete document structure.
    /// - Throws: `PdftractError` if extraction fails, `TimeoutError` on
    ///   deadline expiry, `CancellationError` if the Task is cancelled.
    public func extract(
        _ source: Source,
        options: ExtractOptions = ExtractOptions(),
        timeout: TimeInterval? = nil
    ) async throws -> Document {
        var args = ["extract", "--json"]
        let prepared = try source.toArgs()
        defer { prepared.cleanUp() }
        args.append(contentsOf: prepared.arguments)
        args.append(contentsOf: options.toArgs())

        let output = try await exec(args, timeout: timeout)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Document.self, from: data)
    }

    
    
    
    
    /// Extracts plain text from a PDF.
    
    /// - Parameters:
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Extraction options.
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Returns: The extracted text.
    /// - Throws: `PdftractError` if extraction fails, `TimeoutError` on
    ///   deadline expiry, `CancellationError` if the Task is cancelled.
    public func extractText(
        _ source: Source,
        options: ExtractOptions = ExtractOptions(),
        timeout: TimeInterval? = nil
    ) async throws -> String {
        var args = ["extract"]
        let prepared = try source.toArgs()
        defer { prepared.cleanUp() }
        args.append(contentsOf: prepared.arguments)
        args.append(contentsOf: options.toArgs())
        
        args.append("--text")
        
        args.append("--json")

        let output = try await exec(args, timeout: timeout)

        // Parse JSON to verify it's valid, then extract the text field
        guard let data = output.data(using: .utf8),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else {
            throw PdftractError("Failed to decode JSON output", -1)
        }

        // Return concatenated page text
        return doc.pages.map { page in
            page.blocks.map { $0.text }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    
    
    
    
    /// Extracts Markdown-formatted text from a PDF.
    
    /// - Parameters:
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Extraction options.
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Returns: The extracted text.
    /// - Throws: `PdftractError` if extraction fails, `TimeoutError` on
    ///   deadline expiry, `CancellationError` if the Task is cancelled.
    public func extractMarkdown(
        _ source: Source,
        options: ExtractOptions = ExtractOptions(),
        timeout: TimeInterval? = nil
    ) async throws -> String {
        var args = ["extract"]
        let prepared = try source.toArgs()
        defer { prepared.cleanUp() }
        args.append(contentsOf: prepared.arguments)
        args.append(contentsOf: options.toArgs())
        
        args.append("--md")
        
        args.append("--json")

        let output = try await exec(args, timeout: timeout)

        // Parse JSON to verify it's valid, then extract the text field
        guard let data = output.data(using: .utf8),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else {
            throw PdftractError("Failed to decode JSON output", -1)
        }

        // Return concatenated page text
        return doc.pages.map { page in
            page.blocks.map { $0.text }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    
    
    
    /// Extracts pages from a PDF as an async stream.
    /// - Parameters:
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Extraction options.
    ///   - onSkippedLine: Called once per NDJSON line that failed to decode. Without
    ///     this the dropped line is lost silently — indistinguishable from a PDF that
    ///     simply had fewer pages. Default `nil`.
    /// - Returns: An `AsyncThrowingStream` that yields `Page` values.
    /// - Throws: `PdftractError` if extraction fails.
    public func extractStream(
        _ source: Source,
        options: ExtractOptions = ExtractOptions(),
        onSkippedLine: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncThrowingStream<Page, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                var args = ["extract", "--ndjson"]
                let prepared: PreparedArgs
                do {
                    prepared = try source.toArgs()
                    args.append(contentsOf: prepared.arguments)
                    args.append(contentsOf: options.toArgs())
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                // Remove any spilled temp file (e.g. Source.bytes) once the
                // process has finished — covers success, error, and the
                // cancellation path (onTermination terminates then exits).
                defer { prepared.cleanUp() }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.arguments = args

                // Lifecycle: a dropped or cancelled sequence must terminate
                // (SIGTERM) and reap the child. onTermination fires for every
                // ending — cancellation, break-out-of-the-loop, or normal
                // completion — and can fire before the spawn below even runs
                // (the producer lives in this unstructured Task) or after the
                // child already exited on its own. terminate() is launch-safe
                // and reap() idempotent, so this is correct in every
                // interleaving; the old unconditional
                // terminate()/waitUntilExit() pair trapped in both of those
                // races.
                let spawned = SpawnedProcess()
                continuation.onTermination = { @Sendable _ in
                    spawned.terminate()
                    spawned.reap()
                }

                do {
                    // The sequence may have been dropped before this task got
                    // to run. Never launch a child for a sequence that is
                    // already gone — that is the "dropped call leaves an
                    // orphaned pdftract process" failure mode.
                    guard !spawned.isStopRequested() else { return }

                    try process.run()
                    spawned.didLaunch(process)

                    // A termination that landed between registration and the
                    // launch was a launch-safe no-op above. Honor it now
                    // instead of streaming a dead sequence's child to
                    // completion.
                    if spawned.isStopRequested() {
                        spawned.terminate()
                    }

                    let outHandle = outPipe.fileHandleForReading

                    // Drain stderr concurrently with stdout. Reading stderr
                    // only after waitUntilExit() deadlocks once the child
                    // writes more than the OS pipe buffer (~64KB on Linux):
                    // the child blocks in write(stderr) while this task blocks
                    // on stdout, so neither side ever finishes. Mirrors the
                    // buffered exec path, which drains both pipes this way.
                    let stderrTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }

                    // Read lines incrementally. Loop to EOF rather than while
                    // `process.isRunning`: a child that exits between two reads
                    // can still leave buffered stdout behind, and EOF is the
                    // only signal that stdout is fully drained. When the
                    // sequence is dropped, onTermination's terminate() EOFs
                    // this read — the drop cannot leave the producer wedged on
                    // a pipe that never closes.
                    var buffer = [UInt8]()
                    let readSize = 4096

                    while true {
                        let data = outHandle.readData(ofLength: readSize)
                        if data.isEmpty {
                            break
                        }

                        buffer.append(contentsOf: data)

                        // Process complete lines
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = Data(buffer[..<newlineIndex])
                            buffer.removeSubrange(0...newlineIndex)

                            if let lineString = String(data: lineData, encoding: .utf8), !lineString.isEmpty {
                                do {
                                    let page = try JSONDecoder().decode(Page.self, from: lineData)
                                    continuation.yield(page)
                                } catch {
                                    // Surface undecodable lines via onSkippedLine instead of
                                    // swallowing them — silent drops mask truncation/CLI/schema drift.
                                    if let onSkippedLine { onSkippedLine(error) }
                                }
                            }
                        }
                    }

                    // Process remaining buffer
                    if !buffer.isEmpty {
                        if let lineString = String(bytes: buffer, encoding: .utf8), !lineString.isEmpty {
                            do {
                                let page = try JSONDecoder().decode(Page.self, from: Data(buffer))
                                continuation.yield(page)
                            } catch {
                                // Surface undecodable lines via onSkippedLine instead of
                                // swallowing them — silent drops mask truncation/CLI/schema drift.
                                if let onSkippedLine { onSkippedLine(error) }
                            }
                        }
                    }

                    // Reaps the child exactly once; a no-op if onTermination
                    // already reaped it after killing the child mid-read.
                    spawned.reap()

                    // The child has exited, so the concurrent drain above has
                    // hit EOF and awaiting it cannot block. It must be complete
                    // before mapError so the error carries all of stderr rather
                    // than whatever happened to fit in the pipe buffer.
                    let errData = await stderrTask.value
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.finish(throwing: mapError(stderr, Int(process.terminationStatus)))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    
    
    
    /// Searches for text in a PDF.
    /// - Parameters:
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - pattern: The text pattern to search for.
    ///   - options: Search options.
    ///   - onSkippedLine: Called once per NDJSON line that failed to decode. Without
    ///     this the dropped line is lost silently — indistinguishable from output that
    ///     simply had fewer matches. Default `nil`.
    /// - Returns: An `AsyncThrowingStream` that yields `Match` values.
    /// - Throws: `PdftractError` if search fails.
    public func search(
        _ source: Source,
        _ pattern: String,
        options: SearchOptions = SearchOptions(),
        onSkippedLine: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncThrowingStream<Match, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                var args = ["grep", pattern]
                let prepared: PreparedArgs
                do {
                    prepared = try source.toArgs()
                    args.append(contentsOf: prepared.arguments)
                    args.append(contentsOf: options.toArgs())
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                defer { prepared.cleanUp() }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.arguments = args

                // Lifecycle: a dropped or cancelled sequence must terminate
                // (SIGTERM) and reap the child. onTermination fires for every
                // ending — cancellation, break-out-of-the-loop, or normal
                // completion — and can fire before the spawn below even runs
                // (the producer lives in this unstructured Task) or after the
                // child already exited on its own. terminate() is launch-safe
                // and reap() idempotent, so this is correct in every
                // interleaving; the old unconditional
                // terminate()/waitUntilExit() pair trapped in both of those
                // races.
                let spawned = SpawnedProcess()
                continuation.onTermination = { @Sendable _ in
                    spawned.terminate()
                    spawned.reap()
                }

                do {
                    // The sequence may have been dropped before this task got
                    // to run. Never launch a child for a sequence that is
                    // already gone — that is the "dropped call leaves an
                    // orphaned pdftract process" failure mode.
                    guard !spawned.isStopRequested() else { return }

                    try process.run()
                    spawned.didLaunch(process)

                    // A termination that landed between registration and the
                    // launch was a launch-safe no-op above. Honor it now
                    // instead of streaming a dead sequence's child to
                    // completion.
                    if spawned.isStopRequested() {
                        spawned.terminate()
                    }

                    let outHandle = outPipe.fileHandleForReading

                    // Drain stderr concurrently with stdout. Reading stderr
                    // only after waitUntilExit() deadlocks once the child
                    // writes more than the OS pipe buffer (~64KB on Linux):
                    // the child blocks in write(stderr) while this task blocks
                    // on stdout, so neither side ever finishes. Mirrors the
                    // buffered exec path, which drains both pipes this way.
                    let stderrTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }

                    // Read lines incrementally. Loop to EOF rather than while
                    // `process.isRunning`: a child that exits between two reads
                    // can still leave buffered stdout behind, and EOF is the
                    // only signal that stdout is fully drained. When the
                    // sequence is dropped, onTermination's terminate() EOFs
                    // this read — the drop cannot leave the producer wedged on
                    // a pipe that never closes.
                    var buffer = [UInt8]()
                    let readSize = 4096

                    while true {
                        let data = outHandle.readData(ofLength: readSize)
                        if data.isEmpty {
                            break
                        }

                        buffer.append(contentsOf: data)

                        // Process complete lines
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = Data(buffer[..<newlineIndex])
                            buffer.removeSubrange(0...newlineIndex)

                            if let lineString = String(data: lineData, encoding: .utf8), !lineString.isEmpty {
                                do {
                                    let match = try JSONDecoder().decode(Match.self, from: lineData)
                                    continuation.yield(match)
                                } catch {
                                    // Surface undecodable lines via onSkippedLine instead of
                                    // swallowing them — silent drops mask truncation/CLI/schema drift.
                                    if let onSkippedLine { onSkippedLine(error) }
                                }
                            }
                        }
                    }

                    // Process remaining buffer
                    if !buffer.isEmpty {
                        if let lineString = String(bytes: buffer, encoding: .utf8), !lineString.isEmpty {
                            do {
                                let match = try JSONDecoder().decode(Match.self, from: Data(buffer))
                                continuation.yield(match)
                            } catch {
                                // Surface undecodable lines via onSkippedLine instead of
                                // swallowing them — silent drops mask truncation/CLI/schema drift.
                                if let onSkippedLine { onSkippedLine(error) }
                            }
                        }
                    }

                    // Reaps the child exactly once; a no-op if onTermination
                    // already reaped it after killing the child mid-read.
                    spawned.reap()

                    // The child has exited, so the concurrent drain above has
                    // hit EOF and awaiting it cannot block. It must be complete
                    // before mapError so the error carries all of stderr rather
                    // than whatever happened to fit in the pipe buffer.
                    let errData = await stderrTask.value
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.finish(throwing: mapError(stderr, Int(process.terminationStatus)))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    
    
    
    
    /// Gets metadata from a PDF.
    
    /// - Parameters:
    
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Base options.
    /// - Returns: The document metadata.
    
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Throws: `PdftractError` if operation fails, `TimeoutError` on
    ///   deadline expiry, `CancellationError` if the Task is cancelled.
    public func getMetadata(
        _ source: Source
        
        , options: BaseOptions = BaseOptions()
        
        , timeout: TimeInterval? = nil
    ) async throws -> Metadata {
        var args = [
        
        "extract", "--metadata-only", "--json"
        
        ]
        let prepared = try source.toArgs()
        defer { prepared.cleanUp() }
        args.append(contentsOf: prepared.arguments)
        
        args.append(contentsOf: options.toArgs())
        

        let output = try await exec(args, timeout: timeout)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Metadata.self, from: data)
    }

    
    
    
    
    /// Computes a content hash fingerprint of a PDF.
    
    /// - Parameters:
    
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Hash options.
    /// - Returns: The document fingerprint.
    
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Throws: `PdftractError` if operation fails, `TimeoutError` on
    ///   deadline expiry, `CancellationError` if the Task is cancelled.
    public func hash(
        _ source: Source
        
        , options: HashOptions = HashOptions()
        
        , timeout: TimeInterval? = nil
    ) async throws -> Fingerprint {
        var args = [
        
        "hash", "--json"
        
        ]
        let prepared = try source.toArgs()
        defer { prepared.cleanUp() }
        args.append(contentsOf: prepared.arguments)
        
        args.append(contentsOf: options.toArgs())
        

        let output = try await exec(args, timeout: timeout)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Fingerprint.self, from: data)
    }

    
    
    
    
    /// Classifies a PDF document.
    
    /// - Parameters:
    
    ///   - source: The PDF source (path, URL, or bytes).
    /// - Returns: The classification result.
    
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Throws: `PdftractError` if operation fails, `TimeoutError` on
    ///   deadline expiry, `CancellationError` if the Task is cancelled.
    public func classify(
        _ source: Source
        
        , timeout: TimeInterval? = nil
    ) async throws -> Classification {
        var args = [
        
        "classify", "--json"
        
        ]
        let prepared = try source.toArgs()
        defer { prepared.cleanUp() }
        args.append(contentsOf: prepared.arguments)
        

        let output = try await exec(args, timeout: timeout)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Classification.self, from: data)
    }

    
    
    
    /// Verifies a receipt against a PDF.
    /// - Parameters:
    ///   - path: Path to the PDF file.
    ///   - receipt: The receipt data to verify.
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Returns: A `ReceiptVerificationResult`. Its `valid` property is `true` when the
    ///   receipt matches; when invalid, `reason` describes which verification check failed.
    /// - Throws: `PdftractError` if the CLI invocation itself fails (not a receipt
    ///   validation failure), `TimeoutError` on deadline expiry,
    ///   `CancellationError` if the Task is cancelled.
    public func verifyReceipt(_ path: String, receipt: Receipt, timeout: TimeInterval? = nil) async throws -> ReceiptVerificationResult {
        let output = try await exec(["verify-receipt", path, receipt.data, "--json"], timeout: timeout)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(ReceiptVerificationResult.self, from: data)
    }

    
    
}

/// Cancellation- and timeout-safe handle on a spawned `Process`.
///
/// `Foundation.Process` is hostile to asynchronous lifecycle control:
/// `terminate()` traps when the child has not launched yet, `waitUntilExit()`
/// traps before launch too, and a Task cancellation or a dropped stream can
/// land at any instant — including between `run()` and cancellation-handler
/// registration, or after the child already exited on its own. Every
/// lifecycle path (success, mapped CLI error, timeout, Task cancellation,
/// dropped stream) therefore funnels through this wrapper, which makes both
/// operations launch-safe and idempotent:
///
/// - `terminate()` only signals a child that is actually running, and
///   remembers a stop that won the race against the launch so it is honored
///   once the child exists.
/// - `reap()` runs `waitUntilExit()` exactly once no matter how many callers
///   race to clean up, so the child is never left a zombie.
/// - `deadlineFired()` records whether the timeout genuinely interrupted a
///   live child, so a child that beat its deadline still returns its
///   (complete) output instead of a timeout error.
private final class SpawnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false
    private var reaped = false
    private var timedOut = false

    /// Marks the child as launched. Must be called immediately after
    /// `Process.run()` succeeds; `terminate()` and `reap()` are no-ops before
    /// this point.
    func didLaunch(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    /// Whether any caller has asked for the child to be stopped.
    func isStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    /// Whether the timeout deadline interrupted a live child.
    func isTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// SIGTERMs the child if it is live, and remembers the request so a stop
    /// that races the launch is honored once the child exists. Safe to call
    /// from any thread at any time — before launch, after exit, or
    /// concurrently with itself. Reaping stays with `reap()`.
    func terminate() {
        lock.lock()
        stopRequested = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// Records a fired timeout deadline: SIGTERMs the child if it is still
    /// running and marks the run as timed out. A child that already exited
    /// beat the deadline, so the flag stays clear and the normal path returns
    /// its output rather than a timeout error.
    func deadlineFired() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        lock.lock()
        timedOut = true
        lock.unlock()
        process.terminate()
    }

    /// Reaps the child exactly once. A no-op when the child never launched or
    /// was already reaped, so success, cancellation, timeout, and stream
    /// termination can all call it without double-`waitUntilExit()`.
    func reap() {
        lock.lock()
        let process = self.process
        let alreadyReaped = reaped
        reaped = true
        lock.unlock()
        guard let process, !alreadyReaped else { return }
        process.waitUntilExit()
    }
}
