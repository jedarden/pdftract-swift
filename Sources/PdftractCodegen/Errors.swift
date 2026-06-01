//
// This file is auto-generated. Do not edit manually.
//

#if os(Linux)
import Foundation
#else
import Foundation
#endif

/// Base error type for all Pdftract errors.
public struct PdftractError: Error, LocalizedError {
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



/// Corrupt PDF
public struct CorruptPdfError: Error, LocalizedError {
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




/// Encrypted / password missing/wrong
public struct EncryptionError: Error, LocalizedError {
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




/// Source unreadable
public struct SourceUnreachableError: Error, LocalizedError {
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




/// Network interrupted
public struct RemoteFetchInterruptedError: Error, LocalizedError {
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




/// TLS / cert failure
public struct TlsError: Error, LocalizedError {
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

















/// Receipt verify failed
public struct ReceiptVerifyError: Error, LocalizedError {
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



