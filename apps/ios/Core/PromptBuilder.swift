import Foundation

/// One exchange already completed in this session, as fed back to the model.
public struct ConversationExchange: Sendable, Codable, Equatable {
    public let index: Int
    public let learner: String
    public let partner: String

    public init(index: Int, learner: String, partner: String) {
        self.index = index
        self.learner = learner
        self.partner = partner
    }
}

/// The condensed conversation history that accompanies model calls.
public struct ConversationHistory: Sendable, Equatable {
    public let summary: String?
    public let exchanges: [ConversationExchange]

    public static let empty = ConversationHistory(summary: nil, exchanges: [])

    public init(summary: String?, exchanges: [ConversationExchange]) {
        self.summary = summary
        self.exchanges = exchanges
    }

    public func appending(_ exchange: ConversationExchange) -> ConversationHistory {
        ConversationHistory(summary: summary, exchanges: exchanges + [exchange])
    }
}

/// Input prompt passed to the conversation model.
public struct RoleplayPrompt: Sendable, Equatable {
    public let instructions: String
    public let history: ConversationHistory
    public let learnerUtterance: String

    public init(instructions: String, history: ConversationHistory, learnerUtterance: String) {
        self.instructions = instructions
        self.history = history
        self.learnerUtterance = learnerUtterance
    }
}

/// Builds bounded (~150 token) prompts for on-device English conversation.
public struct PromptBuilder: Sendable, Equatable {
    public init() {}

    /// Construct bounded ~150-token English system instructions with the Ephemeral Turn Directive slot.
    public func instructions(
        theme: ConversationTheme? = nil,
        learner: LearnerState? = nil,
        interests: String = "",
        ephemeralDirective: String? = nil
    ) -> String {
        var lines: [String] = []

        // 1. Role & Register
        lines.append("You are Mural, a warm English conversation partner helping an adult practise English. Speak only natural, friendly English (1 to 3 short sentences, ending with at most one question). Do not lecture about grammar in your spoken reply.")

        // 2. Theme Situation
        if let theme {
            lines.append("Situation: \(theme.situation)")
        } else {
            lines.append("Situation: Just talk. Follow the learner's natural conversation.")
        }

        // 3. Learner Context (due lemmas + interests)
        if !interests.isEmpty {
            lines.append("Learner interests: \(String(interests.prefix(200)))")
        }
        if let learner, learner.observationCount > 0 {
            let dueWords = learner.words.filter { $0.dueAt < .now }.prefix(5).map(\.lemma)
            if !dueWords.isEmpty {
                lines.append("Words to revisit when natural: \(dueWords.joined(separator: ", "))")
            }
        }

        // 4. Ephemeral Turn Directive (single replaceable slot, never an unbounded log)
        if let ephemeralDirective, !ephemeralDirective.isEmpty {
            lines.append("Directive for this turn: \(ephemeralDirective)")
        }

        return lines.joined(separator: "\n")
    }

    /// Renders instructions + condensed summary + recent exchanges + pending utterance.
    /// When `includeInstructions` is false, omits system instructions (e.g. for `LanguageModelSession` which receives instructions separately).
    public func render(_ prompt: RoleplayPrompt, includeInstructions: Bool = true) -> String {
        var sections: [String] = []
        if includeInstructions && !prompt.instructions.isEmpty {
            sections.append(prompt.instructions)
        }
        if let summary = prompt.history.summary, !summary.isEmpty {
            sections.append("Earlier in this conversation (condensed): \(summary)")
        }
        for exchange in prompt.history.exchanges {
            sections.append("Learner: \(exchange.learner)")
            sections.append("Mural: \(exchange.partner)")
        }
        if !prompt.learnerUtterance.isEmpty {
            sections.append("Learner: \(prompt.learnerUtterance)")
        }
        sections.append("Respond with the next structured turn.")
        return sections.joined(separator: "\n")
    }
}
