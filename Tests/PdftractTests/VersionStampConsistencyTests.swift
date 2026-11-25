//
// Version-stamp consistency gate — the mechanical half of the refresh
// discipline in docs/notes/codegen-refresh.md (pdfswift-b2b1cd42).
//
// A codegen drop stamps ONE version literal into four checked-in sites: the
// `.codegen-version` provenance file, the README's SwiftPM `from:`
// requirement, the README's "generated against pdftract N.N.N" line, and the
// README's release link (a `v`-prefixed tag). No existing gate sees a
// mismatch between them: `sdk validate` deliberately ignores
// `.codegen-version` and always diffs README.md against a skeleton generated
// at the default `0.1.0`, so those README lines "differ" for every real
// release; the CI regenerate-and-diff cannot catch a wrong stamp if it
// regenerates with the same wrong version; and until now the only safeguard
// was prose. This suite fails loudly on the two documented failure modes:
//
//   1. Inconsistency — a drop regenerated with `--version N` but checked in
//      without the README (or with a hand-edited site, which is drift
//      anyway) leaves the literals disagreeing. Every occurrence of each
//      stamp site must equal `.codegen-version`, and a site disappearing
//      from README.md entirely is also a failure, not a pass-by-absence.
//   2. The omitted-flag default — omitting `--version` stamps pdftract's
//      own Cargo version, `0.1.0`, consistently into ALL sites, so a pure
//      consistency check would pass. `0.1.0` is therefore rejected outright:
//      it is exactly the documented leaked default, and no release this SDK
//      was generated against carries it (v1.1.0, v1.2.0 shipped; if pdftract
//      ever genuinely releases 0.1.0, reconsider `generatorDefaultStamp`
//      here consciously, don't discover it by a red gate).
//
// Hand-written, not generated: this file is not a codegen template output,
// so `pdftract sdk codegen` leaves it alone (the generator writes only the
// nine paths listed in codegen-refresh.md and never deletes unknown files) —
// the same standing as ExitCodeMappingTests.swift and
// SourceBytesPassthroughTests.swift. Keep it that way. It needs no pdftract
// binary and no network: it reads repo files relative to `#filePath`, so it
// runs — and fails loudly — in every environment the `swift test` gate runs
// in, including binary-less CI containers.
//
// What is deliberately NOT pinned here:
//
//   - The git tag this repo carries. Under the versioning policy
//     (codegen-refresh.md, "Package-versioning policy") the tag equals the
//     stamp on the normal drop-cut release and runs one patch ahead of it
//     on an SDK-only release — but a `git archive` extraction (and any
//     clone without refs) cannot see tags, so that relation stays a
//     release-runbook check rather than a gate here.
//   - The README receipt example's `"extraction_version": "..."` value. That
//     is example CLI output showing a pdftract extraction receipt, not an
//     SDK stamp, and the CLI that produced it is the binary's concern.
//
// Package.swift is pinned in the opposite direction: it must carry NO
// version literal at all. A SwiftPM package's version comes from its git
// tag — the README `from:` requirement is how consumers reference it — so
// today the manifest has nothing to cross-check. If a future template starts
// stamping a version into the manifest, this suite fails until that stamp is
// added to the consistency set above, rather than silently joining the set
// of literals nobody checks.
//

import Foundation
import XCTest

final class VersionStampConsistencyTests: XCTestCase {

    /// The documented leaked default of `pdftract sdk codegen` without
    /// `--version` (pdftract's own Cargo version). Rejected even when every
    /// stamp site agrees on it — that is the failure mode the consistency
    /// check alone cannot see.
    private static let generatorDefaultStamp = "0.1.0"

    // MARK: Stamp-site patterns (capture group = the version literal)

    /// README "Installation": `.package(url: ..., from: "1.2.0")`.
    private static let swiftPMRequirement =
        "from:\\s*\"([0-9]+\\.[0-9]+\\.[0-9]+)\""
    /// README "Binary version compatibility": "generated against pdftract
    /// 1.2.0".
    private static let generatedAgainst =
        "generated against pdftract ([0-9]+\\.[0-9]+\\.[0-9]+)"
    /// README "Binary version compatibility": the release link. The `v` is
    /// part of the pattern, not the capture — a link without the prefix
    /// simply stops matching and fails by absence.
    private static let releaseLink =
        "releases/tag/v([0-9]+\\.[0-9]+\\.[0-9]+)"
    /// Any three-component version literal, for the Package.swift tripwire.
    /// Toolchain and platform versions never take this shape
    /// (`swift-tools-version: 5.10`, `.macOS(.v13)`).
    private static let semverLiteral = "[0-9]+\\.[0-9]+\\.[0-9]+"

    // MARK: - 1. The provenance file itself

    func testCodegenVersionIsPlainSemverAndNotTheGeneratorDefault() throws {
        _ = try versionStamp()
    }

    // MARK: - 2. README stamp sites

    func testReadmeInstallSnippetMatchesCodegenVersion() throws {
        let stamp = try versionStamp()
        let readme = try readRepoFile("README.md")
        try assertAllOccurrences(Self.swiftPMRequirement, in: readme,
                                 equal: stamp,
                                 site: "SwiftPM `from:` requirement")
    }

    func testReadmeGeneratedAgainstLineMatchesCodegenVersion() throws {
        let stamp = try versionStamp()
        let readme = try readRepoFile("README.md")
        try assertAllOccurrences(Self.generatedAgainst, in: readme,
                                 equal: stamp,
                                 site: "\"generated against pdftract\" line")
    }

    func testReadmeReleaseLinkMatchesCodegenVersion() throws {
        let stamp = try versionStamp()
        let readme = try readRepoFile("README.md")
        try assertAllOccurrences(Self.releaseLink, in: readme,
                                 equal: stamp,
                                 site: "pdftract release link")
    }

    // MARK: - 3. Package.swift tripwire

    func testPackageSwiftCarriesNoVersionLiteral() throws {
        let manifest = try readRepoFile("Package.swift")
        let found = try captures(Self.semverLiteral, capture: 0, in: manifest)
        XCTAssertTrue(
            found.isEmpty,
            "Package.swift gained version literal(s) \(found.joined(separator: ", ")). A SwiftPM package's version comes from its git tag, not the manifest — if the generator now stamps one there, extend this suite's consistency set to cover it instead of leaving it unchecked"
        )
    }

    // MARK: - Fixtures and helpers

    /// `<repo root>`, derived from this file's location
    /// (`<root>/Tests/PdftractTests/VersionStampConsistencyTests.swift`),
    /// so the suite reads the checked-out tree it was compiled from and
    /// works in any checkout path, including CI clones and `git archive`
    /// extractions.
    private var repoRoot: String {
        let filePath = #filePath
        let fileDir = (filePath as NSString).deletingLastPathComponent
        let testsDir = (fileDir as NSString).deletingLastPathComponent
        return (testsDir as NSString).deletingLastPathComponent
    }

    private enum GateError: Error {
        case missingFile(String)
        case invalidStamp(String)
    }

    /// The `.codegen-version` provenance stamp: trimmed, plain `X.Y.Z`
    /// semver without a `v` prefix, and never the generator's
    /// omitted-`--version` default. XCTFails with the fix in the message,
    /// then throws so callers stop instead of asserting against garbage.
    private func versionStamp(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let raw = try readRepoFile(".codegen-version", file: file, line: line)
        let stamp = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        var problem: String? = nil
        if stamp.isEmpty {
            problem = ".codegen-version is empty — every drop must record the pdftract release it was emitted from (docs/notes/codegen-refresh.md)"
        } else if stamp.hasPrefix("v") {
            problem = ".codegen-version must be plain semver without a v prefix, got '\(stamp)' — tags carry the v (SwiftPM strips it), the provenance file never does"
        } else if stamp.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil {
            problem = ".codegen-version must be a full X.Y.Z semver literal, got '\(stamp)'"
        } else if stamp == Self.generatorDefaultStamp {
            problem = ".codegen-version is 0.1.0 — pdftract's own Cargo version, i.e. the documented default leaked by omitting --version on `sdk codegen`. Regenerate with --version <the pdftract release the drop came from> per docs/notes/codegen-refresh.md; if 0.1.0 ever becomes a genuine pdftract release, revisit generatorDefaultStamp in VersionStampConsistencyTests first"
        }

        guard let problem = problem else { return stamp }
        XCTFail(problem, file: file, line: line)
        throw GateError.invalidStamp(stamp)
    }

    private func readRepoFile(
        _ relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let path = repoRoot + "/" + relativePath
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("expected repo file is missing (run this suite from the package checkout, not an installed product): \(path)", file: file, line: line)
            throw GateError.missingFile(path)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Every match of `pattern`'s capture group in `text` must equal
    /// `expected`. Zero matches is a failure too: the stamp site the pattern
    /// pins has disappeared from the generated output, and absence must not
    /// read as agreement.
    private func assertAllOccurrences(
        _ pattern: String,
        in text: String,
        equal expected: String,
        site: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let found = try captures(pattern, capture: 1, in: text)
        if found.isEmpty {
            XCTFail("no \(site) found in README.md — the generated version block is missing or its wording changed; restore the stamp site or extend this suite consciously", file: file, line: line)
            return
        }
        let wrong = found.filter { $0 != expected }
        XCTAssertTrue(
            wrong.isEmpty,
            "version-stamp mismatch at the \(site): README says \(wrong.joined(separator: ", ")) but .codegen-version says \(expected). Regenerate the drop with an explicit --version per docs/notes/codegen-refresh.md, or fix the stale site",
            file: file, line: line
        )
    }

    private func captures(
        _ pattern: String,
        capture: Int,
        in text: String
    ) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        return matches.compactMap { match in
            guard match.numberOfRanges > capture,
                  match.range(at: capture).location != NSNotFound else {
                return nil
            }
            return nsText.substring(with: match.range(at: capture))
        }
    }
}
