import XCTest
@testable import MuralCore

final class TranscriptCondenserTests: XCTestCase {
    func testDeterministicSummarizerCapsLength() async throws {
        let summarizer = DeterministicSummarizer(maxSummaryCharacters: 100)
        let exchanges = [
            ConversationExchange(index: 0, learner: "Hello, how are you doing today?", partner: "I am doing well, thank you! How about you?"),
            ConversationExchange(index: 1, learner: "I went to the store and bought some coffee.", partner: "That sounds wonderful, what kind of coffee?")
        ]
        let summary = try await summarizer.summarize(existingSummary: nil, exchanges: exchanges)
        XCTAssertLessThanOrEqual(summary.count, 100)
        XCTAssertTrue(summary.contains("L:") || summary.contains("M:"))
    }

    func testCondenserPassesThroughWhenUnderBudget() async {
        let condenser = TranscriptCondenser()
        let history = ConversationHistory(summary: nil, exchanges: [
            ConversationExchange(index: 0, learner: "Hi", partner: "Hello")
        ])
        let outcome = await condenser.condenseIfNeeded(
            instructions: "Short instructions",
            history: history,
            pendingUtterance: "How are you?"
        )
        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.history.exchanges.count, 1)
    }

    func testCondenserDegradationWhenExceedingBudget() async {
        guard let smallBudget = TokenBudget(contextWindow: 100, callBudget: 50, responseReserve: 20) else {
            XCTFail("Failed to build budget")
            return
        }
        let condenser = TranscriptCondenser(budget: smallBudget, keepRecentExchanges: 2)
        var exchanges: [ConversationExchange] = []
        for i in 0..<10 {
            exchanges.append(ConversationExchange(
                index: i,
                learner: "This is a long sentence from the learner number \(i).",
                partner: "This is a long response from Mural number \(i)."
            ))
        }
        let history = ConversationHistory(summary: nil, exchanges: exchanges)
        let outcome = await condenser.condenseIfNeeded(
            instructions: "Instructions",
            history: history,
            pendingUtterance: "What's next?"
        )
        XCTAssertNotNil(outcome.record)
        XCTAssertLessThan(outcome.history.exchanges.count, exchanges.count)
        XCTAssertTrue(smallBudget.fits(promptTokens: outcome.record!.tokensAfter))
    }
}
