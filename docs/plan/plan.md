# pdftract-swift — Plan

## What this repo is

`pdftract-swift` is the Swift SDK for [pdftract](https://github.com/jedarden/pdftract) — a
thin, **entirely auto-generated** wrapper (see repo-root `GENERATED` marker) that spawns the
`pdftract` CLI binary as a subprocess and maps its stdout (JSON / NDJSON) onto typed Swift
models. It ships as a SwiftPM library (`Pdftract` product) for server-side Swift (macOS 13+,
Linux); iOS is explicitly unsupported because App Store apps can't spawn subprocesses — iOS
consumers are told to talk to `pdftract serve` over HTTP instead.

There is no separate `docs/notes/` or `docs/research/` content yet and no prior `plan.md` — this
file starts honestly, at the point this artifact-improvement audit found the repo, rather than
reconstructing a retroactive history. See `README.md` for the full usage/API reference; this
file is for decisions and forward-looking notes.

## Current shipped state (as of 2026-07-20 audit)

- Single commit (`717e5f3`, "Initial commit: Swift SDK for pdftract v1.1.0"), `main` branch,
  working tree clean.
- `.codegen-version` = `1.1.0`; `Sources/PdftractCodegen/*` and
  `Sources/Pdftract/Pdftract.swift` are marked auto-generated ("do not edit manually — use the
  code generator to refresh").
- No git tags exist on this repo (checked both local and `origin` after `git fetch --tags`).
- `origin` remote is `https://github.com/jedarden/pdftract-swift.git` directly — this repo does
  not currently follow the workspace's Forgejo-primary / GitHub-mirror hosting convention (see
  follow-up beads under ADR-1 below).

## ADR-1: 2026-07-20 — CI-gated build/release pipeline for the generated Swift SDK, plus an interim naming-compatibility shim

### Context

This repo is 100% code-generated from the `pdftract` codegen pipeline and has **no CI
configured anywhere** (no GitHub Actions — disabled workspace-wide per policy — and no Argo
Workflows `WorkflowTemplate` exists for it in `declarative-config`'s `k8s/iad-ci/argo-workflows/`
either). Auditing the shipped code surfaced two release-blocking defects that nothing would
have caught before they reached the public repo:

1. **No git tags exist.** `README.md`'s own installation instructions say:
   ```swift
   .package(url: "https://github.com/jedarden/pdftract-swift", from: "1.1.0")
   ```
   SwiftPM's `from:` version requirement resolves against **semver git tags**. `git tag -l` and
   `git fetch origin --tags` both return nothing — there is no `1.1.0` tag (or any tag) on this
   repo. Following the README's own instructions to depend on this package **fails outright**.

2. **Every generated public method name is PascalCase, but every consumer of the API uses
   lowerCamelCase — and they don't match.** `Sources/PdftractCodegen/Methods.swift` defines
   `Extract`, `ExtractText`, `ExtractMarkdown`, `ExtractStream`, `Search`, `GetMetadata`, `Hash`,
   `Classify`, `VerifyReceipt`. Both `README.md`'s usage examples (`client.extract(...)`,
   `client.extractText(...)`, etc.) and `Tests/PdftractTests/ConformanceTests.swift`
   (`client.extract`, `client.getMetadata`, `client.verifyReceipt`, ...) call the lowerCamelCase
   forms exclusively — Swift is case-sensitive, so **every README code sample and the entire
   conformance test target fail to compile** against the code as generated. Grepping confirms
   100% divergence: zero overlap between the method names defined and the method names called
   anywhere else in the repo.

Because the affected files are marked `GENERATED — do not edit manually`, a hand-fix inside
`Sources/PdftractCodegen/` would silently vanish on the next codegen refresh, and because there
is no build step run anywhere (no CI at all), a regenerated drop with the same bug would ship to
GitHub undetected exactly as this one did.

### Decision

1. Stand up an Argo Workflows CI template for this repo (`pdftract-swift-build`, alongside the
   existing `forge-ci` / `needle-ci` pattern in `declarative-config`'s
   `k8s/iad-ci/argo-workflows/`) that runs `swift build` and `swift build --build-tests` on every
   push to `main`, on Linux. This is the first CI this repo has ever had.
2. Treat "cut a release" as a CI-gated action rather than a manual/never-done one: a semver git
   tag only gets pushed after the build-and-test-compile step above is green. This directly
   fixes defect #1 (no tag exists today) as a side effect of making tagging a real, verifiable
   step instead of an implied-but-skipped one.
3. Ship a small **hand-written, explicitly non-generated** compatibility file (e.g.
   `Sources/Pdftract/CompatibilityAPI.swift`, outside the `PdftractCodegen` target and outside
   the `GENERATED` marker's scope) that exposes the lowerCamelCase names the README and the
   conformance suite already promise (`extract`, `extractText`, `extractMarkdown`,
   `extractStream`, `search`, `getMetadata`, `hash`, `classify`, `verifyReceipt`), each
   forwarding to the corresponding generated PascalCase method. This unblocks every existing
   doc example and the test target immediately, without touching generated code, and survives
   the next codegen refresh.
4. File the real fix upstream: the `pdftract` codegen templates (in `jedarden/pdftract`, not
   this repo) should emit lowerCamelCase method names directly, per Swift API Design
   Guidelines — methods/functions are lowerCamelCase, only types are UpperCamelCase. Once that
   ships and this repo regenerates, the compatibility shim in (3) becomes dead code and should
   be deleted in the same PR that picks up the regenerated output.

### Alternatives Considered

- **Hand-edit `Methods.swift` to rename to lowerCamelCase, skip CI.** Rejected — violates the
  `GENERATED` contract; the very next codegen refresh silently reintroduces both defects with no
  detection mechanism, which is exactly how this shipped in the first place.
- **"Fix" the docs/tests to call the actual PascalCase names instead of adding a shim.**
  Rejected — PascalCase methods (`Extract`, `GetMetadata`, ...) are not idiomatic Swift (Swift
  API Design Guidelines specify lowerCamelCase for methods; only types are UpperCamelCase).
  Codifying the mismatch into the docs would "fix" the compile error while permanently shipping
  a non-idiomatic public API that reads oddly next to every other Swift package.
- **Just push a `v1.1.0` tag now, skip CI entirely.** Rejected — would fix installability but
  tag a commit whose own test target doesn't compile; a tagged "release" that's silently broken
  is worse than an honestly-absent one, because it looks shipped.
- **Do nothing and wait for the next scheduled codegen refresh to happen to fix it.** Rejected —
  there's no evidence a refresh is scheduled, and even if one lands, without CI (point 1) nothing
  would verify it actually fixed the mismatch rather than, say, changing it in some other
  incompatible way.

### Consequences

- Positive: establishes a reusable Argo Workflows pattern for any future generated-SDK repos
  (e.g. if a Python or JS `pdftract` SDK is added later), not just this one.
- Positive: the compatibility shim unblocks real usage today, is isolated to one clearly-labeled
  non-generated file, and is trivially removable in one PR once upstream is fixed.
- Cost: this repo needs a Swift-capable build image for Argo Workflows, which doesn't exist in
  the current template set yet and has to be created.
- Debt: until upstream is fixed, there are two names per method (generated PascalCase +
  hand-written lowerCamelCase forwarding shim) — must be tracked so it doesn't get forgotten.
  Docs should only ever show the lowerCamelCase form.
- Until this ships, `swift build --build-tests` fails on `main` today — see the P0 beads filed
  against this ADR.

### Follow-up work (beads filed 2026-07-20, label `artifact-improvement`)

- Add the lowerCamelCase compatibility shim (point 3 above) — P0, unblocks everything else.
- Add the Argo Workflows CI template (point 1 above) — P0.
- Push the `v1.1.0` tag once CI is green (point 2 above) — P1, depends on the previous two.
- File the upstream codegen-template fix against `jedarden/pdftract` (point 4 above) — P2,
  cross-repo, tracked here since the defect was found here.

## Other improvement ideas considered (not the ADR — filed as beads instead)

- `Sources/PdftractCodegen/Methods.swift`'s private `exec()` (used by every non-streaming
  method: `Extract`, `ExtractText`, `ExtractMarkdown`, `GetMetadata`, `Hash`, `Classify`,
  `VerifyReceipt`) calls `process.waitUntilExit()` **before** draining `outPipe`. If a PDF
  produces more JSON output than the OS pipe buffer holds (large/multi-page documents — the
  exact case this SDK's `extractStream` exists to handle), the child process blocks writing to
  stdout while the parent blocks waiting for it to exit: a classic `Process`/`Pipe` deadlock.
  `ExtractStream` and `Search` already read concurrently while the process runs and don't have
  this problem — `exec()` should use the same pattern.
- `Sources/PdftractCodegen/Types.swift`'s `Source.bytes(_:)` case writes the PDF bytes to a
  temp file (`FileManager.default.temporaryDirectory`) for the CLI to read but never deletes it
  afterward — a temp-file leak, and for sensitive documents passed as in-memory bytes,
  unexpected disk residue.
- `Pdftract.findBinary()` rescans the entire `PATH` on every `Pdftract()` init and only checks
  `FileManager.fileExists`, not that the file is actually executable.
- README's "Version mismatch" section claims "The SDK will refuse to invoke mismatched binary
  versions" — there is no such check anywhere in the code (`.codegen-version` is never read at
  runtime). Either implement the check or remove the claim.
- `ExtractStream` and `Search` silently drop lines that fail JSON decoding (`// Skip malformed
  lines`) with no signal to the caller — a truncated or partially-corrupt CLI output looks
  identical to a clean one.
- `VerifyReceipt` compares raw stdout to the literal string `"true"` instead of parsing
  structured JSON like every other method — fragile, and discards any reason/detail the CLI
  might report on failure.
