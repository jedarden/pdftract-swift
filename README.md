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

### Extract from in-memory Data

```swift
let data = try Data(contentsOf: pdfFileURL) // or any PDF bytes you already hold
let doc = try await client.extract(.bytes(data))
```

Every method that takes a `Source` also accepts `.bytes` with in-memory `Data`,
so documents received over the network or built in memory never need a file of
their own. The SDK spills the bytes to a private temporary file for the pdftract
process and deletes it when the call finishes — success, error, timeout, or
cancellation — so no manual cleanup is required. (`verifyReceipt` is the one
method that takes no `Source` at all — see [Verify receipt](#verify-receipt)
below for why.)

### Extract with OCR

```swift
let options = ExtractOptions(
    ocrLanguage: "eng",
    ocrThreshold: 0.7
)
let doc = try await client.extract(.path("scanned.pdf"), options: options)
```

The two OCR fields carry different contracts.

`ocrLanguage` names the Tesseract language pack or packs the OCR engine
loads, forwarded verbatim as one `--ocr-language` value. Codes follow
Tesseract's pack naming — ISO 639-2/3 codes such as `"eng"`, `"fra"`,
`"deu"`, `"spa"`, `"jpn"`, plus script-qualified names like `"chi_sim"`.
Multiple languages go in one comma-separated string (`"eng,fra"`); the CLI
splits on the commas and loads every named pack. Nothing is validated on the
client side.

A pack the running machine does not have is not an error: each missing code
emits an `OCR_LANGUAGE_UNAVAILABLE` diagnostic and extraction continues with
the packs that are installed; if none of the requested packs is installed,
the CLI falls back to `"eng"`, and only when even that fallback is missing
does extraction fail. Run `pdftract doctor tesseract-langs` to list what a
machine can load — the published Docker images differ (`pdftract:default`
bundles no packs, `pdftract:ocr` the common set, `pdftract:full` all 100+).

`ocrThreshold` is a confidence floor in the range 0–1 (the SDK conformance
spec pins `minimum: 0, maximum: 1`). The SDK clamps nothing: your value is
forwarded verbatim as `--ocr-threshold <v>`, so an out-of-range value is
never caught on the client side. No released pdftract binary accepts this
flag yet — the released CLI rejects `--ocr-threshold` as an unexpected
argument (exit 2) whatever the value — so the field currently expresses
intent ahead of binary support, and passing it makes today's CLI reject the
whole call.

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

`extractStream` returns an `AsyncThrowingStream<Page, Error>`, so iterate it
with `for try await` — extraction failures throw from the loop (see
[Errors from the streaming methods](#errors-from-the-streaming-methods)):

```swift
for try await page in client.extractStream(.path("large.pdf")) {
    print("Page \(page.pageIndex + 1): \(page.blocks.count) blocks")
}
```

`page.pageIndex` is a **zero-based** page index: the document's first page is
page `0`, and the last page yielded is page `metadata.pageCount - 1`, where
`metadata.pageCount` is the total page count from `getMetadata` (see
[Get metadata](#get-metadata)). Human-readable page numbers are
`page.pageIndex + 1`, as printed in the example.

### Search

`search` returns an `AsyncThrowingStream<Match, Error>` and throws the same
way:

```swift
for try await match in client.search(.path("document.pdf"), "invoice") {
    print("Found on page \(match.page + 1): \(match.text)")
    print("  Context: ...\(match.context.before)[\(match.text)]\(match.context.after)...")
}
```

`match.page` is a **zero-based** page index — the same convention as
`Page.pageIndex` in `extractStream` — so the document's first page is page `0`.
Human-readable page numbers are `match.page + 1`.

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

A receipt is produced at extraction time: run `pdftract extract` with
`--receipts lite` (or `--receipts svg`) and every span and block in the output
JSON carries a `receipt` object alongside its text. Save that object to a file
— that JSON file is what a verification consumes:

```json
{
  "pdf_fingerprint": "pdftract-v1:a7f3...",
  "page_index": 14,
  "bbox": [220.0, 412.0, 412.0, 432.0],
  "content_hash": "sha256:9b21...",
  "extraction_version": "1.2.0"
}
```

`Receipt(data:)` wraps the **path** to such a receipt JSON file. The string is
handed to the `verify-receipt` CLI unchanged as its `RECEIPT.json` positional
argument, which the CLI reads from disk — so a receipt JSON *string* held in
memory must be written to a file first; the CLI's `--inline` and stdin forms
are not reachable through the SDK. All five fields above are required
(`svg_clip`, present in `--receipts svg` output, is optional).

```swift
let receipt = Receipt(data: "/tmp/span-14.receipt.json")
let result = try await client.verifyReceipt("/path/to/receipt.pdf", receipt: receipt)
print("Valid: \(result.valid)")
```

The PDF parameter is a plain path string rather than a `Source` — the one
method in this SDK without a `Source` parameter. That is deliberate:
`verify-receipt` reads the PDF from local disk only and has no URL form
(unlike `extract`, whose URL inputs the binary fetches itself), while
`Source` advertises `.url` to every method that accepts it — so accepting
`Source` here would advertise a case the CLI could not honor. In-memory PDF
bytes work the same way as the in-memory receipt JSON above: write them to
a file and pass its path.

Verification re-extracts `page_index` from the PDF and checks, in order: the
PDF fingerprint matches the receipt's, some span overlaps the receipt's `bbox`
with IoU ≥ 0.9, and that span's NFC-normalized SHA-256 equals `content_hash`.
The receipt's `extraction_version` must match the binary's major **and** minor
version or verification fails before any of those checks run (a patch-version
difference is allowed, with a warning on stderr).

The method returns only when the receipt verifies, so a returned
`result.valid` is always `true` and `result.reason` (which decodes the CLI's
`error` field — absent on success) is always `nil`. Every failed verification
throws instead of returning a `valid == false` result:

- `ReceiptVerifyError` — the PDF fingerprint check failed (CLI exit 10)
- `PdftractError` — no span met the bbox IoU threshold (exit 11), the
  best-overlap span's text hashed differently (exit 12), the PDF or the
  receipt file was unreadable, or receipt and binary major/minor versions
  differ (all exit 1)

The CLI's structured failure report (its `verify-receipt --json` output on
stdout) is discarded when the SDK maps a non-zero exit, so the thrown error
carries the CLI's stderr — empty on the mismatch exits. Call the CLI directly
when you need the per-check detail.

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

A custom path is used verbatim — setting it skips the PATH search entirely. If
the path does not exist or is not executable, no child can spawn and there is no
CLI exit code to map: the buffered methods (`extract`, `extractText`,
`extractMarkdown`, `getMetadata`, `hash`, `classify`, `verifyReceipt`) throw the
base `PdftractError` with exit code `-1` and a `Failed to execute pdftract: …`
message carrying the underlying spawn error. The streaming methods
(`extractStream`, `search`) finish their iteration by throwing that spawn error
unwrapped, with nothing yielded.

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

### Errors from the streaming methods

`extractStream` and `search` return `AsyncThrowingStream`s and throw the same
error types as the buffered methods — iterate them with `for try await`:

```swift
do {
    for try await page in client.extractStream(.path("maybe-corrupt.pdf")) {
        render(page) // every page the child emitted before failing still arrives
    }
} catch let error as PdftractError {
    print("Stream failed (code \(error.exitCode)): \(error.localizedDescription)")
}
```

A failure finishes the stream rather than interrupting it: the values the
child produced before dying are yielded to the loop first, and the mapped
error throws when the stream ends. A corrupt PDF that kills `pdftract`
halfway through emitting pages therefore surfaces as the already-decoded
pages followed by `CorruptPdfError` — never as a silently short stream. A
failure before the child produces any output (unreadable source, missing
binary, TLS failure on a remote URL) throws before the first value, so the
loop body never runs.

Lines the decoder cannot parse are deliberately **not** thrown — they are
reported through the `onSkippedLine:` callback so one malformed line cannot
masquerade as a failed extraction. An undecodable line passed over silently
would be indistinguishable from a PDF that simply had fewer pages.

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

## Concurrency

A single `Pdftract` instance may be shared across concurrency domains. The
client is a `Sendable` value type, so you can hold it in an actor, capture it
in `@Sendable` closures, and call it from any number of Tasks at once:

```swift
let client = Pdftract() // one shared instance — or one per actor, both fine

let total = try await withThrowingTaskGroup(of: Int.self) { group in
    for path in paths {
        group.addTask { try await client.extract(.path(path)).pages.count }
    }
    return try await group.reduce(0, +)
}
```

What makes that safe:

- **No per-instance mutable state.** The client stores only an immutable
  `binaryPath`. Everything a call needs — the child process, its pipes, its
  timeout and cancellation bookkeeping — is created inside that call and never
  shared with any other.
- **Concurrent calls are independent.** Each call spawns its own `pdftract`
  child; there is no ordering between concurrent calls beyond each child's own
  completion order, and per-call `timeout:` and `Task` cancellation affect only
  that call's child.
- **The one shared cache is thread-safe.** The PATH scan that resolves the
  `pdftract` binary runs at most once per process and is memoized in a
  `static let`, whose initializer Swift runs atomically and exactly once.

Everything the SDK hands back crosses concurrency domains just as freely —
models, options, and errors are all `Sendable`:

| Type | Notes |
|---|---|
| `Document`, `Page`, `Span`, `Block` | Decoded results |
| `Metadata`, `Match`, `Fingerprint`, `Classification` | Decoded results |
| `Receipt`, `ReceiptVerificationResult` | Decoded results |
| `Source`, `ExtractOptions`, `SearchOptions`, `BaseOptions`, `HashOptions` | Inputs |
| `PdftractError` and every subclass, `TimeoutError`, `MalformedStreamError` | Thrown errors |

The streaming methods are covered by the same contract: `extractStream` and
`search` yield `Sendable` values, and their `onSkippedLine` callback is typed
`@Sendable`, so a stream can be consumed on any task. Streams take no
`timeout:` — for a deadline, cancel the consuming `Task`
(see [Cancellation and timeouts](#cancellation-and-timeouts)).

## Options

### ExtractOptions

```swift
let options = ExtractOptions(
    ocrLanguage: "eng",           // Tesseract language pack code (see "Extract with OCR")
    ocrThreshold: 0.7,            // OCR confidence threshold, 0-1 (see "Extract with OCR")
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
