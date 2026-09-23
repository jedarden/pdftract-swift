# Codegen refresh workflow

How the generated files in this repo are produced, refreshed, validated, and
released. Every generated file carries the `GENERATED` marker ("do not edit
manually — use the code generator to refresh"); this is the "use the code
generator" half of that instruction. This guide is **hand-written** and lives
under `docs/notes/` precisely because it is not generator output and must
survive every refresh.

Last verified against pdftract main (`eeab77e7`) on 2026-09-23.

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

# 4. Build-verify exactly what the CI gate runs.
cd ~/pdftract-swift
swift build && swift build --build-tests
swift test --filter 'StreamingStderrRegressionTests|ExitCodeMappingTests'
# No local Swift toolchain? The swift:5.10-jammy image is what CI uses:
docker run --rm -v "$PWD:/workspace" -w /workspace swift:5.10-jammy \
  bash -c 'swift build && swift build --build-tests && swift test --filter "StreamingStderrRegressionTests|ExitCodeMappingTests"'

# 5. Commit the regenerated drop and the .codegen-version bump together.
```

**Always pass `--version` explicitly.** The flag defaults to pdftract's own
Cargo version (`0.1.0`), which would stamp a wrong `.codegen-version`, a wrong
`Package.swift`-style install snippet in `README.md`
(`from: "0.1.0"`), and a wrong release link.

## `.codegen-version` moves in lockstep with the binary release

`.codegen-version` (plain semver, no `v` prefix — currently `1.1.0`) records
which generator drop produced the checked-in tree. It is **pure provenance**:
no runtime code reads it, and `sdk validate` does not compare it either
(a deliberately mismatched file produces no finding — verified 2026-09-23).
Nothing enforces lockstep mechanically, so it is a discipline:

- `.codegen-version` must always name the pdftract release the generated files
  were actually emitted from, and the git tag this repo carries must be that
  same version.
- The tag is not written by hand: when pdftract releases version `N`, the
  release cascade (`pdftract-release-cascade` → `pdftract-swift-publish`, both
  WorkflowTemplates in `declarative-config/k8s/iad-ci/argo-workflows/`) clones
  this repo, runs the conformance suite against the release-`N` binary, and
  tags this repo `N` (numeric, no `v` prefix — SwiftPM resolves the README's
  `.package(from:)` requirement against git tags).
- Consequence: the refresh that picks up release `N`'s output — with
  `--version N` and `.codegen-version` bumped to `N` — must be committed and
  through the build gate **before** the cascade runs for `N`. Otherwise the
  cascade tags a tree whose generated content does not match the release it
  advertises, which is exactly the ADR-1 failure mode (a "release" that never
  matched its own claims) this workflow exists to prevent.

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
  nobody touched them. As of 2026-09-23, for example, the generator has
  timeout/cancellation support (`exec(_:timeout:)`, `TimeoutError`,
  README "Cancellation and timeouts") that the `1.1.0` drop predates — about
  760 changed lines waiting for the next refresh. Check whether the diff is
  pure template output (expected staleness) or a local edit (contract
  violation) before deciding anything is wrong.

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

## What runs where (CI map)

| When | Workflow (iad-ci) | What it does |
|---|---|---|
| Every push to `main` | `pdftract-swift-build` | `swift build` + `swift build --build-tests` on `swift:5.10-jammy`, then `swift test --filter 'StreamingStderrRegressionTests\|ExitCodeMappingTests'` (the two fake-binary suites). A regenerated drop that breaks either target, or regresses stderr draining or exit-code mapping, fails here. Still deliberately does **not** run unfiltered `swift test` — the conformance suite needs the real binary. |
| pdftract release `N` | `pdftract-swift-publish` (via `pdftract-release-cascade`) | Clones this repo, runs `swift test --filter ConformanceTests` against the release-`N` binary (must pass), tags `N`, warms Swift Package Index. Idempotent — skips an existing tag. |

Both templates live in `jedarden/declarative-config` under
`k8s/iad-ci/argo-workflows/` (`pdftract-swift-build-workflowtemplate.yml`,
`pdftract-swift-publish.yaml`).

One local-testing gotcha the table implies: the generated
`ConformanceTests.swift` asserts a real `pdftract` binary answers
`pdftract --version` on `PATH` (its first test fails with "pdftract binary not
found on PATH" otherwise), so bare `swift test` without the binary installed
cannot pass. Compile-verify locally with the gate's
`swift build --build-tests`; run the full suite only where the binary exists.

## Follow-up (optional, upstream)

If this guide should be discoverable from `README.md`, add the link to
`README.md.tera` in jedarden/pdftract — a link hand-added to this repo's
`README.md` would be classified as `MODIFIED` drift and reverted by the next
refresh.
