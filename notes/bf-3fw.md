# bf-3fw — Verify pdftract-swift-build runs green once (manual submit)

**Status: RED — not closing (gate failed; fix tracked under child #3).**
**Parent: bf-3vc (split-child #1 of 3).**

## What was done (2026-07-22)

Manually submitted the `pdftract-swift-build` WorkflowTemplate against main HEAD
and observed the run to completion. This was the **first-ever** run of the gate
on iad-ci.

- **Workflow name:** `pdftract-swift-build-manual-g2kxf`
- **Commit built:** `7e5e5fde21344fc80c385eea9d9f20d62bdc6d3b` (current main HEAD;
  the template clones `--branch main`, so it does NOT pin the `6e19810` named in
  the task — main had advanced. This is expected/correct.)
- **Image:** `swift:5.10-jammy` → Swift 5.10.1
- **Outcome:** **Failed** — `main: Error (exit code 1)`, Pod phase Failed
  (started 14:40:03Z, finished 14:40:51Z — ~48s; dies fast, in the manifest
  compile, well under the 30m deadline)

## Per-node failure (acceptance criterion)

```
node:   pdftract-swift-build-manual-g2kxf  (type Pod)
phase:  Failed
message: main: Error (exit code 1)
workflow message: "main: Error (exit code 1)"
```

## Step coverage

- ❌ `swift build` (step 1) — **FAILED** (manifest does not compile)
- ⬜ `swift build --build-tests` (step 2) — never reached

## Root cause (authoritative — from the Swift 5.10.1 compiler)

`Package.swift:7` declares a platform Swift 5.10's PackageDescription does not
support:

```swift
platforms: [.macOS(.v13), .linux(.v4)],
```

```
/workspace/Package.swift:7:32: error: type 'SupportedPlatform' has no member 'linux'
/workspace/Package.swift:7:39: error: cannot infer contextual base in reference to member 'v4'
```

`SupportedPlatform.linux` does not exist until a later SwiftPM (6.0+). The
manifest therefore fails to compile under `swift-tools-version: 5.10`, so the
gate dies before building any target.

**Not a regression:** `git log -L 7,7:Package.swift` shows `.linux(.v4)` was
introduced in the initial commit (`717e5f3` — "Initial commit: Swift SDK for
pdftract v1.1.0"). The package has never been buildable under Swift 5.10; the
gate simply had never been run until now. **The gate is working correctly** —
it is the package (not the template) that is incompatible with the CI image.

## Fix (out of scope here — child #3)

Options for child #3, in order of preference:

1. **Drop `.linux(.v4)` from `platforms`.** Linux has no enforced deployment
   target in SwiftPM (unlike macOS/iOS), so this member is a no-op anyway and
   is what's tripping 5.10. `platforms: [.macOS(.v13)]` alone builds clean.
2. **Bump the CI image** to a Swift ≥ 6.0 that supports `.linux` in manifests,
   and bump `swift-tools-version` to match. Heavier change; also means the
   SDK's minimum toolchain rises.
3. Combine as needed — but the gate will stay red until at least (1) or (2)
   lands.

Captured full stdout/stderr in `/tmp/pdftract-swift-build-g2kxf.log` (ephemeral;
pod already GC'd per `podGC: OnPodCompletion`, so re-running is the only way to
regenerate logs).
