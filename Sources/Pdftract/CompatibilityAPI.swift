//
// CompatibilityAPI.swift
// Pdftract
//
// Hand-written — explicitly NOT auto-generated. The pdftract code generator must never
// overwrite or emit this file. It lives outside the `GENERATED` marker's scope and outside
// the `PdftractCodegen` target.
//
// ADR-1 naming-compatibility shim — see docs/plan/plan.md.
//
// The code generator (`Sources/PdftractCodegen/Methods.swift`) emits PascalCase method
// names (`Extract`, `ExtractText`, `ExtractMarkdown`, `ExtractStream`, `Search`,
// `GetMetadata`, `Hash`, `Classify`, `VerifyReceipt`). That violates the Swift API Design
// Guidelines, which require methods/functions to be lowerCamelCase (only types are
// UpperCamelCase), and it breaks every consumer of this SDK: `README.md`'s usage examples
// and `Tests/PdftractTests/ConformanceTests.swift` all call the lowerCamelCase forms.
//
// Rather than hand-edit the generated file (which would silently vanish on the next codegen
// refresh), this extension exposes the idiomatic lowerCamelCase names the README and the
// conformance suite already promise. Each method forwards 1:1 to the corresponding generated
// PascalCase method.
//
// This is dead code the moment the upstream pdftract codegen templates emit lowerCamelCase
// directly (ADR-1 point 4); delete this file in the same PR that picks up that regenerated
// output.
//

#if os(Linux)
import Foundation
#else
import Foundation
#endif

import PdftractCodegen

extension Pdftract {
    /// Extracts structured data from a PDF.
    ///
    /// lowerCamelCase alias for the generated `Extract(_:options:)` method.
    public func extract(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) async throws -> Document {
        try await Extract(source, options: options)
    }

    /// Extracts plain text from a PDF.
    ///
    /// lowerCamelCase alias for the generated `ExtractText(_:options:)` method.
    public func extractText(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) async throws -> String {
        try await ExtractText(source, options: options)
    }

    /// Extracts Markdown-formatted text from a PDF.
    ///
    /// lowerCamelCase alias for the generated `ExtractMarkdown(_:options:)` method.
    public func extractMarkdown(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) async throws -> String {
        try await ExtractMarkdown(source, options: options)
    }

    /// Extracts pages from a PDF as an async stream (for large documents).
    ///
    /// lowerCamelCase alias for the generated `ExtractStream(_:options:)` method.
    public func extractStream(
        _ source: Source,
        options: ExtractOptions = ExtractOptions()
    ) -> AsyncThrowingStream<Page, Error> {
        ExtractStream(source, options: options)
    }

    /// Searches for text in a PDF, streaming matches as they are found.
    ///
    /// lowerCamelCase alias for the generated `Search(_:_:options:)` method.
    public func search(
        _ source: Source,
        _ pattern: String,
        options: SearchOptions = SearchOptions()
    ) -> AsyncThrowingStream<Match, Error> {
        Search(source, pattern, options: options)
    }

    /// Gets metadata from a PDF.
    ///
    /// lowerCamelCase alias for the generated `GetMetadata(_:options:)` method.
    public func getMetadata(
        _ source: Source,
        options: BaseOptions = BaseOptions()
    ) async throws -> Metadata {
        try await GetMetadata(source, options: options)
    }

    /// Computes a content hash fingerprint of a PDF.
    ///
    /// lowerCamelCase alias for the generated `Hash(_:options:)` method.
    public func hash(
        _ source: Source,
        options: HashOptions = HashOptions()
    ) async throws -> Fingerprint {
        try await Hash(source, options: options)
    }

    /// Classifies a PDF document.
    ///
    /// lowerCamelCase alias for the generated `Classify(_:)` method.
    public func classify(
        _ source: Source
    ) async throws -> Classification {
        try await Classify(source)
    }

    /// Verifies a receipt.
    ///
    /// lowerCamelCase alias for the generated `VerifyReceipt(_:receipt:)` method.
    public func verifyReceipt(_ path: String, receipt: Receipt) async throws -> Bool {
        try await VerifyReceipt(path, receipt: receipt)
    }
}
