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
            // Search PATH for pdftract
            self.binaryPath = Self.findBinary() ?? "pdftract"
        }
    }

    /// Finds the pdftract binary on PATH.
    private static func findBinary() -> String? {
        #if os(Linux)
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = envPath.split(separator: ":")
        #else
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = envPath.split(separator: ";")
        #endif

        for path in paths {
            let binaryPath = NSString.path(withComponents: [String(path), "pdftract"])
            if FileManager.default.fileExists(atPath: binaryPath) {
                return binaryPath
            }
        }
        return nil
    }

    /// Executes the pdftract binary with the given arguments.
    /// - Parameter args: Command-line arguments to pass.
    /// - Returns: The stdout output as a String.
    /// - Throws: `PdftractError` if the process fails.
    private func exec(_ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.arguments = args

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw mapError(stderr, Int(process.terminationStatus))
            }

            return output
        } catch let error as PdftractError {
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
        guard let exitCode = exitCode else {
            return PdftractError(stderr, -1)
        }

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
    /// - Returns: The complete document structure.
    /// - Throws: `PdftractError` if extraction fails.
    public func Extract(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) async throws -> Document {
        var args = ["extract", "--json"]
        args.append(contentsOf: try source.toArgs())
        args.append(contentsOf: options.toArgs())

        let output = try await exec(args)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Document.self, from: data)
    }

    
    
    
    
    /// Extracts plain text from a PDF.
    
    /// - Parameters:
    ///   - source: The PDF source (path, URL, or bytes).
    ///   - options: Extraction options.
    /// - Returns: The extracted text.
    /// - Throws: `PdftractError` if extraction fails.
    public func ExtractText(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) async throws -> String {
        var args = ["extract"]
        args.append(contentsOf: try source.toArgs())
        args.append(contentsOf: options.toArgs())
        
        args.append("--text")
        
        args.append("--json")

        let output = try await exec(args)

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
    /// - Returns: The extracted text.
    /// - Throws: `PdftractError` if extraction fails.
    public func ExtractMarkdown(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) async throws -> String {
        var args = ["extract"]
        args.append(contentsOf: try source.toArgs())
        args.append(contentsOf: options.toArgs())
        
        args.append("--md")
        
        args.append("--json")

        let output = try await exec(args)

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
    /// - Returns: An `AsyncThrowingStream` that yields `Page` values.
    /// - Throws: `PdftractError` if extraction fails.
    public func ExtractStream(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) -> AsyncThrowingStream<Page, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                var args = ["extract", "--ndjson"]
                do {
                    args.append(contentsOf: try source.toArgs())
                    args.append(contentsOf: options.toArgs())
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.arguments = args

                // Handle cancellation
                continuation.onTermination = { @Sendable _ in
                    process.terminate()
                    _ = try? process.waitUntilExit()
                }

                do {
                    try process.run()

                    let outHandle = outPipe.fileHandleForReading
                    let errHandle = errPipe.fileHandleForReading

                    // Read lines incrementally
                    var buffer = [UInt8]()
                    let readSize = 4096

                    while process.isRunning {
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
                                    // Skip malformed lines; the final error will be reported if needed
                                }
                            }
                        }
                    }

                    // Process remaining buffer
                    if !buffer.isEmpty {
                        if let lineString = String(data: buffer, encoding: .utf8), !lineString.isEmpty {
                            do {
                                let page = try JSONDecoder().decode(Page.self, from: Data(buffer))
                                continuation.yield(page)
                            } catch {
                                // Skip malformed lines
                            }
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let errData = errHandle.readDataToEndOfFile()
                        let stderr = String(data: errData, encoding: .utf8) ?? ""
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
    /// - Returns: An `AsyncThrowingStream` that yields `Match` values.
    /// - Throws: `PdftractError` if search fails.
    public func Search(
        _ source: Source,
        _ pattern: String,
        options: SearchOptions = SearchOptions()
    ) -> AsyncThrowingStream<Match, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                var args = ["grep", pattern]
                do {
                    args.append(contentsOf: try source.toArgs())
                    args.append(contentsOf: options.toArgs())
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.arguments = args

                // Handle cancellation
                continuation.onTermination = { @Sendable _ in
                    process.terminate()
                    _ = try? process.waitUntilExit()
                }

                do {
                    try process.run()

                    let outHandle = outPipe.fileHandleForReading
                    let errHandle = errPipe.fileHandleForReading

                    // Read lines incrementally
                    var buffer = [UInt8]()
                    let readSize = 4096

                    while process.isRunning {
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
                                    // Skip malformed lines
                                }
                            }
                        }
                    }

                    // Process remaining buffer
                    if !buffer.isEmpty {
                        if let lineString = String(data: buffer, encoding: .utf8), !lineString.isEmpty {
                            do {
                                let match = try JSONDecoder().decode(Match.self, from: Data(buffer))
                                continuation.yield(match)
                            } catch {
                                // Skip malformed lines
                            }
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let errData = errHandle.readDataToEndOfFile()
                        let stderr = String(data: errData, encoding: .utf8) ?? ""
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
    
    /// - Throws: `PdftractError` if operation fails.
    public func GetMetadata(
        _ source: Source
        
        , options: BaseOptions = BaseOptions()
        
    ) async throws -> Metadata {
        var args = [
        
        "extract", "--metadata-only", "--json"
        
        ]
        args.append(contentsOf: try source.toArgs())
        
        args.append(contentsOf: options.toArgs())
        

        let output = try await exec(args)

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
    
    /// - Throws: `PdftractError` if operation fails.
    public func Hash(
        _ source: Source
        
        , options: HashOptions = HashOptions()
        
    ) async throws -> Fingerprint {
        var args = [
        
        "hash", "--json"
        
        ]
        args.append(contentsOf: try source.toArgs())
        
        args.append(contentsOf: options.toArgs())
        

        let output = try await exec(args)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Fingerprint.self, from: data)
    }

    
    
    
    
    /// Classifies a PDF document.
    
    /// - Parameters:
    
    ///   - source: The PDF source (path, URL, or bytes).
    /// - Returns: The classification result.
    
    /// - Throws: `PdftractError` if operation fails.
    public func Classify(
        _ source: Source
        
    ) async throws -> Classification {
        var args = [
        
        "classify", "--json"
        
        ]
        args.append(contentsOf: try source.toArgs())
        

        let output = try await exec(args)

        guard let data = output.data(using: .utf8) else {
            throw PdftractError("Failed to decode output", -1)
        }

        return try JSONDecoder().decode(Classification.self, from: data)
    }

    
    
    
    /// Verifies a receipt.
    /// - Parameters:
    ///   - path: Path to the PDF file.
    ///   - receipt: The receipt data to verify.
    /// - Returns: `true` if the receipt is valid, `false` otherwise.
    /// - Throws: `PdftractError` if verification fails (not receipt validation failure).
    public func VerifyReceipt(_ path: String, receipt: Receipt) async throws -> Bool {
        let output = try await exec(["verify-receipt", path, receipt.data])
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    
    
}
