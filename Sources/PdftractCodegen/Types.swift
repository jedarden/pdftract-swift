//
// This file is auto-generated. Do not edit manually.
//

#if os(Linux)
import Foundation
#else
import Foundation
#endif

/// Source type for PDF input.
/// Represents a local file path, a remote URL, or raw bytes.
public enum Source {
    case path(String)
    case url(URL)
    case bytes(Data)

    /// Converts the source to CLI arguments, tracking any temporary files
    /// that had to be materialized on disk so they can be removed once the
    /// pdftract process no longer needs them.
    /// - Returns: The prepared arguments plus any temp files to clean up.
    func toArgs() throws -> PreparedArgs {
        switch self {
        case .path(let path):
            return PreparedArgs(arguments: [path])
        case .url(let url):
            return PreparedArgs(arguments: [url.absoluteString])
        case .bytes(let data):
            // Spill the bytes to a temporary file so the CLI can read them.
            // The caller owns the returned `PreparedArgs` and must `cleanUp()`
            // (typically via `defer`) once the pdftract process has finished —
            // otherwise the file leaks in the shared temp directory, and for
            // documents passed in-memory to avoid touching disk, the content
            // would persist there indefinitely.
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("pdftract-input-\(UUID().uuidString).pdf")
            try data.write(to: tempFile)
            return PreparedArgs(arguments: [tempFile.path], temporaryFiles: [tempFile])
        }
    }
}

/// CLI arguments prepared from a `Source`, together with any temporary files
/// that were spilled to disk and must be removed after the pdftract process
/// runs (e.g. the backing file for `Source.bytes`).
struct PreparedArgs: Sendable {
    /// Argument strings to pass to the pdftract binary.
    let arguments: [String]
    /// Temporary files created for this invocation; removed by `cleanUp()`.
    let temporaryFiles: [URL]

    init(arguments: [String], temporaryFiles: [URL] = []) {
        self.arguments = arguments
        self.temporaryFiles = temporaryFiles
    }

    /// Removes any temporary files owned by these prepared arguments.
    /// Idempotent; safe on the success, error, and cancellation paths.
    func cleanUp() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Base options common to all methods.
public struct BaseOptions: Codable, Sendable {
    /// Maximum seconds to wait for the operation.
    public var timeout: Int?

    public init(timeout: Int? = nil) {
        self.timeout = timeout
    }

    /// Converts options to CLI arguments.
    func toArgs() -> [String] {
        var args = [String]()
        if let timeout = timeout {
            args.append("--timeout")
            args.append(String(timeout))
        }
        return args
    }
}

/// Options for extraction methods.
public struct ExtractOptions: Codable, Sendable {
    /// ISO 639-3 language code for OCR.
    public var ocrLanguage: String?

    /// Confidence threshold (0-1) for accepting OCR text.
    public var ocrThreshold: Double?

    /// Preserve original reading order and layout.
    public var preserveLayout: Bool?

    /// Extract embedded images.
    public var extractImages: Bool?

    /// Format for extracted images: png, jpg, or webp.
    public var imageFormat: String?

    /// Minimum dimension (pixels) for image extraction.
    public var minImageSize: Int?

    public init(
        ocrLanguage: String? = nil,
        ocrThreshold: Double? = nil,
        preserveLayout: Bool? = nil,
        extractImages: Bool? = nil,
        imageFormat: String? = nil,
        minImageSize: Int? = nil
    ) {
        self.ocrLanguage = ocrLanguage
        self.ocrThreshold = ocrThreshold
        self.preserveLayout = preserveLayout
        self.extractImages = extractImages
        self.imageFormat = imageFormat
        self.minImageSize = minImageSize
    }

    /// Converts options to CLI arguments.
    func toArgs() -> [String] {
        var args = [String]()
        if let ocrLanguage = ocrLanguage {
            args.append("--ocr-language")
            args.append(ocrLanguage)
        }
        if let ocrThreshold = ocrThreshold {
            args.append("--ocr-threshold")
            args.append(String(ocrThreshold))
        }
        if let preserveLayout = preserveLayout, preserveLayout {
            args.append("--preserve-layout")
        }
        if let extractImages = extractImages, extractImages {
            args.append("--extract-images")
        }
        if let imageFormat = imageFormat {
            args.append("--image-format")
            args.append(imageFormat)
        }
        if let minImageSize = minImageSize {
            args.append("--min-image-size")
            args.append(String(minImageSize))
        }
        return args
    }
}

/// Options for search methods.
public struct SearchOptions: Codable, Sendable {
    /// Ignore case when matching.
    public var caseInsensitive: Bool?

    /// Treat pattern as regular expression.
    public var regex: Bool?

    /// Match only whole words.
    public var wholeWord: Bool?

    /// Maximum matches to return.
    public var maxResults: Int?

    public init(
        caseInsensitive: Bool? = nil,
        regex: Bool? = nil,
        wholeWord: Bool? = nil,
        maxResults: Int? = nil
    ) {
        self.caseInsensitive = caseInsensitive
        self.regex = regex
        self.wholeWord = wholeWord
        self.maxResults = maxResults
    }

    /// Converts options to CLI arguments.
    func toArgs() -> [String] {
        var args = [String]()
        if let caseInsensitive = caseInsensitive, caseInsensitive {
            args.append("--case-insensitive")
        }
        if let regex = regex, regex {
            args.append("--regex")
        }
        if let wholeWord = wholeWord, wholeWord {
            args.append("--whole-word")
        }
        if let maxResults = maxResults {
            args.append("--max-results")
            args.append(String(maxResults))
        }
        return args
    }
}

/// Options for hash methods.
public struct HashOptions: Codable, Sendable {
    /// Maximum seconds to wait for the operation.
    public var timeout: Int?

    public init(timeout: Int? = nil) {
        self.timeout = timeout
    }

    /// Converts options to CLI arguments.
    func toArgs() -> [String] {
        var args = [String]()
        if let timeout = timeout {
            args.append("--timeout")
            args.append(String(timeout))
        }
        return args
    }
}

/// Document metadata.
public struct Metadata: Codable, Sendable {
    public let title: String?
    public let author: String?
    public let subject: String?
    public let keywords: [String]?
    public let creator: String?
    public let producer: String?
    public let created: String?
    public let modified: String?
    public let pageCount: Int

    private enum CodingKeys: String, CodingKey {
        case title, author, subject, keywords, creator, producer, created, modified
        case pageCount = "page_count"
    }
}

/// Text span within a page.
public struct Span: Codable, Sendable {
    public let text: String
    public let bbox: [Double]
    public let font: String
    public let size: Double
    public let confidence: Double?
}

/// Content block (paragraph, heading, table, etc.).
public struct Block: Codable, Sendable {
    public let kind: String
    public let text: String
    public let bbox: [Double]
    public let level: Int?
}

/// A single page in the document.
public struct Page: Codable, Sendable {
    public let pageIndex: Int
    public let width: Double
    public let height: Double
    public let rotation: Int
    public let spans: [Span]
    public let blocks: [Block]

    private enum CodingKeys: String, CodingKey {
        case pageIndex = "page_index"
        case width, height, rotation, spans, blocks
    }
}

/// Complete document structure.
public struct Document: Codable, Sendable {
    public let schemaVersion: String
    public let pages: [Page]
    public let metadata: Metadata

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pages, metadata
    }
}

/// Search result match.
public struct Match: Codable, Sendable {
    public let text: String
    public let page: Int
    public let bbox: [Double]
    public let context: Context

    public struct Context: Codable, Sendable {
        public let before: String
        public let after: String
    }
}

/// Document fingerprint for content-based hashing.
public struct Fingerprint: Codable, Sendable {
    public let hash: String
    public let pageCount: Int
    public let fastHash: String
    public let metadata: Metadata

    private enum CodingKeys: String, CodingKey {
        case hash, pageCount, fastHash, metadata
        case pageCount = "page_count"
        case fastHash = "fast_hash"
    }
}

/// Document classification result.
public struct Classification: Codable, Sendable {
    public let category: String
    public let confidence: Double
    public let tags: [String]
    public let heuristics: [String: Bool]
}

/// Receipt for verification.
public struct Receipt: Codable, Sendable {
    public let data: String
}

/// Result of verifying a receipt against a PDF.
///
/// Decode of the `pdftract verify-receipt --json` output. `valid` is `true` when the
/// receipt matched (`status == "ok"`); when `false`, `reason` carries the CLI's
/// explanation of which check failed (fingerprint, bbox, or content hash).
public struct ReceiptVerificationResult: Codable, Sendable {
    /// Raw verification status reported by the CLI
    /// (`"ok"`, `"fingerprint_mismatch"`, `"bbox_mismatch"`, or `"content_mismatch"`).
    public let status: String
    /// Best span intersection-over-union observed during verification.
    public let bestIou: Double
    public let expectedContentHash: String?
    public let actualContentHash: String?
    /// Human-readable explanation of why verification failed; `nil` when the receipt is valid.
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case bestIou = "best_iou"
        case expectedContentHash = "expected_content_hash"
        case actualContentHash = "actual_content_hash"
        case reason = "error"
    }

    /// `true` when the receipt verified successfully (`status == "ok"`).
    public var valid: Bool { status == "ok" }
}
