# bf-um4 — Fix Process/Pipe deadlock in generated `exec()` (Methods.swift)

## Root cause

`Sources/PdftractCodegen/Methods.swift`'s private `exec()` (used by every
non-streaming method: `Extract`, `ExtractText`, `ExtractMarkdown`,
`GetMetadata`, `Hash`, `Classify`, `VerifyReceipt`) called
`process.waitUntilExit()` **before** draining `outPipe`/`errPipe`. If a PDF's
`--json` output exceeds the OS pipe buffer (~64 KB on Linux), the child blocks
on `write()` while the parent blocks in `waitUntilExit()` — a classic
`Process`/`Pipe` deadlock that hangs the call indefinitely. `ExtractStream` and
`Search` already drain concurrently and were unaffected.

## Fix

Drain stdout/stderr via concurrent `Task`s **before** `waitUntilExit()`, then
`await` their values. Mirrors the streaming methods' concurrent-read style:

```swift
let stdoutTask = Task { outPipe.fileHandleForReading.readDataToEndOfFile() }
let stderrTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }
process.waitUntilExit()
let outData = await stdoutTask.value
let errData = await stderrTask.value
```

`readDataToEndOfFile()` returns non-throwing `Data`, so each `Task` is
`Task<Data, Never>` and `.value` needs only `await` (no `try`).

## Cross-repo dependency (canonical fix)

`Sources/PdftractCodegen/Methods.swift` is `GENERATED — do not edit manually`.
The canonical fix therefore landed in the **codegen template**, not here:

- **Repo:** `jedarden/pdftract`
- **File:** `templates/sdk-skeleton/swift/Sources/PdftractCodegen/Methods.swift.tera`
  (rendered into this repo's `Sources/PdftractCodegen/Methods.swift` by
  `pdftract sdk codegen --lang swift`)
- It propagates to this repo automatically on the next SDK regen.

This repo's `Methods.swift` was updated to the identical code in the same
change so the shipped SDK is not deadlocked while waiting for that regen. The
`exec()` region is static template text (no Tera `{{`/`{%}` directives), so it
was verified byte-for-byte identical to the regenerated output — this is **not**
a divergence that a future regen would revert; a regen now reproduces it
exactly.

## Out-of-scope finding (separate bead)

A full `pdftract sdk codegen --lang swift` regen currently **fails** on
`Methods.swift.tera` with `Filter 'lc_first' not found`. The template uses the
`lc_first` filter (ADR-1 lowerCamelCase work) but `crates/pdftract-cli/src/codegen.rs`
registers no such filter, and `camel_name` is still PascalCase. That is the
ADR-1 P2 "file upstream codegen-template fix" — a separate bead, intentionally
**not** touched here. It is why the Methods.swift refresh had to be applied to
the `exec()` region directly rather than via a full regen.

## Verification

- No Swift toolchain is installed on the build box, so the package could not be
  compile-tested here. Correctness was verified by inspection and by confirming
  the propagated code byte-matches the fixed template.
- The deadlock fix is purely about read ordering; the error-mapping path
  (`mapError(stderr, Int(process.terminationStatus))`) and exit-code handling
  are unchanged.
