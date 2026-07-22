# bf-3tn — pdftract-swift origin remote hosting (Forgejo vs GitHub)

**Status: RESOLVED — the deviation no longer exists.** Filed 2026-07-20 as an
artifact-improvement finding; verified and closed 2026-07-22. This note records
the verification so the finding doesn't re-open on a future audit.

## What the bead alleged

> pdftract-swift's only git remote is `origin -> github.com/jedarden/pdftract-swift.git`,
> with no Forgejo (git.ardenone.com) presence (probe returned 403). This deviates
> from the workspace policy that Forgejo is source-of-truth and GitHub is a
> read-only mirror. ADR-1 commit `8ea5b02` was therefore left unpushed.

## Current reality (verified 2026-07-22)

1. **`origin` is Forgejo, not GitHub.**
   ```
   $ git remote -v
   origin  https://git.ardenone.com/jedarden/pdftract-swift.git (fetch)
   origin  https://git.ardenone.com/jedarden/pdftract-swift.git (push)
   ```
   The repo has been migrated onto Forgejo since the bead was filed. This is the
   bead's option (b) — "bring it into the standard pattern" — already carried out.

2. **GitHub is now a live mirror of Forgejo** (Forgejo→GitHub push mirror).
   ```
   $ git ls-remote https://github.com/jedarden/pdftract-swift.git HEAD
   78d3d8c0e2458305f396cc22b93c5dd075cc3650        HEAD   # github.com
   $ git rev-parse origin/main
   78d3d8c0e2458305f396cc22b93c5dd075cc3650              # git.ardenone.com (Forgejo)
   ```
   Identical SHA on both — the public GitHub repo reflects pushes to Forgejo, i.e.
   the intended Forgejo-source / GitHub-mirror topology is in place and in sync.
   (Mirror config itself is behind Forgejo's auth: the unauthenticated API returns
   `403 Only signed in user is allowed to call APIs`, so config can't be read
   without credentials — but the observable HEAD equality confirms the mirror.)

3. **The "403 = no Forgejo presence" read in the bead was a misread.** Forgejo's
   public web API requires a signed-in session; an unauthenticated probe returns
   `403` for *any* repo, present or not. `403` here is auth-gating, not evidence
   of absence — the repo is plainly reachable as `origin` (fetch/push succeed).

4. **The ADR-1 commit `8ea5b02` is pushed.** The bead held it back to avoid
   pushing to a github.com remote; with `origin` now Forgejo it has since been
   pushed and is an ancestor of `origin/main` (verified via
   `git merge-base --is-ancestor 8ea5b02 origin/main`).

5. **No codified policy is being deviated from.** A grep of the global
   `/home/coding/CLAUDE.md` for `forgejo | push_mirror | mirror | source of truth |
   git.ardenone` returns no matches — the "workspace-wide policy" the bead cites is
   not actually written into CLAUDE.md. Even taking the convention at face value,
   this repo now conforms to it.

## README install URL still points at github.com — and that is correct

`README.md` and `docs/plan/plan.md` reference `https://github.com/jedarden/pdftract-swift`.
This is **intentional and correct**, not a lingering deviation: this is a public
SwiftPM package, and `github.com` is its public mirror. SwiftPM consumers resolve
from the public URL; `git.ardenone.com` is internal (Tailscale) and must not
appear in consumer-facing install instructions. Leaving the README on github.com
is exactly the Forgejo-source / GitHub-public-mirror pattern. **No README change
needed.**

## Repository hygiene performed while resolving

- The local `main` had diverged from `origin/main`: a prior `commit --amend` of the
  bf-um4 checkpoint produced local `8379cbb` while origin retained the pre-amend
  `78d3d8c`. The two had an **empty content diff** (the amend only appended a
  `Bead-Id: bf-um4` trailer to the message). To make this bead's push a clean
  fast-forward (CLAUDE.md forbids force-push), local `main` was reset to
  `origin/main` (`78d3d8c`). No content was lost; the amended trailer is
  recoverable from `git reflog` and bf-um4 is already closed.
- After reset, `HEAD == origin/main == 78d3d8c`, working tree clean.

## Outcome

The hosting deviation described by bf-3tn is **obsolete** — the Forgejo migration
and GitHub mirror it called for are already in place and verified. No code,
Package.swift, or README changes are warranted. This note is the deliverable;
no further action required.
