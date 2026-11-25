#!/usr/bin/env bash
# SwiftPM consumer smoke check: install this SDK the way the README says to.
#
# Exercises the README's front door end to end, as an external consumer sees
# it (bead pdfswift-41fd9985): a fresh scratch package — outside this
# checkout, in a container, with no git credentials — pins
#
#     .package(url: "https://github.com/jedarden/pdftract-swift", from: X.Y.Z)
#
# with the version the README currently publishes, SwiftPM resolves the tag
# anonymously over the network, builds the `Pdftract` product, and an
# executable mirroring the README's "Basic extract" snippet imports it.
#
# Nothing here reads the local checkout's sources: the version under test is
# whatever the published tag carries, which is the point. This catches
# releases whose tag does not build as a dependency, a README `from:` above
# the newest published tag (consumers broken on day one), and platform
# declarations that break Linux consumers — the `.linux(.v4)` class of
# failure (pdfswift-d9676b80). It is the consumer-side complement to the
# `pdftract-swift-build` gate, which clones main HEAD and never builds a tag.
#
# The version defaults to the `from:` value currently published in
# README.md, so the check cannot drift from the front door it verifies;
# pass an explicit version to test another one (the v1.1.0 floor, or a
# candidate before announcing it).
#
# Needs: docker with the `swift:5.10-jammy` image (same toolchain as the CI
# gate — the host has no Swift toolchain) and network access to github.com.
# Resolution is anonymous by design: that is exactly how every consumer
# resolves the package, so any credential this script could carry would be
# testing something a consumer cannot do.
#
# `.build` is shadowed with an anonymous container volume (same trick as
# definition-of-done.sh) so the container's root-owned artifacts never land
# in the scratch dir; everything it does write is chown'd back to the
# invoking user before exit so the trap's cleanup succeeds.
#
# Exit code is the verdict: 0 = resolve + build + run all passed.
#
# Usage: scripts/spm-install-smoke.sh [VERSION]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://github.com/jedarden/pdftract-swift"
IMAGE=swift:5.10-jammy
VERSION="${1:-}"

if ! command -v docker >/dev/null 2>&1; then
    echo "spm-install-smoke: docker not found on PATH (no host Swift toolchain)" >&2
    exit 3
fi

if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's|.*\.package(url: [^,]*pdftract-swift", from: "\([0-9][0-9.]*\)").*|\1|p' \
        "$REPO_ROOT/README.md" | head -n1)"
    if [ -z "$VERSION" ]; then
        echo "spm-install-smoke: could not parse the README's from: version; pass one explicitly" >&2
        exit 2
    fi
fi

echo "== smoke-checking the README front door: $URL, from: $VERSION"

WORK="$(mktemp -d /tmp/spm-install-smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/smoke-consumer"

# The consumer's manifest mirrors exactly what the README tells a consumer
# to add — same URL, same from: requirement.
cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 5.10
// Consumer smoke package (scripts/spm-install-smoke.sh): what README.md
// tells a consumer to do, verbatim.
import PackageDescription

let package = Package(
    name: "smoke-consumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "$URL", from: "$VERSION")
    ],
    targets: [
        .executableTarget(
            name: "smoke-consumer",
            dependencies: [.product(name: "Pdftract", package: "pdftract-swift")])
    ]
)
EOF

cat > "$WORK/Sources/smoke-consumer/main.swift" <<'EOF'
// README "Basic extract" snippet. The only deviation from the README is the
// do/catch: the scratch container has no pdftract backend binary on PATH, so
// the call throws and we print it — proving the module links and its error
// surface works end to end rather than crashing the process.
import Pdftract

let client = Pdftract()

do {
    let doc = try await client.extract(.path("document.pdf"))
    print("Pages: \(doc.pages.count)")
    print("Title: \(doc.metadata.title ?? "Untitled")")
} catch {
    print("caught (expected without a backend binary): \(error)")
}
EOF

cat > "$WORK/run-smoke.sh" <<'EOF'
#!/usr/bin/env bash
# Runs inside the container. Stage-by-stage so a failure names its stage.
set -uo pipefail
status=0
echo "-- resolve --"
swift package resolve || status=1
if [ "$status" -eq 0 ]; then
    echo "-- Package.resolved --"
    cat Package.resolved
    echo "-- build --"
    swift build || status=2
fi
if [ "$status" -eq 0 ]; then
    echo "-- run --"
    swift run smoke-consumer || status=3
fi
# Give the scratch dir back to the invoking user so the host-side trap can
# clean it up (the container runs as root).
chown -R "$SMOKE_UID_GID" /workspace
exit "$status"
EOF

STATUS=0
docker run --rm \
    -e "SMOKE_UID_GID=$(id -u):$(id -g)" \
    -v "$WORK":/workspace \
    -v /workspace/.build \
    -w /workspace \
    "$IMAGE" \
    bash /workspace/run-smoke.sh || STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    # Report the version actually pinned, not the requested floor: `from:`
    # resolves upward, so from: 1.1.0 pins 1.2.0 — the summary must not blur
    # that. (The quoted-value pattern skips the unquoted format-level
    # `"version" : 3` line; the pin's version comes first.)
    RESOLVED="$(sed -n 's/.*"version" : "\(.*\)".*/\1/p' "$WORK/Package.resolved" | head -n1)"
    echo "== PASS: from: ${VERSION} resolved at ${RESOLVED:-unknown}; built the Pdftract product, imported it from a consumer executable"
else
    echo "== FAIL (exit $STATUS): see the docker output above" >&2
fi
exit "$STATUS"
