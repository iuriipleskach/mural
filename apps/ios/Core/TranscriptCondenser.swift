import Foundation

public protocol TranscriptSummarizing: Sendable {
    func summarize(
        existingSummary: String?,
        exchanges: [ConversationExchange]
    ) async throws -> String
}

public struct DeterministicSummarizer: TranscriptSummarizing {
    public let maxSummaryCharacters: Int

    public init(maxSummaryCharacters: Int = 600) {
        self.maxSummaryCharacters = max(80, maxSummaryCharacters)
    }

    public func summarize(
        existingSummary: String?,
        exchanges: [ConversationExchange]
    ) async throws -> String {
        var parts: [String] = []
        if let existingSummary, !existingSummary.isEmpty {
            parts.append(existingSummary)
        }
        for exchange in exchanges {
            parts.append("L: \(clip(exchange.learner)) / M: \(clip(exchange.partner))")
        }
        let joined = parts.joined(separator: " · ")
        guard joined.count > maxSummaryCharacters else { return joined }
        return "…" + String(joined.suffix(maxSummaryCharacters - 1))
    }

    private func clip(_ text: String, to limit: Int = 80) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

public struct CondensationOutcome: Sendable {
    public let history: ConversationHistory
    public let record: CondensationRecord?

    public init(history: ConversationHistory, record: CondensationRecord? = nil) {
        self.history = history
        self.record = record
    }
}

/// Enforces the token budget before every model invocation.
/// Condenses or degrades history if prompt exceeds budget.
public struct TranscriptCondenser: Sendable {
    public let budget: TokenBudget
    public let estimator: TokenEstimator
    public let keepRecentExchanges: Int
    private let summarizer: any TranscriptSummarizing
    private let builder = PromptBuilder()

    public init(
        budget: TokenBudget = .afmDefault,
        estimator: TokenEstimator = TokenEstimator(),
        summarizer: any TranscriptSummarizing = DeterministicSummarizer(),
        keepRecentExchanges: Int = 3
    ) {
        self.budget = budget
        self.estimator = estimator
        self.summarizer = summarizer
        self.keepRecentExchanges = max(1, keepRecentExchanges)
    }

    public func promptTokens(
        instructions: String,
        history: ConversationHistory,
        pendingUtterance: String
    ) -> Int {
        let prompt = RoleplayPrompt(
            instructions: instructions,
            history: history,
            learnerUtterance: pendingUtterance
        )
        return estimator.tokens(in: builder.render(prompt))
    }

    public func condenseIfNeeded(
        instructions: String,
        history: ConversationHistory,
        pendingUtterance: String,
        sessionID: UUID = UUID(),
        now: Date = .now
    ) async -> CondensationOutcome {
        let tokensBefore = promptTokens(
            instructions: instructions,
            history: history,
            pendingUtterance: pendingUtterance
        )
        guard !budget.fits(promptTokens: tokensBefore) else {
            return CondensationOutcome(history: history, record: nil)
        }

        let reduction = await reduce(
            instructions: instructions,
            history: history,
            pendingUtterance: pendingUtterance
        )
        let condensed = ConversationHistory(summary: reduction.summary, exchanges: reduction.exchanges)
        guard condensed != history else {
            return CondensationOutcome(history: history, record: nil)
        }

        let tokensAfter = promptTokens(
            instructions: instructions,
            history: condensed,
            pendingUtterance: pendingUtterance
        )

        let minIndex = reduction.foldedIndices.min() ?? 0
        let maxIndex = reduction.foldedIndices.max() ?? minIndex
        let record = CondensationRecord(
            sessionID: sessionID,
            replacedExchangeRange: minIndex...maxIndex,
            summaryText: reduction.summary ?? "",
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            degradedToDrop: reduction.degraded,
            createdAt: now
        )
        return CondensationOutcome(history: condensed, record: record)
    }

    // MARK: - Private

    private struct Reduction {
        let summary: String?
        let exchanges: [ConversationExchange]
        let foldedIndices: [Int]
        let degraded: Bool
    }

    private func reduce(
        instructions: String,
        history: ConversationHistory,
        pendingUtterance: String
    ) async -> Reduction {
        var summary = history.summary
        var exchanges = history.exchanges
        var foldedIndices: [Int] = []
        var degraded = false

        // Step 1: fold older exchanges into summary
        if exchanges.count > keepRecentExchanges {
            let folded = Array(exchanges.dropLast(keepRecentExchanges))
            do {
                summary = try await summarizer.summarize(
                    existingSummary: summary,
                    exchanges: folded
                )
                foldedIndices.append(contentsOf: folded.map(\.index))
                exchanges = Array(exchanges.suffix(keepRecentExchanges))
            } catch {
                degraded = true
            }
        }

        // Step 2: drop oldest remaining exchanges until it fits
        while !budget.fits(promptTokens: promptTokens(
            instructions: instructions,
            history: ConversationHistory(summary: summary, exchanges: exchanges),
            pendingUtterance: pendingUtterance
        )) && !exchanges.isEmpty {
            let dropped = exchanges.removeFirst()
            foldedIndices.append(dropped.index)
            degraded = true
        }

        // Step 3: shed summary if still over budget
        if !budget.fits(promptTokens: promptTokens(
            instructions: instructions,
            history: ConversationHistory(summary: summary, exchanges: exchanges),
            pendingUtterance: pendingUtterance
        )) {
            summary = nil
            degraded = true
        }

        return Reduction(
            summary: summary,
            exchanges: exchanges,
            foldedIndices: foldedIndices,
            degraded: degraded
        )
    }
}
