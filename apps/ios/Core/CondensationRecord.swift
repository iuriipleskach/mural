import Foundation

/// Audit trail for token budget compliance. Every condensation is recorded with tokensBefore/tokensAfter.
public struct CondensationRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let replacedExchangeRange: ClosedRange<Int>
    public let summaryText: String
    public let tokensBefore: Int
    public let tokensAfter: Int
    public let degradedToDrop: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        replacedExchangeRange: ClosedRange<Int>,
        summaryText: String,
        tokensBefore: Int,
        tokensAfter: Int,
        degradedToDrop: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.replacedExchangeRange = replacedExchangeRange
        self.summaryText = summaryText
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.degradedToDrop = degradedToDrop
        self.createdAt = createdAt
    }
}
