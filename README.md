# pdftract-swift

Swift SDK for pdftract - PDF extraction and analysis for server-side Swift.

## Platform Support

**Supported**: macOS 13+, Linux (server-side use only)
**Unsupported**: iOS (Apple does not allow spawning subprocesses in App Store apps)

> **Note for iOS users**: Use `pdftract serve` over HTTP from your iOS client. Run the server with the Swift SDK on a macOS/Linux backend and make HTTP requests from your iOS app.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jedarden/pdftract-swift", from: "1.1.0")
]
```

## Usage

### Basic extract

```swift
import Pdftract

let client = Pdftract()
let doc = try await client.extract(.path("document.pdf"))
print("Pages: \(doc.pages.count)")
print("Title: \(doc.metadata.title ?? "Untitled")")
```

### Extract from URL

```swift
let doc = try await client.extract(.url(URL(string: "https://example.com/doc.pdf")!))
```

### Extract with OCR

```swift
let options = ExtractOptions(
    ocrLanguage: "eng",
    ocrThreshold: 0.7
)
let doc = try await client.extract(.path("scanned.pdf"), options: options)
```

### Extract text

```swift
let text = try await client.extractText(.path("document.pdf"))
print(text)
```

### Extract Markdown

```swift
let md = try await client.extractMarkdown(.path("document.pdf"))
```

### Stream extraction (for large PDFs)

```swift
for await page in client.extractStream(.path("large.pdf")) {
    print("Page \(page.pageIndex + 1): \(page.blocks.count) blocks")
}
```

### Search

```swift
for await match in client.search(.path("document.pdf"), "invoice") {
    print("Found on page \(match.page): \(match.text)")
    print("  Context: ...\(match.context.before)[\(match.text)]\(match.context.after)...")
}
```

### Get metadata

```swift
let metadata = try await client.getMetadata(.path("document.pdf"))
print("Pages: \(metadata.pageCount)")
print("Author: \(metadata.author ?? "Unknown")")
```

### Hash fingerprint

```swift
let fingerprint = try await client.hash(.path("document.pdf"))
print("SHA-256: \(fingerprint.hash)")
print("BLAKE3: \(fingerprint.fastHash)")
```

### Classify document

```swift
let classification = try await client.classify(.path("document.pdf"))
print("Category: \(classification.category)")
print("Confidence: \(classification.confidence)")
```

### Verify receipt

```swift
let receipt = Receipt(data: "...")
let valid = try await client.verifyReceipt("/path/to/receipt.pdf", receipt: receipt)
print("Valid: \(valid)")
```

## Binary version compatibility

This SDK requires pdftract 1.1.0. Download from:
https://github.com/jedarden/pdftract/releases/tag/v1.1.0

The SDK will search for `pdftract` on your PATH. To specify a custom binary path:

```swift
let client = Pdftract(binaryPath: "/custom/path/to/pdftract")
```

## Error handling

All methods are `async throws` and can throw the following errors:

| Error | Exit Code | Description |
|-------|-----------|-------------|
| `CorruptPdfError` | 2 | The PDF file is corrupt or invalid |
| `EncryptionError` | 3 | The PDF is encrypted and password is missing/wrong |
| `SourceUnreachableError` | 4 | The source (file or URL) is unreadable |
| `RemoteFetchInterruptedError` | 5 | Network interrupted during remote fetch |
| `TlsError` | 6 | TLS certificate validation failed |
| `ReceiptVerifyError` | 10 | Receipt verification failed |
| `PdftractError` | other | Internal error |

Example:

```swift
do {
    let doc = try await client.extract(.path("document.pdf"))
} catch let error as PdftractError {
    print("Error (code \(error.exitCode)): \(error.localizedDescription)")
}
```

## Options

### ExtractOptions

```swift
let options = ExtractOptions(
    ocrLanguage: "eng",           // ISO 639-3 language code
    ocrThreshold: 0.7,            // OCR confidence threshold (0-1)
    preserveLayout: false,        // Preserve original reading order
    extractImages: false,         // Extract embedded images
    imageFormat: "png",           // Format for images: png, jpg, webp
    minImageSize: 64              // Minimum image dimension
)
```

### SearchOptions

```swift
let options = SearchOptions(
    caseInsensitive: true,        // Ignore case
    regex: false,                 // Treat pattern as regex
    wholeWord: false,             // Match whole words only
    maxResults: 100              // Maximum matches
)
```

### BaseOptions / HashOptions

```swift
let options = BaseOptions(
    timeout: 60                   // Maximum seconds
)
```

## Troubleshooting

### Binary not found

Ensure `pdftract` is on your PATH. The SDK searches PATH for the executable.

```bash
# Verify pdftract is available
pdftract --version
```

### Version mismatch

The SDK will refuse to invoke mismatched binary versions. Install the correct version from the releases page.

### Network failure

For remote URLs, check your network connection and TLS certificate chain.

## Conformance

This SDK passes 100% of the [pdftract conformance suite](https://github.com/jedarden/pdftract/tree/main/tests/sdk-conformance). The conformance report for this release is linked in the GitHub Release.

## License

MIT License - see LICENSE file for details.
