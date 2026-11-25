//
// This file is auto-generated. Do not edit manually.
//

#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif os(macOS)
import Foundation
import Darwin
#else
import Foundation
#endif

/// Main Pdftract client for extracting data from PDFs.
/// Uses the bundled pdftract binary via Process spawning.
///
/// `Sendable` value type: a single instance may be shared across concurrency
/// domains (held by an actor, captured in concurrent Tasks, copied freely).
/// The struct's only stored property is an immutable `binaryPath`, and every
/// call builds its working state locally — its own child process, pipes, and
/// timeout/cancellation bookkeeping — so concurrent calls are fully
/// independent. The one shared piece, the PATH scan cached in
/// `resolvedBinaryPath`, runs at most once per process behind a thread-safe
/// `static let` initializer. No locks to configure, no shared mutable state,
/// and no ordering between concurrent calls beyond each child's own
/// completion order.
public struct Pdftract: Sendable {
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
    ///   - stdin: Optional payload pushed to the child's standard input
    ///     before launch. This is the transport for the password leg of the
    ///     CLI's `--password-stdin` channel (`ExtractOptions.password`) —
    ///     the value must never travel in argv, where `ps` exposes it.
    /// - Returns: The stdout output as a String.
    /// - Throws: `PdftractError` if the process fails, `TimeoutError` when the
    ///   deadline expires, `CancellationError` if the surrounding Task is
    ///   cancelled (the child is terminated and reaped either way).
    private func exec(
        _ args: [String],
        timeout: TimeInterval? = nil,
        stdin: Data? = nil
    ) async throws -> String {
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

        // Optional stdin payload — the password leg of `--password-stdin`
        // (see `ExtractOptions.password`). The pipe is retained by
        // `process.standardInput`; the local keeps a second reference so it
        // provably outlives the run on every path below.
        var stdinPipe: Pipe?
        if let stdin {
            stdinPipe = Self.attachStdin(process, payload: stdin)
        }

        let spawned = SpawnedProcess()

        do {
            return try await withTaskCancellationHandler {
                guard !Task.isCancelled else { throw CancellationError() }

                try Self.runWithDeliverableTermination(process)
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

                // Drains BEFORE reaping — the order is load-bearing on Linux.
                // When waitUntilExit() runs on a Swift-concurrency thread and
                // parks across the child's death, corelibs-foundation on
                // swift:5.10-jammy never delivers the exit event to it (a call
                // parked across the exit wedged forever when the test fake
                // left no other process to fire; measured 2026-11-25,
                // pdfswift-b64f41eb). A call made after the child has already
                // exited takes a fast path that always works. Awaiting the
                // drains first guarantees exactly that: EOF means the child —
                // the sole holder of the pipe write ends — is gone, so the
                // reap below finds an exited child and completes promptly.
                // This mirrors the streaming methods, which reap after
                // reading to EOF for the same reason.
                let outData = await stdoutTask.value
                let errData = await stderrTask.value

                // Reaps the child exactly once; by this point the child has
                // exited (the drains above saw EOF), so this cannot park.
                spawned.reap()

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

    /// Hands `payload` to the child as its standard input.
    ///
    /// The bytes are pushed and the write end closed BEFORE `process.run()`,
    /// which is what makes this race-free: by the time the child exists there
    /// is nothing left to write, so a child that exits without ever reading
    /// its stdin (a usage error from a binary that predates
    /// `--password-stdin`, say) can never SIGPIPE this process on a write to
    /// a dead pipe — the payload simply dies unread with the child. Password
    /// payloads are bytes-tiny, far under the ~64KB kernel pipe buffer, so
    /// the pre-launch push cannot block.
    ///
    /// The returned pipe must stay referenced until the child has been
    /// reaped; `process.standardInput` retains it, and the spawning site
    /// keeps a local reference through the whole run.
    private static func attachStdin(_ process: Process, payload: Data) -> Pipe {
        let pipe = Pipe()
        do {
            try pipe.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            // Unreachable in practice (empty pipe buffer, no child yet, no
            // competing writer), but a failed decrypt request must not crash
            // the caller: drop the payload and let the child run without a
            // password — which surfaces as the CLI's own encrypted-PDF
            // failure (exit 3 through `mapError`), never as a Foundation
            // handle exception.
        }
        try? pipe.fileHandleForWriting.close()
        process.standardInput = pipe
        return pipe
    }

    /// Launches `process` with SIGTERM deliverable in the child.
    ///
    /// posix_spawn inherits the launching thread's signal mask, and
    /// Foundation sets no `POSIX_SPAWN_SETSIGMASK` to override it. Swift
    /// concurrency's cooperative threads run with every catchable signal
    /// blocked — SIGTERM included — and every spawn site here executes on
    /// one (the buffered `exec` operation, or a streaming producer Task).
    /// A child spawned from such a thread therefore starts with SIGTERM
    /// blocked: the cancellation and timeout paths' `terminate()` enqueues
    /// a signal the child can never act on, and the call wedges until the
    /// child exits on its own. Unblocking SIGTERM for the spawn window
    /// alone gives the child a deliverable SIGTERM; the calling thread's
    /// mask is restored synchronously before any suspension point, so no
    /// other task can observe the widened window.
    private static func runWithDeliverableTermination(_ process: Process) throws {
        #if os(Linux) || os(macOS)
        var toUnblock = sigset_t()
        var saved = sigset_t()
        sigemptyset(&toUnblock)
        sigaddset(&toUnblock, SIGTERM)
        guard pthread_sigmask(SIG_UNBLOCK, &toUnblock, &saved) == 0 else {
            // Mask manipulation failed (not observed in practice): launch
            // anyway — an undeliverable SIGTERM is the pre-fix status quo,
            // and refusing every call would be strictly worse.
            try process.run()
            return
        }
        defer { pthread_sigmask(SIG_SETMASK, &saved, nil) }
        try process.run()
        #else
        try process.run()
        #endif
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
        // Options before the `--` separator, the caller's source after it —
        // see "Flag-like paths and patterns" in README.md.
        args.append(contentsOf: options.toArgs())
        args.append("--")
        args.append(contentsOf: prepared.arguments)

        // A password rides the `--password-stdin` flag `toArgs()` emitted,
        // delivered as one newline-terminated line on the child's stdin —
        // the CLI's secure channel. Empty strings stay unset (see
        // `ExtractOptions.password`).
        let stdinPayload = options.password.flatMap { password in
            password.isEmpty ? nil : Data("\(password)\n".utf8)
        }

        let output = try await exec(args, timeout: timeout, stdin: stdinPayload)

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
        // Options and format flags before the `--` separator, the caller's
        // source after it — see "Flag-like paths and patterns" in README.md.
        args.append(contentsOf: options.toArgs())
        
        args.append("--text")

        args.append("--json")
        args.append("--")
        args.append(contentsOf: prepared.arguments)

        // Password leg, same transport as `extract` (see `ExtractOptions.password`).
        let stdinPayload = options.password.flatMap { password in
            password.isEmpty ? nil : Data("\(password)\n".utf8)
        }

        let output = try await exec(args, timeout: timeout, stdin: stdinPayload)

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
        // Options and format flags before the `--` separator, the caller's
        // source after it — see "Flag-like paths and patterns" in README.md.
        args.append(contentsOf: options.toArgs())
        
        args.append("--md")

        args.append("--json")
        args.append("--")
        args.append(contentsOf: prepared.arguments)

        // Password leg, same transport as `extract` (see `ExtractOptions.password`).
        let stdinPayload = options.password.flatMap { password in
            password.isEmpty ? nil : Data("\(password)\n".utf8)
        }

        let output = try await exec(args, timeout: timeout, stdin: stdinPayload)

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
                    // Options before the `--` separator, the caller's source
                    // after it — see "Flag-like paths and patterns" in
                    // README.md. Every method builds its argv in this order;
                    // a value that begins with `-` must never be reachable
                    // by the flag parser.
                    args.append(contentsOf: options.toArgs())
                    args.append("--")
                    args.append(contentsOf: prepared.arguments)
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

                // Password leg: same pre-launch stdin transport as the
                // buffered exec path (see `ExtractOptions.password` and
                // `Pdftract.attachStdin`). The pipe is retained by
                // `process.standardInput`; the local keeps a second
                // reference through the whole run.
                var stdinPipe: Pipe?
                if let password = options.password, !password.isEmpty {
                    stdinPipe = Pdftract.attachStdin(
                        process,
                        payload: Data("\(password)\n".utf8)
                    )
                }

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

                    try Self.runWithDeliverableTermination(process)
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
                var args = ["grep"]
                let prepared: PreparedArgs
                do {
                    prepared = try source.toArgs()
                    // Options first, then `--`, then the caller's values —
                    // see "Flag-like paths and patterns" in README.md.
                    // Without the separator a pattern like "-js" is parsed
                    // as short flags (here: --threads with value "s"), and
                    // a pattern like "-i" would silently flip
                    // case-sensitivity instead of being searched for.
                    args.append(contentsOf: options.toArgs())
                    args.append("--")
                    args.append(pattern)
                    args.append(contentsOf: prepared.arguments)
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

                    try Self.runWithDeliverableTermination(process)
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
        // Options before the `--` separator, the caller's source after it —
        // see "Flag-like paths and patterns" in README.md.
        
        args.append(contentsOf: options.toArgs())
        
        args.append("--")
        args.append(contentsOf: prepared.arguments)

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
        // Options before the `--` separator, the caller's source after it —
        // see "Flag-like paths and patterns" in README.md.
        
        args.append(contentsOf: options.toArgs())
        
        args.append("--")
        args.append(contentsOf: prepared.arguments)

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
        // Options before the `--` separator, the caller's source after it —
        // see "Flag-like paths and patterns" in README.md.
        
        args.append("--")
        args.append(contentsOf: prepared.arguments)

        let output = try await exec(args, timeout: timeout)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Classification.self, from: data)
    }

    
    
    
    /// Verifies a receipt against a PDF.
    ///
    /// Verification re-extracts the receipt's page and checks the PDF
    /// fingerprint, a span bbox overlap of at least 90% IoU, and the NFC-normalized
    /// content hash. The receipt's `extraction_version` must match the binary's
    /// major and minor version or verification fails before those checks.
    /// - Parameters:
    ///   - path: Path to the PDF file. A plain path rather than a `Source` —
    ///     the one method without a `Source` parameter — because the
    ///     `verify-receipt` CLI reads the PDF from local disk only and has no
    ///     URL form (unlike `extract`, whose URL inputs the binary fetches
    ///     itself); `Source` advertises `.url` to every method that accepts
    ///     it, so accepting `Source` here would advertise a case the CLI
    ///     could not honor. With in-memory PDF bytes, write them to a file
    ///     and pass its path — the same materialization `Source.bytes`
    ///     performs for the other methods.
    ///   - receipt: The receipt to verify — its `data` must be the path of a
    ///     receipt JSON file (see `Receipt`); the string is passed to the CLI
    ///     unchanged.
    ///   - timeout: Maximum seconds to let the pdftract process run before it
    ///     is terminated and reaped and `TimeoutError` is thrown. `nil` (the
    ///     default) waits indefinitely. Cancelling the surrounding Task has
    ///     the same effect at any time.
    /// - Returns: A `ReceiptVerificationResult`, decoded from the CLI's
    ///   `--json` output. The method returns only when the receipt verified,
    ///   so `valid` is always `true` and `reason` always `nil` here — the
    ///   struct's failure fields mirror the CLI schema and are filled only
    ///   by decodes outside this call.
    /// - Throws: `ReceiptVerifyError` when the PDF fingerprint check fails
    ///   (CLI exit 10); `PdftractError` when the bbox or content-hash check
    ///   fails (exits 11/12), the PDF or receipt file is unreadable, or
    ///   receipt and binary major/minor versions differ (exit 1);
    ///   `TimeoutError` on deadline expiry, `CancellationError` if the Task
    ///   is cancelled.
    public func verifyReceipt(_ path: String, receipt: Receipt, timeout: TimeInterval? = nil) async throws -> ReceiptVerificationResult {
        // `--` separates the SDK's `--json` flag from the two caller-supplied
        // positional paths — see "Flag-like paths and patterns" in README.md.
        let output = try await exec(["verify-receipt", "--json", "--", path, receipt.data], timeout: timeout)

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
