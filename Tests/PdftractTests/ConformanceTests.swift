//
// Conformance test suite for pdftract Swift SDK
// Auto-generated - do not edit manually
//

import XCTest
@testable import Pdftract

final class ConformanceTests: XCTestCase {
    var client: Pdftract!
    var suite: [String: Any]?

    override func setUp() {
        client = Pdftract()

        let suitePath = ProcessInfo.processInfo.environment["CONFORMANCE_SUITE"] ?? "tests/sdk-conformance/cases.json"

        if let data = try? Data(contentsOf: URL(fileURLWithPath: suitePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            suite = json
        }
    }

    func testBinaryAvailable() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "pdftract --version"]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "pdftract binary not found on PATH")
    }

    func testConformance() async throws {
        guard let suite = suite,
              let cases = suite["cases"] as? [[String: Any]] else {
            throw XCTSkip("No conformance suite loaded")
        }

        for testCase in cases {
            let id = testCase["id"] as? String ?? "unknown"
            let method = testCase["method"] as? String ?? "unknown"

            try await runTestCase(testCase, fixturePath: "fixtures/\(testCase["fixture"] as? String ?? "")")
        }
    }

    private func runTestCase(_ testCase: [String: Any], fixturePath: String) async throws {
        guard let method = testCase["method"] as? String else {
            throw XCTSkip("No method specified")
        }

        switch method {
        case "extract":
            try await testExtract(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "extract_text":
            try await testExtractText(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "extract_markdown":
            try await testExtractMarkdown(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "get_metadata":
            try await testGetMetadata(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "hash":
            try await testHash(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "classify":
            try await testClassify(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "verify_receipt":
            try await testVerifyReceipt(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "search":
            try await testSearch(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        case "extract_stream":
            try await testExtractStream(fixturePath, assertions: testCase["assertions"] as? [String: Any])
        default:
            throw XCTSkip("Method not yet implemented: \(method)")
        }
    }

    private func testExtract(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let doc = try await client.extract(.path(fixturePath))

        if let pageCount = assertions?["page_count"] as? Int {
            XCTAssertEqual(doc.pages.count, pageCount)
        }

        if let hasTitle = assertions?["has_title"] as? Bool, hasTitle {
            XCTAssertNotNil(doc.metadata.title)
        }
    }

    private func testExtractText(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let text = try await client.extractText(.path(fixturePath))

        if let minLen = assertions?["min_length"] as? Int {
            XCTAssertGreaterThanOrEqual(text.count, minLen)
        }

        if let contains = assertions?["contains"] as? [String] {
            for substr in contains {
                XCTAssertTrue(text.contains(substr), "Expected text to contain: \(substr)")
            }
        }
    }

    private func testExtractMarkdown(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let md = try await client.extractMarkdown(.path(fixturePath))

        if let minLen = assertions?["min_length"] as? Int {
            XCTAssertGreaterThanOrEqual(md.count, minLen)
        }
    }

    private func testGetMetadata(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let metadata = try await client.getMetadata(.path(fixturePath))

        if let pageCount = assertions?["page_count"] as? Int {
            XCTAssertEqual(metadata.pageCount, pageCount)
        }
    }

    private func testHash(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let fingerprint = try await client.hash(.path(fixturePath))

        XCTAssertEqual(fingerprint.hash.count, 64)
        XCTAssertEqual(fingerprint.fastHash.count, 64)

        if let pageCount = assertions?["page_count"] as? Int {
            XCTAssertEqual(fingerprint.pageCount, pageCount)
        }
    }

    private func testClassify(_ fixturePath: String, assertions: [String: Any]?) async throws {
        let classification = try await client.classify(.path(fixturePath))

        XCTAssertFalse(classification.category.isEmpty)
        XCTAssertTrue(classification.confidence >= 0 && classification.confidence <= 1)
    }

    private func testVerifyReceipt(_ fixturePath: String, assertions: [String: Any]?) async throws {
        guard let receipt = assertions?["receipt"] as? String else {
            throw XCTSkip("Receipt not provided in assertions")
        }

        let receiptStruct = Receipt(data: receipt)
        let valid = try await client.verifyReceipt(fixturePath, receipt: receiptStruct)

        if let expectedValid = assertions?["valid"] as? Bool {
            XCTAssertEqual(valid, expectedValid)
        }
    }

    private func testSearch(_ fixturePath: String, assertions: [String: Any]?) async throws {
        guard let pattern = assertions?["pattern"] as? String else {
            throw XCTSkip("Pattern not provided in assertions")
        }

        var matchCount = 0
        for await _ in client.search(.path(fixturePath), pattern) {
            matchCount += 1
            if let maxResults = assertions?["max_results"] as? Int, matchCount >= maxResults {
                break
            }
        }

        if let minMatches = assertions?["min_matches"] as? Int {
            XCTAssertGreaterThanOrEqual(matchCount, minMatches)
        }
    }

    private func testExtractStream(_ fixturePath: String, assertions: [String: Any]?) async throws {
        var pageCount = 0
        for await _ in client.extractStream(.path(fixturePath)) {
            pageCount += 1
        }

        if let expectedPages = assertions?["page_count"] as? Int {
            XCTAssertEqual(pageCount, expectedPages)
        }
    }
}
