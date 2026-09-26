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
    .package(url: "https://github.com/jedarden/pdftract-swift", from: "1.2.0")
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
let result = try await client.verifyReceipt("/path/to/receipt.pdf", receipt: receipt)
print("Valid: \(result.valid)")
if let reason = result.reason {
    print("Verification failed: \(reason)")
}
```

## Binary version compatibility

This SDK was generated against pdftract 1.2.0. Download that release from:
https://github.com/jedarden/pdftract/releases/tag/v1.2.0

The SDK does **not** verify the binary version at runtime, so a mismatched binary
may fail or return output that does not match this SDK's types. Make sure the
`pdftract` on your PATH is the release above.

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

The exit-code table above covers failures the CLI itself reports. Two
lifecycle errors come from the SDK instead (see the next section):

| Error | Exit Code | Description |
|-------|-----------|-------------|
| `TimeoutError` | -1 | The process outlived the caller-provided `timeout:` and was terminated |
| `CancellationError` | — | The surrounding Swift `Task` was cancelled; the process was terminated |

## Cancellation and timeouts

Every SDK call spawns a `pdftract` child process. The SDK owns that child's
lifecycle end to end:

**Cancellation.** Cancelling the Swift `Task` around a call terminates the
child (SIGTERM) and reaps it — no orphaned `pdftract` process is left behind —
and the call throws `CancellationError`:

```swift
let task = Task { try await client.extract(.path("huge.pdf")) }
// ...caller changes their mind...
task.cancel()
try await task.value // throws CancellationError; the child is already gone
```

**Dropping a stream.** `extractStream` and `search` follow the same rule.
Breaking out of the loop — or dropping the sequence without iterating it —
terminates and reaps the child promptly. A sequence dropped before the child
has even launched never spawns one:

```swift
for try await page in client.extractStream(.path("huge.pdf")) {
    if page.pageIndex > 10 { break } // child terminated and reaped here
}
```

**Timeouts.** The buffered methods (`extract`, `extractText`, `extractMarkdown`,
`getMetadata`, `hash`, `classify`, `verifyReceipt`) take an optional
`timeout:` in seconds. On expiry the child is terminated and reaped and the
call throws `TimeoutError`:

```swift
let doc = try await client.extract(.path("huge.pdf"), timeout: 30)
```

`timeout:` bounds the whole invocation from the caller's side. It is
independent of the CLI-level `--timeout` flag carried by
`BaseOptions`/`SearchOptions`: the flag is enforced inside the binary, while
the `timeout:` parameter is enforced by the SDK and works even if the binary
ignores its own flag or hangs. A non-positive or non-finite `timeout:` throws
`TimeoutError` without spawning anything.

For a deadline on a *stream*, run the loop in its own `Task` and cancel it —
the cancellation propagates to the child exactly as above:

```swift
let task = Task {
    for try await page in client.extractStream(.path("huge.pdf")) {
        print(page.pageIndex)
    }
}
try await Task.sleep(for: .seconds(30))
task.cancel() // child terminated and reaped if still running
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
# Verify pdftract is available and runnable
pdftract --help
```

### Version mismatch

The SDK does not enforce a binary version, so a mismatch is not caught for you.
To see which version you have installed:

```bash
pdftract doctor
```

If it differs from the version under [Binary version compatibility](#binary-version-compatibility),
install that release and make sure it is first on your PATH.

### Network failure

For remote URLs, check your network connection and TLS certificate chain.

## Conformance

This SDK passes 100% of the [pdftract conformance suite](https://github.com/jedarden/pdftract/tree/main/tests/sdk-conformance). The conformance report for this release is linked in the GitHub Release.

## License

MIT License - see LICENSE file for details.
