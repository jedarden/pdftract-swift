//
// This file is auto-generated. Do not edit manually.
//

#if os(Linux)
import Foundation
#else
import Foundation
#endif

/// Base error type for all Pdftract CLI exit-code errors.
///
/// A class, not a struct: the sdk-contract requires every exit-code error to
/// inherit from this single base type, and `mapError` (Methods.swift) is
/// declared to return it, so concrete errors like `CorruptPdfError` must be
/// subtypes — Swift structs cannot inherit. Callers rethrow through
/// `catch let error as PdftractError`, which only matches subtypes.
public class PdftractError: Error, LocalizedError {
    public let message: String
    public let exitCode: Int

    public init(_ message: String, _ exitCode: Int) {
        self.message = message
        self.exitCode = exitCode
    }

    public var errorDescription: String? {
        return message
    }

    public var localizedDescription: String {
        return message
    }
}

/// One or more lines in the CLI's NDJSON stream could not be decoded into the
/// expected type (`Page` for `extractStream`, `Match` for `search`).
///
/// Unlike the exit-code errors above, this is not raised by the CLI — the
/// process exited cleanly (status 0) but emitted at least one line this SDK
/// could not parse. The records that did decode were already yielded; this
/// error finishes the stream so a caller can distinguish silently-dropped data
/// from a PDF that genuinely produced fewer results. `skippedCount` is the
/// number of undecodable lines that were dropped (a truncated write, a CLI bug,
/// or a schema drift between the CLI and this SDK's model are the usual causes).
public struct MalformedStreamError: Error, LocalizedError {
    public let message: String
    public let skippedCount: Int

    public init(_ message: String, _ skippedCount: Int) {
        self.message = message
        self.skippedCount = skippedCount
    }

    public var errorDescription: String? {
        return message
    }

    public var localizedDescription: String {
        return message
    }
}



/// Corrupt PDF
///
/// Adds nothing to `PdftractError` — it exists so callers can catch this
/// specific exit code. It inherits `init(_:_:)` because it declares no stored
/// properties of its own.
public final class CorruptPdfError: PdftractError {}




/// Encrypted / password missing/wrong
///
/// Adds nothing to `PdftractError` — it exists so callers can catch this
/// specific exit code. It inherits `init(_:_:)` because it declares no stored
/// properties of its own.
public final class EncryptionError: PdftractError {}




/// Source unreadable
///
/// Adds nothing to `PdftractError` — it exists so callers can catch this
/// specific exit code. It inherits `init(_:_:)` because it declares no stored
/// properties of its own.
public final class SourceUnreachableError: PdftractError {}




/// Network interrupted
///
/// Adds nothing to `PdftractError` — it exists so callers can catch this
/// specific exit code. It inherits `init(_:_:)` because it declares no stored
/// properties of its own.
public final class RemoteFetchInterruptedError: PdftractError {}




/// TLS / cert failure
///
/// Adds nothing to `PdftractError` — it exists so callers can catch this
/// specific exit code. It inherits `init(_:_:)` because it declares no stored
/// properties of its own.
public final class TlsError: PdftractError {}

















/// Receipt verify failed
///
/// Adds nothing to `PdftractError` — it exists so callers can catch this
/// specific exit code. It inherits `init(_:_:)` because it declares no stored
/// properties of its own.
public final class ReceiptVerifyError: PdftractError {}



