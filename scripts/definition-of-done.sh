#!/usr/bin/env bash
# Definition of done for pdftract-swift.
#
# This script is the workspace's declared verifier: NEEDLE's fallback
# selection picks `scripts/definition-of-done.sh` ahead of every language
# marker, and Swift is not a language NEEDLE detects at all. Without this
# script the workspace has no runnable verifier, so every bead is judged by
# the `fallback_clean_tree` gate instead — which demands a clean *shared*
# checkout and can never pass while any worker holds in-flight edits or the
# checkpoint automation has staged shard deltas (workspace degraded after 11
# consecutive gate errors on 2026-11-25, bead pdfswift-18f02c1a attempts
# 12-14). Run against a clean extraction of the committed revision — which
# is how NEEDLE invokes it — the script carries no shared-tree precondition.
#
# The host has no Swift toolchain; the build runs in the same
# `swift:5.10-jammy` image the `pdftract-swift-build` CI gate on iad-ci
# uses, so local verdicts match the CI gate's verdicts.
#
# Modes:
#   scripts/definition-of-done.sh          full CI-gate mirror:
#                                          swift test --skip ProcessLifecycleTests
#   scripts/definition-of-done.sh --fast   compile-only: swift build --build-tests
#
# `--skip ProcessLifecycleTests` mirrors the iad-ci gate (b947d7a35, live
# 2026-11-25T03:00Z): the suite's process-spawn/cancellation assertions time
# out in containerized environments — an environment limitation, not a
# regression signal (3/6 fail at unchanged repo content in this image).
#
# `.build` is shadowed with an anonymous container volume so the container's
# root-owned build artifacts never land in the directory being verified
# (a fresh extraction would otherwise need root to clean up).
#
# Exit code is the verdict: 0 = done, nonzero = not done.

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=swift:5.10-jammy

case "${1:-}" in
    "")        COMMAND="swift test --skip ProcessLifecycleTests" ;;
    --fast)    COMMAND="swift build --build-tests" ;;
    *)         echo "usage: $0 [--fast]" >&2; exit 2 ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    echo "definition-of-done: docker not found on PATH (no host Swift toolchain)" >&2
    exit 3
fi

exec docker run --rm \
    -v "$PWD":/workspace \
    -v /workspace/.build \
    -w /workspace \
    "$IMAGE" \
    bash -c "$COMMAND"
