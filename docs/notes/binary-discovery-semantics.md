# Binary discovery semantics

How the SDK resolves which `pdftract` executable to spawn: the PATH search,
its precedence relative to an explicit `binaryPath:`, and what happens when
nothing is found. Hand-written documentation (like
[codegen-refresh.md](codegen-refresh.md) and
[v1.2.0-binary-divergence-inventory.md](v1.2.0-binary-divergence-inventory.md))
— it documents the generated code but is not generator output, so it survives
every refresh. The README cannot carry this: `README.md` is one of the nine
generated paths, and anything written into it directly is overwritten on the
next codegen refresh (README wording changes belong in the upstream
`templates/sdk-skeleton/swift` Tera templates in jedarden/pdftract — see
[codegen-refresh.md](codegen-refresh.md)).

Source of truth: `Sources/PdftractCodegen/Methods.swift` — `init(binaryPath:)`
(lines 29-36), `resolvedBinaryPath` (lines 44-62), the buffered `exec` spawn
and wrap (lines 82, 171-173), and the two streaming spawn sites (each with its
own `Process` and its own catch, re-throwing raw). Behavior claims marked
**[probe 2026-11-25]** were verified empirically in `swift:5.10-jammy` (the
same image the CI gate and `scripts/definition-of-done.sh` use) by replicating
the generated code path verbatim; everything else is read directly from the
generated source. Companion test pins:
`Tests/PdftractTests/BinaryPathOverrideTests.swift` (explicit-path API,
pdfswift-30cb2045) and the lifecycle section of
`Tests/PdftractTests/ExitCodeMappingTests.swift` (buffered spawn-failure wrap,
pdfswift-e83b1b91).

## Resolution in one paragraph

`Pdftract(binaryPath:)` accepts an optional path and never throws at init.
An explicit path is used **verbatim** and the PATH search never runs. Without
one, the SDK scans the `PATH` environment variable once per process for an
**executable** entry named exactly `pdftract` and takes the first hit; the
result — including "not found" — is memoized. If discovery fails, the stored
path is the bare string `"pdftract"`, which Foundation's `Process` then treats
as a path relative to the current working directory at spawn time.

## Precedence: explicit `binaryPath:` wins outright

```swift
public init(binaryPath: String? = nil) {
    if let binaryPath = binaryPath {
        self.binaryPath = binaryPath          // verbatim; PATH scan never runs
    } else {
        self.binaryPath = Self.resolvedBinaryPath ?? "pdftract"
    }
}
```

- The explicit path is stored as given — no existence, executability, or
  absoluteness check at init. A path that cannot spawn is accepted silently
  and fails at the first method call with the lifecycle error described
  below.
- "Skips the PATH search entirely" is literal: `resolvedBinaryPath` is a
  `static let`, and a `static let` is initialized lazily on first access —
  which only happens in the nil branch. Passing an explicit path means the
  scan never executes, not that it executes and loses.
- All three spawn sites read the same stored `binaryPath` — the buffered
  `exec` and the producer Tasks of `extractStream` and `search`, each of
  which builds its own `Process`. That the override reaches all three is
  pinned by `BinaryPathOverrideTests` (one argv-capture test per site).

## What the PATH search actually does

`resolvedBinaryPath`, in order:

1. **Read** `ProcessInfo.processInfo.environment["PATH"]`; unset or empty →
   no entries at all (an empty string splits to `[]`).
2. **Split** on `:` — Linux only. The generated code guards
   `#if os(Linux)` for the `:` separator and splits on `;` in the `#else`
   branch, so on Apple platforms the entire PATH string becomes a single
   candidate (`<whole-PATH-string>/pdftract`) and discovery effectively never
   resolves there. This is current generated behavior, verified by source
   reading only (no Apple host in this workspace); any fix belongs in the
   upstream `Methods.swift.tera` template, not in this repo's generated file.
3. **Drop empty entries.** `String.split` omits empty subsequences by
   default, so `PATH="a::b"` yields entries `a`, `b` — **probe 2026-11-25**.
   Unlike shell PATH semantics, an empty entry does *not* mean "try the
   current directory" during the scan.
4. **No expansion.** Entries are used literally: no `~` expansion, no
   variable expansion (**probe 2026-11-25**: `~/pdftract` fails
   `isExecutableFile` even when `$HOME/bin/pdftract` exists).
5. **Candidate per entry:** `<entry>/pdftract` via `NSString.path`. A
   *relative* PATH entry produces a relative candidate resolved against the
   process CWD at scan time (`PATH=bin` → candidate `bin/pdftract`).
6. **Acceptance check:** `FileManager.isExecutableFile(atPath:)` — POSIX
   `X_OK` on the path as-is, following symlinks. **[probe 2026-11-25]**
   matrix: executable file (0755) → accepted; file without the x bit (0644)
   → rejected (the source comment is explicit: a non-executable file with
   the right name is skipped rather than selected only to fail confusingly
   at `exec()`); symlink to an executable → accepted; nonexistent →
   rejected. One sharp edge: a **directory** named `pdftract` with the
   execute bit set *passes* `X_OK` and is selected (**probe 2026-11-25**);
   spawning it then fails with the standard lifecycle error (Foundation
   raises `NSCocoaErrorDomain` code 4 at `process.run()` — same
   `localizedDescription` text as the not-found case, so the wrapped
   client-side error looks identical).
7. **First match wins**, in declared PATH order — later entries are never
   consulted once one resolves.
8. **Memoized for the process lifetime** in a `static let`: atomically lazy,
   thread-safe (Swift guarantees the initializer runs once), and the
   **negative result is cached too**. Consequences:
   - Installing the binary (or fixing a PATH entry) after the first `init`
     in a process has no effect until the process restarts.
   - The environment snapshot is taken at scan time; mutating the process's
     own `PATH` later does not re-trigger anything.
   - Discovery is a stat at scan time, not a reservation: a binary present
     at scan and deleted before the first call produces the not-found
     failure below (TOCTOU in the caller's favor is impossible — nothing
     re-checks).

## Environment-variable override: none

The only environment variable the SDK consults is `PATH` itself (the sole
`environment[...]` read in `Sources/` is the one in `resolvedBinaryPath`;
the `CONFORMANCE_SUITE` variable belongs to the test suite, not the SDK).
There is no `PDFTRACT_BINARY`-style override, no settings file, and no
compile-time default beyond the `"pdftract"` fallback. The explicit
`binaryPath:` parameter is the only override mechanism. Adding an env-var
override would be a generated-code change — an upstream
`templates/sdk-skeleton/swift/Methods.swift.tera` edit, and per
[codegen-refresh.md](codegen-refresh.md) it lands in this repo only via a
codegen refresh, not by hand.

## Not-found behavior

Discovery failure never surfaces at init. `Pdftract()` with nothing on PATH
constructs normally, storing the literal string `"pdftract"`:

```swift
self.binaryPath = Self.resolvedBinaryPath ?? "pdftract"
```

What that string does at call time — Foundation `Process` does not perform
its own PATH search; it treats `executableURL` verbatim, and a relative path
resolves against the **current working directory** of the embedding process
at spawn:

- **Buffered methods** (`extract`, `extractText`, `extractMarkdown`,
  `getMetadata`, `hash`, `classify`, `verifyReceipt`): `process.run()`
  throws, and the generic catch wraps it — **probe 2026-11-25** for the
  exact text, wrap shape pinned by the `ExitCodeMappingTests` lifecycle
  section:
  - thrown type: the **plain base `PdftractError`** (not a subclass —
    deliberately not `TimeoutError`, which is reserved for children that
    actually ran);
  - `exitCode == -1` (the client-side convention);
  - message: `Failed to execute pdftract: ` + the Foundation
    `localizedDescription`. On Linux with swift-corelibs-foundation that
    currently reads:
    `Failed to execute pdftract: The operation could not be completed. The file doesn’t exist.`
    (the wrapped failure is `NSCocoaErrorDomain` code 260,
    `NSFileReadNoSuchFileError`).
- **Streaming methods** (`extractStream`, `search`): each producer Task has
  its own `try process.run()` and its own catch, which re-throws the raw
  Foundation `NSError` **unwrapped** — `NSCocoaErrorDomain` 260 here — so it
  is **not** a `PdftractError`, and the README's own
  `catch let error as PdftractError` example would *not* catch it. The
  iteration finishes by throwing, yields nothing, never hangs. Pinned by
  `BinaryPathOverrideTests` (the negative type assertion is deliberate: when
  a regeneration aligns streaming with the buffered wrap, that test fails
  and forces a conscious update of the pin and the README paragraph).
- **The CWD gotcha:** because the fallback is a relative path, "not found on
  PATH" does **not** mean every call throws. If the process's current
  working directory happens to contain an executable file named `pdftract`,
  *that file runs* (**probe 2026-11-25**: stub in CWD spawned, exit 0). The
  same is true of any relative path passed explicitly via `binaryPath:`.
  Prefer absolute paths when pinning a binary.

## What this doc is for

The README (generated) says only "The SDK will search for `pdftract` on your
PATH" and shows `Pdftract(binaryPath:)`; the "custom path used verbatim"
paragraph (added with the pdfswift-30cb2045 test bead, commit 64c6027d)
covers the explicit-path failure shapes but not the discovery algorithm
itself, the no-override answer, or the discovery-failure fallback documented
here.
Consumers needing any of that get it from this file. If the upstream
templates ever change discovery (macOS separator fix, env-var override,
search-order changes), regenerate per [codegen-refresh.md](codegen-refresh.md)
and update this file in the same change — it documents the generated source,
not an independent spec.
