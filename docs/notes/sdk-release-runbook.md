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

## Canonical consumer URL (decision)

**Decision (pdfswift-63bde4de, 2026-11-25): consumers install from the GitHub
mirror URL — `https://github.com/jedarden/pdftract-swift`. Forgejo is never
cited to consumers.** Every snippet, announcement, and generated README points
at the GitHub URL; this section records why, what that obligates, and what
would flip it.

Why GitHub stays canonical:

- **SwiftPM resolves anonymously, and Forgejo is not anonymously readable.**
  `swift package resolve` speaks anonymous HTTPS to the package URL; it cannot
  authenticate. As of 2026-11-25 the Forgejo repo answers **401** to an
  anonymous `/info/refs?service=git-upload-pack` (push-created repos start
  private, and the instance is not a consumer-facing host), while the GitHub
  mirror answers **200**. A Forgejo `from:` requirement would fail for every
  consumer on day one — not a mirror risk, a certainty.
- **The mirror is the only place both tags are publicly visible.** Checked
  2026-11-25: `v1.1.0` and `v1.2.0` present on GitHub with `^{}`-peeled SHAs
  matching Forgejo `origin` and local.
- The org hosting convention (Forgejo primary, GitHub read-only mirror)
  governs *development pushes*, not consumer resolution. Consumers were never
  the mirror's purpose — the public portfolio is — but for this repo the
  mirror is also the only anonymous read path, so it is the consumer URL of
  record.

What this decision obligates:

- **Mirror health is release-critical, not hygiene.** Steps 3–4 of the
  checklist (force the sync, verify the tag on the mirror) are mandatory for
  every release *and* any tag-only push, because a tag that lives only on
  Forgejo is invisible to every `from:` requirement (the 2026-09-24 gotcha).
- The mirror is one-way, server-side. Never push to GitHub client-side — that
  diverges the mirror from its source of truth.
- **If the README URL ever changes**, the change routes through the pdftract
  template (`templates/sdk-skeleton/swift/README.md.tera`, the
  `.package(url: ...)` line) and a `--version`-stamped codegen refresh — never
  a hand edit of the generated `README.md`. The decision above keeps the
  GitHub URL, so no template change ships with it.

Flip conditions — re-decide only if **all** of these hold:

1. The Forgejo repo is flipped anonymously readable (curl its `info/refs`
   endpoint: 200, not 401).
2. `git.ardenone.com` is proven reachable for anonymous consumer traffic from
   outside the tailnet.
3. There is a concrete reason to stop depending on the GitHub mirror (not
   just symmetry with the org convention).

Then migrate consumers: change the template URL, regenerate, release per the
checklist, and announce the new `from:` URL. Until then, the GitHub URL is
the install URL of record.

### Post-migration / pre-announcement check

After any hosting or mirror change — and before any release announcement —
prove the **documented** URL anonymously resolves the **latest** tag:

```bash
# 1. Anonymous readability of the canonical URL (expect 200; 401 = consumers broken now)
curl -s -o /dev/null -w '%{http_code}\n' \
  'https://github.com/jedarden/pdftract-swift/info/refs?service=git-upload-pack'

# 2. Latest tag visible there, with the peeled commit matching local
#    VER is the release version from checklist step 0 — equal to
#    .codegen-version only on a drop-cut release, patch-ahead on an
#    SDK-only one (versioning policy in codegen-refresh.md).
VER="<X.Y.Z from checklist step 0>"
git ls-remote --tags https://github.com/jedarden/pdftract-swift.git | grep "refs/tags/v${VER}"
git rev-parse "v${VER}^{commit}"   # must equal the ^{} peeled SHA from the line above

# 3. The documented requirement resolves against a visible tag
grep -n 'from:' README.md          # README's from: (the drop floor) must be <= the latest tag visible in step 2

# 4. The full consumer path: resolve + build + import from the published tag
scripts/spm-install-smoke.sh
```

Failures and what they mean: step 1 ≠ 200 → mirror visibility changed,
consumers are broken now. Step 2 has no lines → the tag didn't reach the
mirror; re-run step 3 of the checklist. Step 2 peeled SHA ≠ local → the
mirror holds the tag on a stale commit; investigate before announcing.
Step 3 `from:` greater than the latest visible tag → the README advertises a
version no consumer can resolve; the drop or the tag didn't publish — do not
announce. Step 4 fails → the tag resolves but does not build or import as a
dependency (broken manifest-as-dependency, Linux platform break, or a
README snippet whose API the tag doesn't ship); do not announce.

## The version triple

Three independently-stored artifacts carry version literals. On a
**drop-cut release** — the normal case, and every release so far — they
name the same `X.Y.Z`. On an **SDK-only release** (no new pdftract drop) the
tag moves ahead by a patch and the generator-stamped two stay at the drop;
the full rule is the versioning policy in `codegen-refresh.md`
("Package-versioning policy"). Two of the artifacts are generator output
and are stamped *together* by one flag; the tag is the one you cut by hand:

| Artifact | Format | Set by | Read by |
|---|---|---|---|
| `.codegen-version` | plain `X.Y.Z` (no `v`) | `pdftract sdk codegen --version X.Y.Z` | humans; provenance only — nothing mechanical reads it |
| `README.md` | `from: "X.Y.Z"` install snippet, "generated against pdftract X.Y.Z" line, release link | the same `--version` flag | consumers (SwiftPM `from:`), humans |
| git tag `vX.Y.Z` | annotated, `v` prefix | you, at step 2 below | SwiftPM — this **is** the release |

The relation between them is the policy: **tag ≥ `.codegen-version`, same
major.minor** — equality means a drop-cut release; a patch-only lead means
SDK-only releases shipped ahead of the drop. Only the tag moves on an
SDK-only release, never the stamps (README is generated output; a
hand-bumped `from:` is drift, and regenerating at a fake version would
falsify the drop provenance). `from:` is a floor: consumers resolve upward,
so an SDK-only tag publishes fine with README still advertising the drop.

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
  The link is drop-stamped, so on an SDK-only release it is exactly where
  the last drop-cut left it — its upstream situation carries over, and
  only a new drop can move it.

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

Ordered. Steps 0–1 are the gate — do not tag until both pass. Steps 3–5
can only run once the tag is published (they prove the published thing,
not the local tree); step 6 records and announces. The ordering rule
underneath everything: **a tag push triggers nothing** (the
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
- Choose the version you are releasing, `X.Y.Z`, per the versioning policy
  (codegen-refresh.md): the smallest unused semver that is ≥ the current
  drop stamp and shares its major.minor. On a **drop-cut release** that is
  `.codegen-version` itself — equal to the README `from:` value and the
  `--version` the drop was generated with. On an **SDK-only release** it is
  the newest existing tag's patch + 1, while the stamps stay at the drop.
  Check all of it:
  ```bash
  cat .codegen-version          # the drop stamp (stays put on an SDK-only release)
  grep -n 'from:' README.md     # == .codegen-version — gate-enforced, always the drop
  git ls-remote --tags origin | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -3
  ```
  `X.Y.Z` must not collide with any of those tags; a major/minor divergence
  from the stamp means this release may not happen without a drop (the
  policy above).
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

Require `Succeeded` on a workflow **created after your push**. Three gotchas:

- **The workflow object is reaped ~5 minutes after success** — this template
  sets `secondsAfterSuccess: 300`, overriding the fleet-wide 30-minute
  default (failures keep 30 min; completion 30 min). Observed 2026-11-25: a
  succeeded run vanished within ~10 min of creation. Check within minutes of
  pushing; afterwards, the archived workflow (Argo labels it
  `workflow-archiving-status: Archived`) and the Argo UI are the only record.
- **The run builds main HEAD at clone time, not "your" commit.** The
  template does `git clone --depth 1 --branch main` and prints the resolved
  SHA; the sensor submits a bare template ref carrying no SHA. If other
  commits (e.g. fleet `chore(beads)` checkpoint pushes) landed between your
  push and the run, it gated those too — fine as long as nothing
  source-affecting intervened and your commit is an ancestor of what it
  built. When that's ambiguous, don't guess; run the identical gate
  yourself against the exact SHA:

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
VER=1.2.1                       # the release version chosen at step 0; no 'v'
DROP="$(cat .codegen-version)"  # the drop stamp; == VER only on a drop-cut release
git tag -a "v${VER}" -m "Release v${VER} (generated against pdftract ${DROP})" main
git push origin "v${VER}"
```

- **Annotated** (`-a`), matching both shipped releases. A lightweight tag
  works for SwiftPM but breaks the convention and the `^{}`-peeled line you
  verify in step 4.
- The message names the **drop** the tree was generated from, not
  necessarily `${VER}` — on an SDK-only release the tag's tree was not
  generated against itself.
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

### 5. Consumer smoke check: install the published tag as a consumer would

Steps 1–4 prove this repo's *view* of the release; nothing yet has built
the tag *as a dependency*. That gap is what this step closes
(pdfswift-41fd9985, added 2026-11-25): a fresh scratch package — outside
this checkout, in a container, with no git credentials — resolves the
README's exact `from:` requirement anonymously, builds the `Pdftract`
product, and imports it from an executable mirroring the README's
"Basic extract" snippet:

```bash
scripts/spm-install-smoke.sh            # pins whatever README.md currently publishes
scripts/spm-install-smoke.sh 1.2.0      # or pin an explicit version/floor
```

Needs docker + the `swift:5.10-jammy` image and network access to
github.com. It is the consumer-side complement to the `pdftract-swift-build`
gate, which clones main HEAD and never builds a tag. It catches releases
whose tag does not build as a dependency, a README `from:` above the newest
published tag (every consumer broken on day one), and platform declarations
that break Linux consumers — the `.linux(.v4)` class of failure
(pdfswift-d9676b80). Note the summary line reports the version
*resolved*, not the one requested: `from:` floats up to the newest tag, so
`from: "1.1.0"` still pins 1.2.0 — the printed `Package.resolved` is the
evidence that matters. Run it after step 4, before announcing; record its
exit and resolved version with the release evidence in step 6. On an
SDK-only release, pass the release version explicitly
(`spm-install-smoke.sh "${VER}"`) so the check exercises the new tag
directly instead of reaching it only via float-up from the drop floor.

### 6. Record and announce

Only after step 5 passes. Record on the release bead: version,
tagged commit SHA, the gating build (workflow name + phase, or the local
docker exit), the mirror-sync HTTP code, the `ls-remote` output, and the
smoke check's exit and resolved version. The announcement can then cite
`from: "X.Y.Z"` knowing it resolves.

## If the tag is wrong

**Never move or delete a published tag.** No re-tagging, no `git push
--force`, no delete-and-recreate — consumers may already have resolved it,
and SwiftPM caches resolved versions. Ship a fix as a new version: correct
the tree, gate it, cut `v(X.Y.Z+1)` (patch bump for release-metadata fixes;
semver discipline for anything behavioral). This matches the org-wide
never-force-push rule — and a release-metadata fix is precisely an
SDK-only release under the versioning policy (codegen-refresh.md): the
stamps stay at the drop, only the tag moves.

## Retiring a compatibility shim

A naming/API compatibility shim that ships in a tag is public API from that
moment. Retiring it after the codegen (or upstream) fix that obsoletes it is a
**breaking change and must be a semver-major release** (`vX+1.0.0`), whose
release notes tell consumers to move straight to the regenerated version — not
a patch that silently drops symbols. Treat the retirement as a release event
per the checklist above, not an ad-hoc commit, and don't let a shim rot past
the fix: the moment a regenerated drop carries the real names natively, the
shim is dead weight and the next release should retire it.

Precedent — the ADR-1 lowerCamelCase shim (bf-b6j, `6e19810d`) never had to
meet this bar: it lived only 2026-07-22 09:41→11:03, from add to bf-1b5's drop
(`d7009cba`) once upstream pdftract registered the `lc_first` Tera filter
(`54b432f8`) and `Methods.swift.tera` was regenerated with all nine methods
lowerCamelCase natively. Both shipped releases postdate the drop, so no
shim-era symbol ever reached a tag and **no semver-major was owed** — cutting
one anyway would have shipped a major with no breaking change in it. Prove
what a tag actually shipped before classifying a shim-drop as breaking:

```bash
git grep -E "public func [A-Z]" v1.1.0 -- "Sources/"   # empty here: nothing shipped
```

Breaking is a property of what shipped, not of what the diff removes.

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
- **2026-11-25** — canonical consumer URL decided (pdfswift-63bde4de): the
  GitHub mirror URL is the install URL of record; Forgejo answers 401 to
  anonymous reads and so cannot serve SwiftPM consumers. See "Canonical
  consumer URL (decision)" — flip conditions and the post-migration check
  live there.
- **2026-11-25** — consumer smoke check added as checklist step 5
  (pdfswift-41fd9985): `scripts/spm-install-smoke.sh`, closing the
  nothing-ever-built-the-tag-as-a-dependency gap. First exercised against
  the published v1.2.0 tag in swift:5.10-jammy — anonymous resolve, build,
  and import all green, and `from: "1.1.0"` confirmed to float up to 1.2.0
  (floor semantics working; the pinned revision matched the mirror's
  `^{}`-peeled commit exactly).
- **2026-11-25** — package-versioning policy added (pdfswift-88877757,
  defined in codegen-refresh.md "Package-versioning policy"): SDK-only
  releases move the tag one patch ahead of the drop and touch no stamp;
  the triple above names one version only on a drop-cut release. The tag
  message and the pre-announcement check now take the release version and
  the drop stamp as separate values (they were conflated before, which
  would have mislabeled an SDK-only tag and false-alarmed the mirror
  check).
