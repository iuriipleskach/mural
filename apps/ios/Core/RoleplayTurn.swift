import Foundation

/// Structured turn representation for conversation engine output.
public struct RoleplayTurn: Sendable, Codable, Equatable {
    public let reply: String
    public let correction: CorrectionSuggestion?
    public let naturalness: Naturalness

    public init(reply: String, correction: CorrectionSuggestion? = nil, naturalness: Naturalness = Naturalness(score: 1.0, note: "")) {
        self.reply = reply
        self.correction = correction
        self.naturalness = naturalness
    }
}

public struct Naturalness: Sendable, Codable, Equatable {
    public let score: Double
    public let note: String

    public init(score: Double, note: String = "") {
        self.score = score.isFinite ? min(max(score, 0), 1) : 0
        self.note = note
    }
}

public enum CorrectionCategory: String, Sendable, Codable, Equatable, CaseIterable {
    case grammar
    case vocab
    case register
}

public struct CorrectionSuggestion: Sendable, Codable, Equatable {
    public let originalSpan: String
    public let correctedSpan: String
    public let category: CorrectionCategory

    public init(originalSpan: String, correctedSpan: String, category: CorrectionCategory) {
        self.originalSpan = originalSpan
        self.correctedSpan = correctedSpan
        self.category = category
    }
}

public enum GateOutcome: Sendable, Codable, Equatable {
    case shown
    case suppressed(reason: String)
}

public struct GatedCorrection: Sendable, Codable, Equatable {
    public let suggestion: CorrectionSuggestion
    public let outcome: GateOutcome

    public init(suggestion: CorrectionSuggestion, outcome: GateOutcome) {
        self.suggestion = suggestion
        self.outcome = outcome
    }

    public var isShown: Bool {
        outcome == .shown
    }

    public var corrected: String {
        suggestion.correctedSpan
    }

    public var original: String {
        suggestion.originalSpan
    }
}
