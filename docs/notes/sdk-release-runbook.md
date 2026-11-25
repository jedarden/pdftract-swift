# SDK release runbook

How to cut an actual release of this SDK — stamp the version, gate it, tag it,
and prove the tag reached the GitHub mirror SwiftPM resolves against. This is
the repeatable checklist the v1.1.0 (bf-4mw, 2026-09-24) and v1.2.0
(pdfswift-55d2f9e8, 2026-09-26) releases were both cut from, written down
after the fact. Companion to `codegen-refresh.md`, which covers *producing*
the refreshed drop; this document covers *publishing* it. Hand-written, like
every file under `docs/notes/` — it must survive codegen refreshes untouched.

## What a release is here

There is no registry, no release artifact, and no `Package.swift` version
field to bump. **The git tag is the release.** A consumer's

```swift
.package(url: "https://github.com/jedarden/pdftract-swift", from: "1.2.0")
```

resolves `from:` against the semver tags visible at that URL — the GitHub
mirror, not Forgejo. A tag that exists on Forgejo `origin` but not on GitHub
is invisible to every consumer; this failure actually happened (see
"Mirror-sync gotcha" below). That is why half this runbook is mirror
verification.

Tag format is **`v`-prefixed** (`v1.1.0`, `v1.2.0` — both annotated). SwiftPM
strips an optional leading `v` when matching, so `v1.2.0` satisfies
`from: "1.2.0"`. Do not also push an unprefixed twin — one version, one tag.

## The version triple

Three independently-stored artifacts must name the same `X.Y.Z`. Two of them
are generator output and are stamped *together* by one flag; the third is the
tag you cut by hand:

| Artifact | Format | Set by | Read by |
|---|---|---|---|
| `.codegen-version` | plain `X.Y.Z` (no `v`) | `pdftract sdk codegen --version X.Y.Z` | humans; provenance only — nothing mechanical reads it |
| `README.md` | `from: "X.Y.Z"` install snippet, "generated against pdftract X.Y.Z" line, release link | the same `--version` flag | consumers (SwiftPM `from:`), humans |
| git tag `vX.Y.Z` | annotated, `v` prefix | you, at step 5 below | SwiftPM — this **is** the release |

Notes on the triple:

- **`--version` is the only correct way to stamp the first two.** It defaults
  to pdftract's own Cargo version (`0.1.0`), which would stamp a wrong
  `.codegen-version`, a wrong README snippet, and a wrong release link in one
  stroke. Always pass it explicitly (codegen-refresh.md, "Refresh procedure"
  step 2). Never hand-edit `README.md` to fix a version — it is generated
  output and the next refresh reverts the edit; re-run codegen with the right
  `--version` instead.
- **Prefix asymmetry is real and intentional-looking but worth knowing:**
  `.codegen-version` and the README's `from:` carry no `v`; the git tag does.
  The tag is the odd one out because it was cut by hand following ordinary
  release-tag convention.
- **The README also links the pdftract CLI release**
  (`https://github.com/jedarden/pdftract/releases/tag/vX.Y.Z`). That link
  dangles until upstream pdftract cuts its own `vX.Y.Z` release tag — the
  v1.2.0 SDK drop shipped on 2026-09-26 while upstream had only
  `v0.1.0-test`, and the link stayed dead until pdftract's v1.2.0 landed
  (present on both Forgejo and its GitHub mirror as of 2026-11-25). Step 1
  of the checklist therefore includes checking upstream, not just this repo.

## What runs automatically vs. what you do by hand

**Automatic on every push to `main`**: Forgejo → GitHub push mirror
(`sync_on_commit: true`) → GitHub webhook → `pdftract-swift-ci-sensor` (Argo
Events, iad-ci) → `pdftract-swift-build` workflow: `swift build`,
`swift build --build-tests`, then
`swift test --filter 'StreamingStderrRegressionTests|ExitCodeMappingTests'`.
This is the release gate. It fires only for `refs/heads/main`.

**Manual, always, so far**: the release tag. The release cascade
(`pdftract-release-cascade` → `sdk-swift-publish`, WorkflowTemplates in
`declarative-config/k8s/iad-ci/argo-workflows/`) has the Swift slot
**hard-off** — `when: 'false'`, commented "permanently disabled pending their
SDKs' first release" — even though this SDK has shipped two releases. Both
were tagged manually, exactly per this runbook.

If that slot is ever enabled, reconcile the template first — as written on
declarative-config `origin/main` (2026-11-25) it has four defects, three of
which are the same class that made `pdftract-php-publish` "never runnable end
to end":

1. **Template name mismatch.** The cascade invokes
   `pdftract-sdk-swift-publish`; the synced template is named
   `pdftract-swift-publish`. Enabling the slot as-is yields an Error-phase
   workflow (template not found) that no TTL reaps.
2. **GitHub-direct clone and push.** The template clones
   `github.com/jedarden/pdftract-swift` and pushes the tag straight to
   GitHub, bypassing Forgejo-primary/mirror-only (the org convention forbids
   client-side pushes to the mirror).
3. **Numeric tag.** It creates `N` without the `v` and its header claims
   "SPM tags use NUMERIC format only" — the numeric tag *would* resolve
   (SwiftPM does not require the strip), but it diverges from both shipped
   tags and splits the convention.
4. **Vacuous conformance gate.** The header says the conformance suite runs
   "against the bundled binary", but nothing installs a release binary on
   PATH in the pod, and since the pdfswift-8f868708 XCTSkip guards the
   binary-dependent tests *skip* in that environment. The gate would pass
   without ever exercising the release binary it claims to gate on.

Until someone does that reconciliation, the manual checklist below is the
only release path. It has been used successfully twice.

## Checklist

Ordered. Steps 1–4 are the gate; do not tag until all four pass. The
ordering rule underneath everything: **a tag push triggers nothing** (the
sensor filters `refs/heads/main`, and a tag-only push doesn't even trigger
the mirror sync — see gotcha below), so nobody will catch a tag cut on an
ungreen commit except you, before you cut it. Tagging an ungreen or
stale-drop commit is exactly the ADR-1 failure mode: a release that never
matched its own claims.

### 0. Preconditions

- The refreshed drop is committed **and pushed** (codegen-refresh.md step 5):
  `.codegen-version` bumped, README stamped, both in one commit on `main`.
- Working tree clean apart from `.beads/`/`.needle*` fleet state:
  ```bash
  git status --short
  git log --oneline -3
  ```
- The version you are releasing is `X.Y.Z` = `.codegen-version` = the README
  `from:` value = the `--version` the drop was generated with. Check all
  three:
  ```bash
  cat .codegen-version
  grep -n 'from:' README.md
  ```
- Upstream pdftract has its own `vX.Y.Z` release (so the README release link
  resolves the day you announce):
  ```bash
  git ls-remote --tags https://git.ardenone.com/jedarden/pdftract.git | grep "v${VER}"
  ```
  (Replace with the GitHub URL if Forgejo lacks it.) If upstream hasn't cut
  it yet, either wait or release knowing the README link dangles until it
  does — and say so in the announcement.

### 1. Gate: build green on the exact commit

The gate is the CI run for the commit you are about to tag — not "the latest
green run", which may predate your drop. Push first, then check:

```bash
kubectl --server=http://traefik-iad-ci:8001 get workflow -n argo-workflows \
  --sort-by=.metadata.creationTimestamp | grep pdftract-swift-build | tail -5
kubectl --server=http://traefik-iad-ci:8001 get workflow <name> -n argo-workflows \
  -o jsonpath='{.status.phase}{"\n"}'
```

Require `Succeeded` on a workflow **created after your push**. Two gotchas:

- **The workflow object is reaped 30 minutes after success** (`ttlStrategy:
  secondsAfterSuccess: 1800`), so check promptly after pushing. After that,
  only the Argo UI (within its own TTL) remembers.
- The workflow spec records no commit SHA (the sensor submits a bare
  template ref). Matching a run to your push is by creation timestamp. When
  that's ambiguous — rebases, bursts of pushes, TTL already elapsed — don't
  guess; run the identical gate yourself against the exact SHA:

  ```bash
  D=$(mktemp -d) && git archive HEAD | tar -x -C "$D" && docker run --rm \
    -v "$D":/workspace -w /workspace swift:5.10-jammy bash -c \
    'swift build && swift build --build-tests && swift test --filter "StreamingStderrRegressionTests|ExitCodeMappingTests"'
  ```

  Same command CI runs, no local Swift toolchain needed (this box has
  none). Docker writes `$D/.build` as root — clean up with `sudo rm -rf`.
  Expect `ExtractStreamConformanceTests`/`ConformanceTests` noise to be
  skips, and never add `ProcessLifecycleTests` to the filter: it fails 3/6
  in docker-class containers for environment reasons unrelated to any drop
  (see the CI map in codegen-refresh.md).

### 2. Cut the tag

On Forgejo — never push tags (or anything) to GitHub directly; the mirror is
one-way, server-side:

```bash
VER=1.3.0   # X.Y.Z, no 'v'; the tag gets the 'v'
git tag -a "v${VER}" -m "Release v${VER} (generated against pdftract ${VER})" main
git push origin "v${VER}"
```

- **Annotated** (`-a`), matching both shipped releases. A lightweight tag
  works for SwiftPM but breaks the convention and the `^{}`-peeled line you
  verify in step 4.
- Tag `main` at the gated commit. If `main` moved since the green run,
  re-run step 1 on the new HEAD before tagging it.

### 3. Force the mirror sync

```bash
FORGEJO_TOKEN="$(git credential fill <<< 'protocol=https
host=git.ardenone.com
' | grep password | cut -d= -f2)"
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "https://git.ardenone.com/api/v1/repos/jedarden/pdftract-swift/push_mirrors-sync" \
  -H "Authorization: token $FORGEJO_TOKEN"
```

HTTP `200` = accepted.

**Why this step exists — the mirror-sync gotcha:** the push mirror has
`sync_on_commit: true`, but *commit* is the operative word. A tag-only push
does not trigger a sync: on 2026-09-24, `v1.1.0` was on Forgejo `origin`
immediately after `git push` and absent from GitHub until forced. If you skip
this step, the tag appears on the mirror within the 8h interval at best —
during which every `from: "X.Y.Z"` resolution fails. (The sync endpoint is
also harmless when nothing is pending, so run it unconditionally rather than
reasoning about whether it's needed.)

### 4. Verify the tag on the mirror

```bash
git ls-remote --tags https://github.com/jedarden/pdftract-swift.git | grep "v${VER}"
```

Expect **two lines** (annotated tag):

```
<tag-object-sha>	refs/tags/v1.3.0
<commit-sha>	refs/tags/v1.3.0^{}
```

- The `^{}` line is the peeled commit; confirm it equals the `git rev-parse
  v${VER}^{commit}` you gated — that proves the mirror has the tag *on your
  commit*, not on a stale `main`.
- `git ls-remote` talks to GitHub anonymously over HTTPS — no token needed,
  so this check works even when the local GitHub credential is broken.
- Appeared within ~15 s of the forced sync last time. If it's missing, wait
  30 s and re-run before debugging; if still missing, re-run step 3 and
  check the sync response body.

### 5. Record and announce

Only after step 4 shows both lines. Record on the release bead: version,
tagged commit SHA, the gating build (workflow name + phase, or the local
docker exit), the mirror-sync HTTP code, and the `ls-remote` output. The
announcement can then cite `from: "X.Y.Z"` knowing it resolves.

## If the tag is wrong

**Never move or delete a published tag.** No re-tagging, no `git push
--force`, no delete-and-recreate — consumers may already have resolved it,
and SwiftPM caches resolved versions. Ship a fix as a new version: correct
the tree, gate it, cut `v(X.Y.Z+1)` (patch bump for release-metadata fixes;
semver discipline for anything behavioral). This matches the org-wide
never-force-push rule.

## History

- **v1.1.0** — 2026-09-24, bf-4mw. First tag; cut ad hoc, which is why this
  runbook exists. Discovered the mirror-sync gotcha above: `v1.1.0` was on
  `origin` immediately, absent from GitHub until `push_mirrors-sync` was
  forced.
- **v1.2.0** — 2026-09-26, pdfswift-55d2f9e8. Tagged only after
  `pdftract-swift-build` went green on the exact tagged commit. Mirror
  confirmed via `ls-remote`. At release time upstream pdftract had no
  v1.2.0 tag, so the README's release link dangled until pdftract cut
  v1.2.0 (now present on Forgejo and the GitHub mirror).
- **2026-11-25** — this runbook written from the two precedents; cascade
  Swift slot re-verified hard-off on declarative-config `origin/main`, with
  the four template defects listed above.
