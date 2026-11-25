# pdftract-swift — Plan

## What this repo is

`pdftract-swift` is the Swift SDK for [pdftract](https://github.com/jedarden/pdftract) — a
thin, **entirely auto-generated** wrapper (see repo-root `GENERATED` marker) that spawns the
`pdftract` CLI binary as a subprocess and maps its stdout (JSON / NDJSON) onto typed Swift
models. It ships as a SwiftPM library (`Pdftract` product) for server-side Swift (macOS 13+,
Linux); iOS is explicitly unsupported because App Store apps can't spawn subprocesses — iOS
consumers are told to talk to `pdftract serve` over HTTP instead.

There was no prior `plan.md` — this file starts honestly, at the point the 2026-07-20
artifact-improvement audit found the repo, and grows by dated updates. The "Current shipped
state" section below was re-anchored to present tense on 2026-11-25 (pdfswift-e71c2c1e); the
audit-era snapshot it replaced is condensed into that section's history list. See `README.md`
for the full usage/API reference; this file is for decisions and forward-looking notes.

The hand-written `docs/notes/` set — everything here survives every codegen refresh:
[`codegen-refresh.md`](../notes/codegen-refresh.md) — how to regenerate this repo from the
pdftract codegen pipeline (which command emits which paths, `.codegen-version` lockstep with
binary releases, how to read `pdftract sdk validate` findings, the
fix-upstream-then-regenerate rule that ADR-1 depends on, and the CI map of which iad-ci
workflow runs where); [`sdk-release-runbook.md`](../notes/sdk-release-runbook.md) — the
manual tag-and-mirror release procedure; [`url-fetch-semantics.md`](../notes/url-fetch-semantics.md);
and the `probes/` TLS/fetch-probe harness fixtures.

## Current shipped state (re-anchored 2026-11-25, pdfswift-e71c2c1e)

**Hosting.** Forgejo-primary: `origin` =
`https://git.ardenone.com/jedarden/pdftract-swift.git`; GitHub
(`https://github.com/jedarden/pdftract-swift`) is the read-only mirror the README's install
snippet points consumers at, kept current by Forgejo's server-side push mirror. Local `main`
== `origin/main` (nothing unpushed) at this rewrite.

**Generated drop.** `.codegen-version` = `1.2.0` — the 1.2.0 regeneration of the pdftract
codegen pipeline (f72f9a5, then 84b1482 for the drop-before-iteration lifecycle-test fix from
pdftract `a2ed4c967`), subsequently refreshed from the same still-unlanded pdftract local-main
lineage: the pdfswift-8f868708 XCTSkip/probe fixes (61d59402), then the pdfswift-215641c8
Sendable/concurrency semantics (pdftract `ae0a158d`, landed here as a87876f8). All nine
generated paths carry the `GENERATED` marker ("do not edit manually — use the code generator
to refresh"; `docs/notes/codegen-refresh.md` is that instruction's "use the code generator"
half). `pdftract sdk validate` against the generator that produced the tree (ae0a158d)
reports zero `MODIFIED`/`MISSING` under generated paths — only the benign README
0.1.0-comparison artifact (validate has no `--version` flag and always compares against a
0.1.0 skeleton).

**Releases.** `v1.1.0` (annotated, → `01d83b0`) and `v1.2.0` (annotated, → `01a5b44`) are both
pushed to Forgejo `origin` and confirmed on the GitHub mirror (`ls-remote`, 2026-11-25), so
the README's `from: "1.2.0"` requirement resolves on the URL it names. Both were cut manually
per `docs/notes/sdk-release-runbook.md`, tagged only after the gate went green on the exact
tree — the release-cascade Swift slot (`sdk-swift-publish`) remains hard-off
(`when: 'false'`) pending the four runbook-listed fixes, and upstream pdftract still hasn't
cut a v1.2.0 release tag (only `v0.1.0-test`), so the cascade could not fire regardless.
pdfswift-3307a377's real-binary end-to-end verification stays retargeted to a 1.2.0-lineage
binary built from pdftract main.

**CI.** `pdftract-swift-build` (WorkflowTemplate in declarative-config
`k8s/iad-ci/argo-workflows/`, ArgoCD-owned/synced) auto-triggers on every push to `main` via
`pdftract-swift-ci-sensor` (argo-events; webhook → EventSource → Sensor → submit, proven by
bf-57b and re-proven post-Forgejo-migration 2026-09-25). Gate on `swift:5.10-jammy`:
`swift build` + `swift build --build-tests` + `swift test --skip ProcessLifecycleTests` — the
expanded gate from declarative-config `b947d7a35` (live 2026-11-25). The original two-suite
`--filter` lost its reason when the pdfswift-8f868708 XCTSkip guards made the binary-dependent
suites skip cleanly, while `ProcessLifecycleTests` still fails 3/6 in docker-class containers
for environment reasons (drop the `--skip` when pdfswift-b64f41eb lands). The gate has
verified teeth (bf-25c): reverting the lowerCamelCase API surface on a throwaway branch makes
`swift build --build-tests` exit 1, and it went green on three consecutive runs under load.
Latest proof (2026-11-25): the auto-triggered run `pdftract-swift-build-v7hq6` (auto-generated
name, no `-manual-` suffix) Succeeded — node exitCode 0, 03:27:46Z→03:35:04Z — against main
`5d805bb7`, and the same three-step gate re-run locally on a clean `git archive HEAD`
extraction of `5d805bb7`: 34 tests, 6 binary-dependent skips, 0 failures. Full CI map:
`codegen-refresh.md` → "What runs where (CI map)".

**Verification doctrine shipped.** ADR-1 is fully resolved (follow-up list below): the
compatibility shim shipped (6e19810) and was then deleted (d7009cb) once upstream emitted
lowerCamelCase directly (pdftract `54b432f8`); CI shipped and was verified with a negative
test; both semver tags shipped and were mirror-confirmed; the release runbook and the codegen
refresh guide are in-repo and current. The five bf-era CI/release beads (bf-3vc, bf-3fw,
bf-25c, bf-57b, bf-4mw) and their verification children (pdfswift-4aae6077,
pdfswift-a6304661) are closed on that evidence.

**Known-open themes (not shipped).** The generated client still cannot drive any released
pdftract binary — argv/JSON-schema/NDJSON-page-frame/zero-page protocol mismatch demonstrated
against v1.2.0, held at proposal pdfswift-ccccb2ff pending explicit admission. macOS 13+ is
declared-but-untested and the macOS path is believed broken outright: the generated
binary-discovery scan splits `PATH` on `;` off-Linux (`Methods.swift:34`), so a stock
colon-separated macOS PATH never resolves `pdftract` — full analysis and the
manual-macOS-host recipe: `codegen-refresh.md` → "Platform coverage". A queue of
README-semantics documentation beads (page-index conventions, hash/classify/receipt
semantics, streaming `try await` examples, OCR fields, error hierarchy, …) remains open, each
scoped in its own bead.

### Superseded snapshots (condensed from the pre-replace addenda)

- 2026-07-20 audit: single commit `717e5f3` ("Initial commit: Swift SDK for pdftract
  v1.1.0"), `.codegen-version` = `1.1.0`, no tags anywhere, `origin` pointed at GitHub
  directly, and the generated PascalCase API broke every README sample and the test target →
  ADR-1 below. (A local-only `needle-cleanup-backup-20260801` tag from a fleet cleanup also
  existed; not semver, never pushed.)
- 2026-07-22: shim shipped (6e19810), then deleted (d7009cb) after the upstream `lc_first`
  filter fix (`54b432f8`) made the generated API lowerCamelCase natively.
- 2026-09-24: ADR-1 follow-ups resolved — CI template + sensor shipped and verified (bf-3vc,
  bf-25c, bf-57b); `v1.1.0` tagged and mirror-confirmed (bf-4mw) after gate run `manual-tn26m`
  went green on that exact commit `01d83b0`.
- 2026-09-26: regenerated against pdftract 1.2.0 (f72f9a5, pdfswift-3bc489ab; then 84b1482 for
  the `a2ed4c967` lifecycle-test fix) — `.codegen-version` = `1.2.0`; `v1.2.0` tagged and
  mirror-confirmed (pdfswift-55d2f9e8) after gate run `fnrbs` went green; `origin` moved to
  Forgejo with GitHub as mirror.
- 2026-11-24: bare `swift test` passes binary-less — `requireBinary()` XCTSkip guards plus the
  `--help` probe fix (the old `--version` probe exited 2 on every real binary;
  pdfswift-8f868708, 61d59402).
- 2026-11-25: macOS declared-but-untested + believed-broken `;` PATH split documented
  (pdfswift-d971f54f); CI gate expanded to the full suite minus `ProcessLifecycleTests`
  (declarative-config `b947d7a35`); Sendable/concurrency drop regenerated
  (pdfswift-215641c8, a87876f8).

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
- Debt (resolved 2026-07-22): the two-names-per-method shim is gone — upstream codegen emits
  lowerCamelCase directly (d7009cb). Docs still only ever show the lowerCamelCase form.
- `swift build --build-tests` passes on `main` as of 2026-09-24 (it failed before ADR-1's
  fixes); the CI gate keeps it that way on every push.

### Follow-up work (beads filed 2026-07-20, label `artifact-improvement`)

Status update 2026-09-24 (bf-4mw): every item below is resolved — the ADR is fully shipped.

- ~~Add the lowerCamelCase compatibility shim (point 3 above) — P0~~ — SHIPPED (6e19810),
  then deleted per point 4 once the upstream fix landed (d7009cb, 2026-07-22): the generated
  API is lowerCamelCase directly now.
- ~~Add the Argo Workflows CI template (point 1 above) — P0~~ — **SHIPPED + VERIFIED**
  (bf-3vc ready to close). `pdftract-swift-build` lives in declarative-config
  `k8s/iad-ci/argo-workflows/` (ArgoCD-synced) and a sensor auto-triggers it on every push
  to main (bf-57b). Verified 2026-09-24 (bf-25c):
  - Reliability: green on 3 consecutive runs (`4b79w` auto-triggered + `q9q72`/`85c2t`
    manual), pod runtimes ~3–8 min against the 1800 s step deadline even while iad-ci is
    under load — no resource/deadline hardening needed; loosening them would only mask
    infra flakes rather than catch regressions.
  - Correctness (the gate has teeth, not a no-op green): on a throwaway branch, reverting
    the lowerCamelCase API surface — renaming the 9 generated methods back to the PascalCase
    the pre-fix generator emitted, the same defect class the deleted shim used to paper
    over — makes `swift build --build-tests` exit 1 with `value of type 'Pdftract' has no
    member 'extractMarkdown'` (likewise extract, extractText, extractStream, search,
    getMetadata, hash, classify, verifyReceipt): the test target fails to compile, exactly
    the failure class that shipped undetected before CI existed. Branch discarded; main
    untouched.
- ~~Push the `v1.1.0` tag once CI is green (point 2 above) — P1~~ — **SHIPPED + VERIFIED**
  (bf-4mw, 2026-09-24). `v1.1.0` (annotated, → `01d83b0`) pushed to Forgejo `origin` and
  confirmed on the GitHub mirror (the URL in the README's `from: "1.1.0"` requirement).
  Tagged only after the gate was verified green on that exact commit: `pdftract-swift-build`
  `manual-tn26m` Succeeded against main `01d83b0`, and the same gate re-run locally on a clean
  `git archive HEAD` extraction (`swift build`, `swift build --build-tests`, and the filtered
  fake-binary test suites) all exited 0.
- ~~File the upstream codegen-template fix against `jedarden/pdftract` (point 4 above) —
  P2~~ — SHIPPED upstream (pdftract 54b432f8 registers the `lc_first` filter); this repo
  regenerated and dropped the shim in d7009cb.

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
