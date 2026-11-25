#!/usr/bin/env bash
# End-to-end SDK ↔ binary verification against the pinned pdftract release.
#
# The only check that catches serialization drift between this SDK's
# generated types and the pdftract binary the README names (bead
# pdfswift-3307a377): every other gate runs `swift test` where no binary is
# installed, so the three binary-gated suites (ConformanceTests,
# ExtractStreamConformanceTests, DocumentedApiConformanceTests) hit their
# XCTSkip guards and verify nothing. This script installs the pinned
# release, runs the full suite with it on PATH, and then refuses to honor
# a run in which anything skipped — a broken download or a PATH problem
# would otherwise look exactly like a green run.
#
# What it does:
#   1. resolves the pinned version from README.md's release link (the same
#      link "Binary version compatibility" tells consumers to download),
#   2. downloads that release tarball + SHA256SUMS from the public GitHub
#      mirror — the URL the README publishes; anonymous download is the
#      consumer's path (the Forgejo source-of-truth instance gates release
#      attachments behind sign-in, so a credential would test something a
#      consumer cannot do — same reasoning as spm-install-smoke.sh),
#      and verifies the tarball against the published sums before use,
#   3. runs `swift test` in the swift:5.10-jammy image — the same image and
#      the same suite as the definition-of-done gate — with the binary
#      mounted read-only onto a PATH directory inside the container, so
#      the binary-gated suites EXECUTE instead of skip,
#   4. fails if the suite failed OR if any single test was skipped: inside
#      this run the guard can only mean provisioning broke, and a pin that
#      silently stops running is exactly the drift this gate exists to
#      catch. (ProcessLifecycleTests runs too since pdfswift-b64f41eb:
#      its fake binaries now survive containerized environments, and its
#      fake children ignore their arguments, so the pinned binary's real
#      behavior is irrelevant to them.)
#
# Verdict, per the run this script was written for (2026-11-25, v1.2.0):
# the suite is GREEN against the release binary as it ships — the
# binary-gated tests are reality pins (DocumentedApiConformanceTests and
# the converted ExtractStreamConformanceTests pins) asserting the binary's
# actual behavior, with flip notes naming what to assert when the
# generator converges with the binary (proposal pdfswift-ccccb2ff). A red
# result here therefore means reality MOVED — a new binary, a regenerated
# SDK, or a changed pin — and the red pin's comment is the instruction.
# The divergence inventory (docs/notes/v1.2.0-binary-divergence-inventory.md)
# is the prose form of what the pins assert.
#
# `.build` is shadowed with an anonymous container volume (same trick as
# definition-of-done.sh) so the container's root-owned build artifacts
# never land in the verified directory.
#
# Needs: docker with the swift:5.10-jammy image, curl, and network access
# to github.com. The download happens on the host; the container needs no
# network.
#
# Exit code is the verdict: 0 = checksum-verified binary, full suite
# green, zero skips. Nonzero (with a stage-tagged message) otherwise.
#
# Usage: scripts/e2e-binary-verification.sh [CHECKOUT_DIR]
#   CHECKOUT_DIR defaults to the checkout that owns this script; pass a
#   fresh `git archive HEAD` extraction to verify the committed revision
#   (how a gate run should invoke it). PDFTRACT_VERSION overrides the
#   version pin; PDFTRACT_RELEASE_BASE_URL overrides the download root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-$REPO_ROOT}"
IMAGE=swift:5.10-jammy

die() { echo "e2e-binary-verification: $*" >&2; exit "${2:-1}"; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH (no host Swift toolchain)" 3
command -v curl   >/dev/null 2>&1 || die "curl not found on PATH" 3
[ -d "$TARGET" ] || die "target checkout not a directory: $TARGET" 2
[ -f "$TARGET/Package.swift" ] || die "no Package.swift under $TARGET — pass a checkout, not a tarball" 2

# -- Stage 1: resolve the pinned version ------------------------------------
#
# The README's "Binary version compatibility" section names the release
# this SDK was generated against; parsing it keeps the gate from drifting
# from the front door it verifies (spm-install-smoke.sh's convention).
VERSION="${PDFTRACT_VERSION:-$(sed -n 's|.*releases/tag/v\([0-9][0-9.]*\).*|\1|p' "$REPO_ROOT/README.md" | head -n1)}"
[ -n "$VERSION" ] || die "could not parse the pinned release version from README.md; pass PDFTRACT_VERSION" 2

case "$(uname -m)" in
    x86_64)          ARCH=x86_64 ;;
    aarch64|arm64)   ARCH=aarch64 ;;
    *) die "unsupported architecture: $(uname -m) (release ships x86_64 and aarch64 musl builds)" 2 ;;
esac

TARBALL="pdftract-v${VERSION}-${ARCH}-unknown-linux-musl.tar.gz"
BASE_URL="${PDFTRACT_RELEASE_BASE_URL:-https://github.com/jedarden/pdftract/releases/download/v${VERSION}}"

echo "== e2e-binary-verification: target $TARGET"
echo "== release: v${VERSION} ($ARCH) from $BASE_URL"

WORK="$(mktemp -d /tmp/e2e-binary-verification.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# -- Stage 2: download + checksum-verify the release -------------------------
curl -fSL --retry 3 -o "$WORK/$TARBALL" "$BASE_URL/$TARBALL" \
    || die "download failed: $BASE_URL/$TARBALL" 4
curl -fSL --retry 3 -o "$WORK/SHA256SUMS" "$BASE_URL/SHA256SUMS" \
    || die "download failed: $BASE_URL/SHA256SUMS" 4

# SHA256SUMS covers every release artifact; verify only the line for the
# tarball this run downloads (the other arch's file is not here).
grep " $TARBALL\$" "$WORK/SHA256SUMS" > "$WORK/want.sums"
[ -s "$WORK/want.sums" ] || die "$TARBALL not listed in SHA256SUMS — refusing an unlisted artifact" 4
(cd "$WORK" && sha256sum -c want.sums) \
    || die "checksum mismatch for $TARBALL against the published SHA256SUMS" 4
echo "== checksum ok: $(cat "$WORK/want.sums")"

tar -xzf "$WORK/$TARBALL" -C "$WORK"
BIN_DIR="$WORK/pdftract-v${VERSION}-${ARCH}-unknown-linux-musl"
[ -x "$BIN_DIR/pdftract" ] || die "tarball has no executable pdftract at pdftract-v${VERSION}-${ARCH}-unknown-linux-musl/" 4
"$BIN_DIR/pdftract" --version >/dev/null \
    || die "release binary cannot execute on this host" 4

# -- Stage 3: full suite with the binary on PATH -----------------------------
#
# Same image, same suite, same volume trick as definition-of-done.sh, plus
# the one thing that gate cannot do: a real binary the binary-gated suites
# can resolve. /pdftract-bin is read-only; the tests only ever execute the
# binary and read its output.
echo "== running: swift test (with pdftract v${VERSION} on PATH)"
set +e
docker run --rm \
    -v "$TARGET":/workspace \
    -v /workspace/.build \
    -v "$BIN_DIR":/pdftract-bin:ro \
    -w /workspace \
    "$IMAGE" \
    bash -c 'export PATH=/pdftract-bin:$PATH; swift test' \
    2>&1 | tee "$WORK/test-output.log"
STATUS=${PIPESTATUS[0]}
set -e

# -- Stage 4: verdict — green AND nothing skipped -----------------------------
#
# The zero-skip demand is the point of this script. Without it, a wrong
# checksum, a bad mount, or a PATH mistake degrades every binary-gated
# suite into its XCTSkip guard and the run "passes" having exercised
# nothing. A failed run keeps its full output at a stable path for
# diagnosis (the work dir itself is trap-cleaned).
KEEP_LOG=/tmp/e2e-binary-verification-failure.log
SKIPS="$(grep -c "Test Case.*skipped" "$WORK/test-output.log" || true)"
if [ "$STATUS" -ne 0 ]; then
    cp "$WORK/test-output.log" "$KEEP_LOG"
    echo "== FAIL (exit $STATUS): suite failed with pdftract v${VERSION} on PATH" >&2
    echo "   full output retained: $KEEP_LOG" >&2
    grep -E "Test Case.*(failed|error)" "$KEEP_LOG" | head -20 >&2 || true
    exit "$STATUS"
fi
if [ "$SKIPS" -ne 0 ]; then
    cp "$WORK/test-output.log" "$KEEP_LOG"
    echo "== FAIL: $SKIPS test(s) SKIPPED in the provisioned run — every skip is a" >&2
    echo "   provisioning failure or a pin that stopped running. Skipped cases:" >&2
    grep "Test Case.*skipped" "$KEEP_LOG" >&2
    echo "   full output retained: $KEEP_LOG" >&2
    exit 4
fi

echo "== PASS: suite green with pdftract v${VERSION} on PATH, zero tests skipped:"
grep -E "^Test Suite 'All tests'|Executed.*tests" "$WORK/test-output.log" | tail -3
exit 0
