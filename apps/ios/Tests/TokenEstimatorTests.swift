import XCTest
@testable import MuralCore

final class TokenEstimatorTests: XCTestCase {
    let estimator = TokenEstimator(bytesPerToken: 3)

    func testEmptyStringReturnsZero() {
        XCTAssertEqual(estimator.tokens(in: ""), 0)
    }

    func testAsciiTokenEstimation() {
        // 3 bytes = 1 token
        XCTAssertEqual(estimator.tokens(in: "abc"), 1)
        // 4 bytes = 2 tokens (ceiling of 4 / 3)
        XCTAssertEqual(estimator.tokens(in: "abcd"), 2)
        // 6 bytes = 2 tokens
        XCTAssertEqual(estimator.tokens(in: "abcdef"), 2)
    }

    func testMultipleTexts() {
        XCTAssertEqual(estimator.tokens(in: ["abc", "def"]), 2)
    }
}
