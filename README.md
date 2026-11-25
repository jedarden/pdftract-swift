# pdftract-swift

Swift SDK for pdftract - PDF extraction and analysis for server-side Swift.

> [!IMPORTANT]
> **This repository is auto-generated.** The Swift sources, tests,
> `Package.swift`, this README, and the root [`GENERATED`](GENERATED) marker
> are all emitted by the codegen pipeline in
> [jedarden/pdftract](https://git.ardenone.com/jedarden/pdftract)
> (`templates/sdk-skeleton/swift/*.tera`); the
> [github.com mirror](https://github.com/jedarden/pdftract-swift) is
> read-only.
>
> **Do not hand-edit generated files.** Changes to `Sources/`, `Tests/`,
> `Package.swift`, or this README are drift: the next codegen refresh
> silently reverts them. Fix the templates in jedarden/pdftract, then
> regenerate this drop.
>
> Bug reports and pull requests go to
> [jedarden/pdftract](https://git.ardenone.com/jedarden/pdftract), not this
> repo. The full refresh procedure — generator invocation, validation, and
> the provenance stamp — is documented in
> [docs/notes/codegen-refresh.md](docs/notes/codegen-refresh.md).

## Platform Support

**Supported**: macOS 13+, Linux (server-side use only)
**Unsupported**: iOS (Apple does not allow spawning subprocesses in App Store apps)
**Toolchain**: Swift 5.10+ — the `swift-tools-version` declared in `Package.swift`

**Using pdftract from an iOS app**: the SDK drives the `pdftract` binary by
spawning it as a subprocess, which iOS forbids in App Store apps — so the SDK
cannot run inside an iOS app, and none of its APIs start a server. The
supported pattern runs the pdftract binary's own `serve` subcommand on a
macOS/Linux backend and calls it over HTTP from the app; the SDK is not
involved on the iOS side.

Start the server on the backend (binds `127.0.0.1:8080` by default; pass
`--bind` to change):

```bash
pdftract serve
```

`serve` accepts the PDF as a `multipart/form-data` upload in a `file` field
and returns the same JSON document envelope `pdftract extract --json` prints
(`schema_version`, `fingerprint`, `metadata`, `pages`, `outline`, `errors`,
...), with the server also filling `metadata.cache_status` and an
`X-Pdftract-Cache` response header:

```bash
curl -F file=@document.pdf http://127.0.0.1:8080/extract
```

From the app, plain `URLSession` is enough — the only hand-rolled part is the
multipart body:

```swift
let boundary = "pdftract.\(UUID().uuidString)"
var request = URLRequest(url: URL(string: "https://pdftract.backend.example/extract")!)
request.httpMethod = "POST"
request.setValue("multipart/form-data; boundary=\(boundary)",
                 forHTTPHeaderField: "Content-Type")
var body = Data()
func part(_ s: String) { body.append(s.data(using: .utf8)!) }
part("--\(boundary)\r\n")
part("Content-Disposition: form-data; name=\"file\"; filename=\"document.pdf\"\r\n")
part("Content-Type: application/pdf\r\n\r\n")
body.append(pdfData)                       // the PDF bytes to extract
part("\r\n--\(boundary)--\r\n")
request.httpBody = body
let (data, _) = try await URLSession.shared.data(for: request)
// `data` decodes to the document envelope: `pages`, `metadata`, ...
```

Other endpoints: `POST /extract/text` (plain text), `POST /extract/stream`
(NDJSON frames), and `GET /health` (`{"status":"ok","version":"..."}`).
Optional form fields mirror the extract flags: `pages`, `ocr_language`,
`ocr_dpi`, `full_render`, `markdown_anchors`, `receipts`, `no_cache`, and
`max_decompress_gb`. Errors return a 4xx/5xx status with a JSON body of
`error`, `message`, and optional `hint`.

`serve` has no built-in authentication — bind it to loopback or a private
interface and terminate auth at a reverse proxy before exposing it to
devices (the CLI prints the same warning at startup). Cleartext `http://`
from an iOS device also needs an App Transport Security exception, which is
one more reason to put HTTPS in front of the server. Run `pdftract serve
--help` on the backend for the full option list.

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

The complete field set every decoded result carries — `Document`,
`Metadata`, `Page`, `Span`, `Block`, and the rest — is documented in
[Result types](#result-types) below.

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

### Flag-like paths and patterns

Values the SDK hands to the pdftract CLI are never misparsed as CLI flags,
even when they begin with `-`. Every method separates the CLI's own options
from caller-supplied values with the conventional end-of-options marker `--`,
so a file literally named `-report.pdf`, a search pattern like `-5%`, a URL,
and a receipt path all reach the CLI verbatim as positional values. On the
command line the same invocations read
`pdftract extract --json -- -report.pdf` and
`pdftract grep -- -5% document.pdf`.

Without that separator the CLI's flag parser would claim such values: with
the released CLI, `grep -js` is parsed as `--threads` with the value `s` (a
usage error), and a bare `-i` pattern would silently flip case-sensitivity
instead of being searched for. Nothing is rejected and nothing needs escaping
on your side — the separator is always emitted, so behavior does not depend
on the value. The same rule covers `Source.bytes` (whose spill path the SDK
controls), `.url` values, and the two positional paths of `verifyReceipt`.

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

`category` is one of ten fixed document-type strings — the classifier's whole
output vocabulary, never free text:

| `category` | Document type |
|---|---|
| `invoice` | Commercial transaction request for payment |
| `receipt` | Proof of payment |
| `contract` | Legal agreement between parties |
| `scientific_paper` | Academic research article (abstract, references) |
| `slide_deck` | Presentation slides (PowerPoint/PDF export) |
| `form` | Fillable fields, structured data entry |
| `bank_statement` | Financial account statement |
| `legal_filing` | Court or legal filing |
| `book_chapter` | Book excerpt with chapter structure |
| `unknown` | Fallback when no profile matches |

`confidence` is not a percentage: it is a `Double` in the closed range
`0.0...1.0` — the fraction of the winning profile's weighted predicates the
document matched, so 1.0 means every predicate matched and 0.0 means none
did. Profiles also carry individual acceptance thresholds: when even the
best-scoring profile falls below its own threshold, `category` is `unknown`
and `confidence` carries that best below-threshold score rather than 0.0 —
`unknown` is a real classification result, not an error, and a low
confidence is not a zero confidence.

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

## Result types

Every decoded result is a plain `Codable` and `Sendable` struct. The tables
below are each type's complete field set; where the Swift property name
differs from the JSON key it decodes, the key is given in parentheses. The
decoder ignores JSON keys a type does not declare, so extra fields in the
CLI's output are dropped, never surfaced.

### Document

Returned by `extract` — one `Page` per document page, in document order,
plus the document's `metadata`.

| Field | Type | Description |
|---|---|---|
| `schemaVersion` (`schema_version`) | `String` | Version of the extraction output schema (currently `"1.0"`) |
| `pages` | `[Page]` | One entry per page, in document order |
| `metadata` | `Metadata` | Document metadata — see the table below |

The CLI's full JSON envelope carries more top-level keys than `Document`
declares (`extraction_quality`, `outline`, `errors`, `links`, `form_fields`,
`signatures`, `threads`, `attachments`). None are typed by this SDK, so the
decoder drops them: those sections are not reachable through `extract`'s
return value.

### Metadata

Returned by `getMetadata`, and embedded in every `Document` and `Fingerprint`.
The fields map to the PDF information dictionary; a field is `nil` when the
PDF omits the corresponding entry.

| Field | Type | Description |
|---|---|---|
| `title` | `String?` | `/Title` — document title |
| `author` | `String?` | `/Author` — who created the document |
| `subject` | `String?` | `/Subject` — subject-matter summary |
| `keywords` | `[String]?` | The `/Keywords` entry |
| `creator` | `String?` | Authoring application (e.g. "Microsoft Word 2019") |
| `producer` | `String?` | PDF-writing library (e.g. "Acrobat Distiller") |
| `created` | `String?` | Creation date, as an ISO-8601 string |
| `modified` | `String?` | Last-modification date, as an ISO-8601 string |
| `pageCount` (`page_count`) | `Int` | Total number of pages |

### Page

| Field | Type | Description |
|---|---|---|
| `pageIndex` (`page_index`) | `Int` | **Zero-based** page index — the document's first page is `0` (see [Stream extraction](#stream-extraction-for-large-pdfs)) |
| `width` | `Double` | Page width in points (1/72 inch) |
| `height` | `Double` | Page height in points (1/72 inch) |
| `rotation` | `Int` | Page rotation in degrees clockwise: `0`, `90`, `180`, or `270` |
| `spans` | `[Span]` | Text spans — atomic runs of text with consistent font and styling |
| `blocks` | `[Block]` | Semantic blocks — paragraphs, headings, lists, tables, figures |

The CLI's page JSON also carries `page_number`, `page_label`, `type`,
`tables`, and `annotations`; none are declared here, so the decoder drops
them.

### Span

| Field | Type | Description |
|---|---|---|
| `text` | `String` | The extracted text |
| `bbox` | `[Double]` | Bounding box `[x0, y0, x1, y1]` in PDF user-space points — `(x0, y0)` is the bottom-left corner and `(x1, y1)` the top-right |
| `font` | `String` | Font name or identifier |
| `size` | `Double` | Font size in points |
| `confidence` | `Double?` | Extraction confidence 0.0–1.0; present when the text came from OCR or the extraction was otherwise uncertain, `nil` when confidence does not apply |

### Block

| Field | Type | Description |
|---|---|---|
| `kind` | `String` | Block type — commonly `paragraph`, `heading`, `list`, `table`, or `figure`. A plain string, not a Swift enum, so a kind this list does not name passes through unchanged |
| `text` | `String` | The block's text — the concatenation of the text of its spans |
| `bbox` | `[Double]` | Same `[x0, y0, x1, y1]` convention as `Span` |
| `level` | `Int?` | Heading level (1–6) for `heading` blocks, nesting depth for `list` blocks; `nil` for other kinds |

### Match

Returned by `search` — see [Search](#search) for usage.

| Field | Type | Description |
|---|---|---|
| `text` | `String` | The matched text |
| `page` | `Int` | **Zero-based** page index of the page containing the match |
| `bbox` | `[Double]` | Location of the match — same `[x0, y0, x1, y1]` convention as `Span` |
| `context` | `Context` | Nested `Match.Context` with `before` and `after`: the text immediately surrounding the match |

### Fingerprint

Returned by `hash`.

| Field | Type | Description |
|---|---|---|
| `hash` | `String` | SHA-256 hex digest of the document content |
| `pageCount` (`page_count`) | `Int` | Total number of pages |
| `fastHash` (`fast_hash`) | `String` | BLAKE3 hex digest of the first 10 KB — cheap to compare for a quick inequality check |
| `metadata` | `Metadata` | Document metadata — same type as above |

### Classification

Returned by `classify`; `category` and `confidence` semantics (the
ten-category vocabulary and the 0.0–1.0 range) are covered in
[Classify document](#classify-document).

| Field | Type | Description |
|---|---|---|
| `category` | `String` | One of the ten fixed document-type strings |
| `confidence` | `Double` | Match score of the winning profile, 0.0–1.0 |
| `tags` | `[String]` | Tags accompanying the classification |
| `heuristics` | `[String: Bool]` | Individual feature detections: heuristic name → whether it matched |

### ReceiptVerificationResult

Returned by `verifyReceipt`; the verification flow and the thrown-error
mapping are covered in [Verify receipt](#verify-receipt).

| Field | Type | Description |
|---|---|---|
| `status` | `String` | Raw verification status from the CLI: `ok`, `fingerprint_mismatch`, `bbox_mismatch`, or `content_mismatch` |
| `valid` | `Bool` | Computed property: `status == "ok"` |
| `bestIou` (`best_iou`) | `Double` | Best span intersection-over-union observed during verification |
| `expectedContentHash` (`expected_content_hash`) | `String?` | Content hash the receipt expected |
| `actualContentHash` (`actual_content_hash`) | `String?` | Content hash the verification recomputed |
| `reason` (decodes the CLI's `error` key) | `String?` | The CLI's explanation of which check failed; absent on success |

`Receipt` itself carries a single field, `data: String` — the path of the
receipt JSON file handed to the CLI (see [Verify receipt](#verify-receipt)).

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

### Error hierarchy

The exit-code errors in the first table plus `TimeoutError` are all
`final class` **subclasses of `PdftractError`**. The base class carries the
fields every handler needs — `message: String` and `exitCode: Int` — and
each subclass adds nothing: it exists so a caller can catch that one
failure. The `PdftractError` row itself (`other`) is the base class thrown
directly, for a non-zero exit code outside the table or a spawn failure
(exit code `-1`).

That relationship is what makes the single `catch let error as PdftractError`
above cover every `pdftract` failure: Swift's `as` pattern matches
subclasses, so one clause catches `CorruptPdfError`, `EncryptionError`, …,
`TimeoutError`, and unmapped exit codes alike.

Two throwables sit outside the hierarchy and are **not** caught by it:

- **`CancellationError`** — the standard-library struct thrown when the
  surrounding `Task` is cancelled; it shares no type with `PdftractError`.
- **`MalformedStreamError`** — a `struct`, not a `PdftractError` subclass,
  so a base-type catch will not bind it. Current SDK methods never throw
  it: undecodable NDJSON lines are surfaced through `onSkippedLine:`
  instead (see the streaming section below).

To treat one failure mode differently, catch the specific subclass
**before** any base-class catch — Swift tries `catch` clauses in order, so
a base `PdftractError` clause placed first would swallow every subclass:

```swift
do {
    let doc = try await client.extract(.path("document.pdf"))
} catch let error as EncryptionError {
    promptForPassword() // most specific clauses first
} catch let error as TimeoutError {
    retryOrFail() // deadline expiry — exit code -1
} catch let error as PdftractError {
    // CorruptPdfError, TlsError, … and every unmapped exit code
    print("pdftract failed (code \(error.exitCode)): \(error.message)")
}
```

Because the subclasses add no stored properties, switching on
`error.exitCode` inside a single base-class catch is equivalent to the
multi-clause form.

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
