# Codegen refresh workflow

How the generated files in this repo are produced, refreshed, validated, and
released. Every generated file carries the `GENERATED` marker ("do not edit
manually — use the code generator to refresh"); this is the "use the code
generator" half of that instruction. This guide is **hand-written** and lives
under `docs/notes/` precisely because it is not generator output and must
survive every refresh.

Last verified against pdftract main (`ab720d47`, pdfswift-1959bda3's
`Source.bytes` README-template fix, which sits on the still-unlanded local
main above `a2ed4c967` + `12c63b65`) on 2026-11-24: a fresh
`pdftract sdk codegen --lang swift --version 1.2.0` reproduces all nine
generated paths in this repo byte-for-byte, and `sdk validate` reports no
`MODIFIED`/`MISSING` under any generated path (only the usual README
0.1.0-comparison artifact).

## Where the generated output comes from

This repo is 100% emitted by the codegen pipeline in
[jedarden/pdftract](https://git.ardenone.com/jedarden/pdftract):

- **Templates:** `templates/sdk-skeleton/swift/*.tera` (Tera), plus the
  per-language contract in `docs/notes/sdk-contract.md` that drives them.
- **Binary:** `pdftract sdk codegen` / `pdftract sdk validate`, built from that
  repo. The binary bakes in the templates current at the commit it was built
  from — the binary's version **is** the generator version you record.

The generator emits exactly nine paths — nothing else is touched:

| Path | Target |
|---|---|
| `Sources/PdftractCodegen/Types.swift` | `PdftractCodegen` |
| `Sources/PdftractCodegen/Methods.swift` | `PdftractCodegen` |
| `Sources/PdftractCodegen/Errors.swift` | `PdftractCodegen` |
| `Sources/Pdftract/Pdftract.swift` | `Pdftract` (re-exports `PdftractCodegen`) |
| `Tests/PdftractTests/ConformanceTests.swift` | `PdftractTests` |
| `README.md` | API reference |
| `Package.swift` | manifest |
| `GENERATED` | marker |
| `.codegen-version` | provenance stamp |

Everything else in the repo (`docs/`, `notes/`, `LICENSE`, `.gitignore`,
this file) is hand-written and survives regeneration untouched — verified:
codegen pointed at a populated repo root only rewrites the nine paths above.
Note that `README.md` and `Package.swift` are generated too, even though they
read like prose/config: **hand-edits to them are drift and get reverted by the
next refresh.**

## Refresh procedure

Run the codegen commands **from the root of a pdftract checkout** — both the
SDK contract and the template directory resolve relative to the process CWD;
from anywhere else codegen fails with
`Template directory for Swift does not exist`.

```bash
# 1. Pick the generator: check out jedarden/pdftract at the release tag (or
#    main, once a template fix has landed there) and build/install its binary.
cd ~/pdftract && git checkout <ref> && cargo build --release
export PATH="$HOME/pdftract/target/release:$PATH"

# 2. Regenerate straight into this repo. --version is the pdftract release
#    the drop comes from (see ".codegen-version" below).
cd ~/pdftract
pdftract sdk codegen --lang swift --version <X.Y.Z> --out ~/pdftract-swift

# 3. Review the diff, then validate (see "Validating a drop" below).
cd ~/pdftract
pdftract sdk validate --lang swift --sdk-dir ~/pdftract-swift

# 4. Build-verify, then run the conformance suites unfiltered. Since the
#    pdfswift-8f868708 XCTSkip guards, every binary-dependent test skips
#    cleanly when no pdftract binary is on PATH, so a binary-less
#    environment exercises the conformance and stream suites without a
#    --filter. One caveat: in docker-class containers ProcessLifecycleTests
#    fails 3/6 for environment reasons unrelated to any drop (pre-existing;
#    cancellation and timeouts never reach the spawned child there) — see
#    the CI map below before reading an unfiltered container run:
cd ~/pdftract-swift
swift build && swift build --build-tests
swift test
# No local Swift toolchain? The swift:5.10-jammy image is what CI uses:
docker run --rm -v "$PWD:/workspace" -w /workspace swift:5.10-jammy \
  bash -c 'swift build && swift build --build-tests && swift test'

# 5. Commit the regenerated drop and the .codegen-version bump together.
```

**Always pass `--version` explicitly.** The flag defaults to pdftract's own
Cargo version (`0.1.0`), which would stamp a wrong `.codegen-version`, a wrong
`Package.swift`-style install snippet in `README.md`
(`from: "0.1.0"`), and a wrong release link.

## `.codegen-version` moves in lockstep with the binary release

`.codegen-version` (plain semver, no `v` prefix — currently `1.2.0`) records
which generator drop produced the checked-in tree. It is **pure provenance**:
no runtime code reads it, and `sdk validate` does not compare it either
(a deliberately mismatched file produces no finding — verified 2026-09-23).
Nothing enforces lockstep mechanically, so it is a discipline:

- `.codegen-version` must always name the pdftract release the generated files
  were actually emitted from, and the git tag this repo carries must be that
  same version.
- The tag **is** written by hand today. The release cascade's Swift slot
  (`pdftract-release-cascade` → `sdk-swift-publish`, WorkflowTemplates in
  `declarative-config/k8s/iad-ci/argo-workflows/`) is **hard-off**
  (`when: 'false'`) pending a template reconciliation, so both shipped tags
  (`v1.1.0`, `v1.2.0` — annotated, `v`-prefixed; SwiftPM strips the `v` when
  matching the README's `.package(from:)` requirement) were cut manually and
  mirror-verified. The repeatable procedure is
  `docs/notes/sdk-release-runbook.md`, which also lists the four defects a
  re-enable must fix first (template-name mismatch, GitHub-direct push,
  numeric-tag divergence, vacuous conformance gate).
- Consequence of that manual path: the refresh that picks up release `N`'s
  output — with `--version N` and `.codegen-version` bumped to `N` — must be
  committed and through the build gate **before** `vN` is tagged. Otherwise
  the release tags a tree whose generated content does not match the release
  it advertises, which is exactly the ADR-1 failure mode (a "release" that
  never matched its own claims) this discipline exists to prevent.

## Validating a drop

```bash
cd ~/pdftract
pdftract sdk validate --lang swift --sdk-dir ~/pdftract-swift
```

Validate regenerates the skeleton into a temp dir and diffs it against
`--sdk-dir`, reporting three finding kinds:

- **`MODIFIED: <path>`** — the file exists but differs from current generator
  output. Under `Sources/`, `Tests/`, `Package.swift`, or `GENERATED` this is
  real drift: either a hand-edit (forbidden by the `GENERATED` contract) or a
  drop that is stale relative to the installed binary's templates.
- **`MISSING: <path>`** — a generated path is absent (deleted, or `--sdk-dir`
  points at the wrong tree).
- **`EXTRA: <path>`** — present in the SDK dir but not emitted by the
  generator. Every hand-written file lands here (`docs/`, `notes/`,
  `LICENSE`, …), as does build/VCS noise (`.git/`, `.build/`, `.beads/`).
  Expected on any working repo; not a problem.

### Interpreting results on this repo

- **The exit code is not the signal.** Validate exits 1 whenever *any* finding
  exists, including pure `EXTRA` noise — on this repo it therefore always
  exits 1. Gate on the absence of `MODIFIED`/`MISSING` lines under generated
  paths instead:
  ```bash
  pdftract sdk validate --lang swift --sdk-dir ~/pdftract-swift 2>&1 \
    | grep -E '^\s+(MODIFIED|MISSING)'
  ```
- **`MODIFIED: README.md` is (mostly) benign.** Validate has no `--version`
  flag and always compares against a skeleton generated at the default
  `0.1.0`, so the install snippet and the "generated against pdftract"
  lines in `README.md` always differ for any real release. Diff `README.md`
  by hand to separate that two-line artifact from real content drift.
- **Staleness looks like tampering.** When pdftract main's templates are ahead
  of the last drop, validate reports `MODIFIED` on generated paths even though
  nobody touched them. (Worked example, now resolved: on 2026-09-23 the
  generator's timeout/cancellation support — `exec(_:timeout:)`,
  `TimeoutError`, README "Cancellation and timeouts" — was about 760 changed
  lines ahead of the `1.1.0` drop. The 1.2.0 refresh landed all of it:
  f72f9a5, then 84b1482 for the drop-before-iteration lifecycle-test fix from
  pdftract a2ed4c967.) Check whether the diff is pure template output
  (expected staleness) or a local edit (contract violation) before deciding
  anything is wrong.

## Fixing a bug in generated code

Fix the **template upstream first**, land it in jedarden/pdftract, then
regenerate here. Never hand-patch a generated file: the next refresh silently
reverts the patch with no detection — the exact mechanism by which ADR-1's
PascalCase method-name defect shipped. Worked examples from this repo's
history:

- `bf-1b5` (d7009cb): the generator emitted PascalCase methods because
  `Methods.swift.tera` referenced an unregistered `lc_first` Tera filter.
  Fixed in pdftract `54b432f8`, then regenerated here — byte-identical to the
  earlier manual edit, turning it into true provenance.
- `pdfswift-d9676b80` (418d46f): Swift 5.10 compilation breakage
  (`Package.swift` `.linux(.v4)`, struct-based error types). Templates fixed
  in pdftract `d4c52028`, regenerated with `--version 1.1.0`; validate then
  reported every `.swift` file in sync.
- `pdfswift-6bc41168` (fef69c4): concurrent stderr drain in the streaming
  APIs, mirrored upstream in pdftract `eeab77e7` so future refreshes keep it.
- `pdfswift-8f868708` (2026-11-24): XCTSkip guards for the binary-dependent
  conformance tests (`requireBinary()` mirroring the client's PATH scan) and
  a probe fix — `testBinaryAvailable` asserted `pdftract --version`, which no
  pdftract build accepts (the CLI registers no version flag, so clap exits
  2); the probe is now `--help`. Fixed in the Swift test template on pdftract
  local main — the unlanded lineage this repo's drops come from, same
  standing as the `a2ed4c967` lifecycle-test fix — and regenerated here as a
  delta confined to `Tests/PdftractTests/ConformanceTests.swift`.

## What runs where (CI map)

| When | Workflow (iad-ci) | What it does |
|---|---|---|
| Every push to `main` | `pdftract-swift-build` | `swift build` + `swift build --build-tests` on `swift:5.10-jammy`, then `swift test --filter 'StreamingStderrRegressionTests\|ExitCodeMappingTests'` (the two fake-binary suites). A regenerated drop that breaks either target, or regresses stderr draining or exit-code mapping, fails here. The filter predates the pdfswift-8f868708 XCTSkip guards, which removed the conformance-suite reason for it: binary-less, `ExtractStreamConformanceTests` now skips cleanly and could be safely added to the gate. A wholesale drop is still blocked, but for a different pre-existing reason: `ProcessLifecycleTests` fails 3/6 in docker-class containers (observed identically on the pre-guard tree, 2026-11-25 — cancel/timeout/drop-before-iteration; cancellation and timeouts don't reach the spawned child in that environment), and adding it would turn this gate red. Investigating that is its own piece of work; loosening the filter is a declarative-config change to `pdftract-swift-build-workflowtemplate.yml`. |
| pdftract release `N` | `pdftract-swift-publish` (via `pdftract-release-cascade`) | **Not firing** — the cascade's `sdk-swift-publish` slot is hard-off (`when: 'false'`), so pdftract releases do **not** auto-tag this SDK; releases are cut manually per `docs/notes/sdk-release-runbook.md`. The template, if ever enabled as written, clones GitHub directly and tags `N` numerically — four defects to reconcile first, listed in the runbook. |

Both templates live in `jedarden/declarative-config` under
`k8s/iad-ci/argo-workflows/` (`pdftract-swift-build-workflowtemplate.yml`,
`pdftract-swift-publish.yaml`).

One local-testing gotcha the table used to imply, resolved 2026-11-24
(pdfswift-8f868708): the generated `ConformanceTests.swift` used to assert a
real `pdftract` binary answers `pdftract --version` on `PATH`, so bare
`swift test` without the binary failed — and, less visibly, with the binary
failed too, because the CLI registers no `--version` flag (clap exits 2 on
it). Both are fixed in the template: a `requireBinary()` helper throws
XCTSkip when the client's PATH scan would find nothing (the same guard
`ExtractStreamConformanceTests` carries), and the probe is `--help`, which
every pdftract build answers with exit 0. Bare `swift test` in a binary-less
environment now exercises every suite — the real-binary ones skip cleanly,
the fake/stub ones run — so compile-verification is no longer the only thing
such a run can tell you. The one remaining binary-less failure set is
pre-existing and unrelated to any drop: `ProcessLifecycleTests` fails 3/6 in
docker-class containers (see the CI map above).

## Platform coverage: macOS 13+ is declared-but-untested

The README ("**Supported**: macOS 13+, Linux") and `Package.swift`
(`platforms: [.macOS(.v13)]`) both declare macOS 13+, but **nothing in this
repo's verification chain has ever compiled or run the package on macOS**.
Every gate in the CI map above runs on `swift:5.10-jammy` — Linux — and the
docker recipe under "Refresh procedure" is the same image. There is no macOS
host in the fleet (iad-ci is a Linux cluster; Linux docker cannot run macOS
images), so macOS coverage cannot be added to any existing gate. Read the
README claim as a *declaration*, not a verified fact (pdfswift-d971f54f,
2026-11-25).

Inspection of the macOS branches the Linux gates never compile says the
declaration is not merely unverified — the macOS path is believed broken for
its primary use:

- Four of the six `#if os(Linux)` sites are inert: both branches are the same
  `import Foundation` (`Errors.swift:5`, `Types.swift:5`,
  `Sources/Pdftract/Pdftract.swift:6`, `Methods.swift:5`).
- The other two split the binary-discovery PATH scan on `;` for every
  non-Linux platform (`Methods.swift:34`, mirrored by the `requireBinary()`
  helper in `ConformanceTests.swift:29`). macOS, like Linux, separates PATH
  entries with `:` — so on a stock macOS PATH (`/usr/local/bin:/usr/bin:/bin`)
  the whole PATH is one split result and the scan probes
  `/usr/local/bin:/usr/bin:/bin/pdftract`, a path that never exists. The scan
  result is discarded (`resolvedBinaryPath ?? "pdftract"`), the client falls
  back to the bare string `pdftract`, and every default-init call then fails
  at spawn — binary-not-found. The fake/stub suites are unaffected (they pass
  `binaryPath:` explicitly, bypassing discovery), which is exactly why the
  Linux gates cannot catch this: they never exercise macOS discovery.

All six sites, plus the README/platform wording, are generated output — the
conditionals come from the upstream pdftract templates. Fixing the `;` split,
or rewording the README claim, is a **template change upstream** (see "Fixing
a bug in generated code" above), then a regeneration here; a hand-edit to
`Methods.swift`, `ConformanceTests.swift`, or `README.md` is drift and gets
reverted by the next refresh.

### Manual macOS verification (when a macOS host is available)

Until such a host exists, the claim stays declared-but-untested. When one is
available, run on macOS 13+ with the Swift 5.10 toolchain and record the
result like the CI proof beads do (commit SHA, exact commands, exit codes):

```bash
# fresh checkout or `git archive HEAD` extraction of the tagged release
swift build && swift build --build-tests   # compile both targets
swift test --filter 'StreamingStderrRegressionTests|ExitCodeMappingTests'
# with a real pdftract release binary on PATH (expect this to be red until
# the upstream `;`-split fix lands and a drop picks it up — discovery is the
# known-broken path):
swift test --filter ConformanceTests
```

The compile-level steps are expected to pass on macOS (nothing in them
resolves PATH at compile time); the real-binary step is where the `;` split
bites. A green macOS conformance run would falsify the analysis above and
justify upgrading the README claim from declaration to verified support.

## Follow-up (optional, upstream)

If this guide should be discoverable from `README.md`, add the link to
`README.md.tera` in jedarden/pdftract — a link hand-added to this repo's
`README.md` would be classified as `MODIFIED` drift and reverted by the next
refresh.
