import XCTest
@testable import MuralCore

final class TokenBudgetTests: XCTestCase {
    func testAfmDefaultParameters() {
        let budget = TokenBudget.afmDefault
        XCTAssertEqual(budget.contextWindow, 4096)
        XCTAssertEqual(budget.callBudget, 3200)
        XCTAssertEqual(budget.responseReserve, 640)
        XCTAssertTrue(budget.fits(promptTokens: 3200))
        XCTAssertFalse(budget.fits(promptTokens: 3201))
    }

    func testInvalidBudgetReturnsNil() {
        XCTAssertNil(TokenBudget(contextWindow: 0, callBudget: 10, responseReserve: 10))
        XCTAssertNil(TokenBudget(contextWindow: 100, callBudget: 0, responseReserve: 10))
        XCTAssertNil(TokenBudget(contextWindow: 100, callBudget: 80, responseReserve: 30)) // 80 + 30 > 100
        XCTAssertNil(TokenBudget(contextWindow: 100, callBudget: 80, responseReserve: -1))
    }

    func testValidCustomBudget() {
        let budget = TokenBudget(contextWindow: 8192, callBudget: 6000, responseReserve: 1000)
        XCTAssertNotNil(budget)
        XCTAssertTrue(budget!.fits(promptTokens: 5000))
        XCTAssertFalse(budget!.fits(promptTokens: 6001))
    }
}
