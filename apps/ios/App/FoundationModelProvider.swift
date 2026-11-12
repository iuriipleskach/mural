import Foundation
import MuralCore

#if canImport(FoundationModels)
import FoundationModels

@Generable
public struct AFMRoleplayTurn: Sendable, Equatable {
    @Guide(description: "Your natural, warm spoken English reply (1 to 3 short sentences, ending with at most one question). Do not lecture about grammar in the spoken reply.")
    public var reply: String

    @Guide(description: "Exact substring from the learner's latest utterance that contained a clear English grammar, vocabulary, or register error, or empty string if none.")
    public var correctionOriginal: String?

    @Guide(description: "Corrected English phrasing for correctionOriginal, or empty string if no correction is needed.")
    public var correctionCorrected: String?

    @Guide(description: "Category of the correction: grammar, vocab, or register, or empty string if none.")
    public var correctionCategory: String?

    public init(reply: String, correctionOriginal: String? = nil, correctionCorrected: String? = nil, correctionCategory: String? = nil) {
        self.reply = reply
        self.correctionOriginal = correctionOriginal
        self.correctionCorrected = correctionCorrected
        self.correctionCategory = correctionCategory
    }
}

@Generable
public struct AFMWordEvidence: Sendable, Equatable {
    @Guide(description: "Citation lemma in lowercase singular or base form, for example 'journey' or 'go'.")
    public var lemma: String
    @Guide(description: "Brief English sense/meaning of the word, for example 'a trip or travel'.")
    public var meaning: String
    @Guide(description: "Exact form observed in the utterance.")
    public var form: String
    @Guide(description: "Whether the word was used well or needed help: 'usedWell' or 'neededHelp'.")
    public var status: String

    public init(lemma: String, meaning: String, form: String, status: String) {
        self.lemma = lemma
        self.meaning = meaning
        self.form = form
        self.status = status
    }
}

@Generable
public struct AFMSessionAssessment: Sendable, Equatable {
    @Guide(description: "Provisional 0 to 5 challenge level recommendation.")
    public var suggestedLevel: Int
    @Guide(description: "Compact next English teaching goal (1 short sentence).")
    public var nextGoal: String
    @Guide(description: "English can-do capability descriptor, for example 'Can order coffee and describe preferences'.")
    public var capability: String
    @Guide(description: "Up to 6 practiced English words or phrases.")
    public var words: [AFMWordEvidence]

    public init(suggestedLevel: Int, nextGoal: String, capability: String, words: [AFMWordEvidence]) {
        self.suggestedLevel = suggestedLevel
        self.nextGoal = nextGoal
        self.capability = capability
        self.words = words
    }
}
#endif

public protocol RoleplayModelProviding: Sendable {
    func generateTurn(for prompt: RoleplayPrompt) async throws -> RoleplayTurn
}

public protocol SessionAssessmentProviding: Sendable {
    func assessSession(passage: Passage, context: String, languageID: String) async throws -> Assessment
}

public struct FoundationModelProvider: RoleplayModelProviding, SessionAssessmentProviding {
    private let promptBuilder = PromptBuilder()

    public init() {}

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        #endif
        return false
    }

    public func generateTurn(for prompt: RoleplayPrompt) async throws -> RoleplayTurn {
        #if canImport(FoundationModels)
        if Self.isAvailable {
            let session = LanguageModelSession(instructions: prompt.instructions)
            let renderedPrompt = promptBuilder.render(prompt, includeInstructions: false)
            let response = try await session.respond(to: renderedPrompt, generating: AFMRoleplayTurn.self)
            let raw = response.content

            var suggestion: CorrectionSuggestion? = nil
            if let orig = raw.correctionOriginal?.trimmingCharacters(in: .whitespacesAndNewlines),
               let corr = raw.correctionCorrected?.trimmingCharacters(in: .whitespacesAndNewlines),
               !orig.isEmpty, !corr.isEmpty {
                let catRaw = raw.correctionCategory?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "grammar"
                let cat = CorrectionCategory(rawValue: catRaw) ?? .grammar
                suggestion = CorrectionSuggestion(originalSpan: orig, correctedSpan: corr, category: cat)
            }

            return RoleplayTurn(reply: raw.reply, correction: suggestion)
        }
        #endif
        return try await MockRoleplayModel().generateTurn(for: prompt)
    }

    public func assessSession(passage: Passage, context: String, languageID: String = "en") async throws -> Assessment {
        #if canImport(FoundationModels)
        if Self.isAvailable {
            let instructions = TeachingPolicy.assessment(language: .english)
            let session = LanguageModelSession(instructions: instructions)
            let input = "Context:\n\(context)\nTarget Passage: \(passage.text)"
            let response = try await session.respond(to: input, generating: AFMSessionAssessment.self)
            let raw = response.content

            let proposals = raw.words.prefix(6).map { w -> WordProposal in
                let kind: EvidenceKind = (w.status.lowercased() == "neededhelp") ? .assisted : .independent
                return WordProposal(
                    lemma: w.lemma.lowercased(),
                    meaning: w.meaning,
                    form: w.form,
                    kind: kind,
                    confidence: 0.95,
                    sourceIDs: passage.fragments.map(\.id),
                    quote: passage.text,
                    language: languageID
                )
            }

            return Assessment(
                passageID: passage.id,
                revisionKey: passage.revisionKey,
                outcome: .success,
                suggestedLevel: min(max(raw.suggestedLevel, 0), 5),
                nextGoal: raw.nextGoal,
                capability: raw.capability,
                words: Array(proposals),
                context: context
            )
        }
        #endif
        return try await MockSessionAssessmentModel().assessSession(passage: passage, context: context, languageID: languageID)
    }
}

public struct MockRoleplayModel: RoleplayModelProviding {
    public init() {}

    public func generateTurn(for prompt: RoleplayPrompt) async throws -> RoleplayTurn {
        let learner = prompt.learnerUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if learner.isEmpty {
            return RoleplayTurn(
                reply: "Hello! It's great to talk with you. What are you up to today?",
                correction: nil
            )
        }

        // Detect simple common learner errors for mock testing
        var suggestion: CorrectionSuggestion? = nil
        let lower = learner.lowercased()
        if lower.contains("i goed") {
            suggestion = CorrectionSuggestion(originalSpan: "I goed", correctedSpan: "I went", category: .grammar)
        } else if lower.contains("i have 20 years") {
            suggestion = CorrectionSuggestion(originalSpan: "I have 20 years", correctedSpan: "I am 20 years old", category: .vocab)
        }

        let reply: String
        if lower.contains("coffee") {
            reply = "Coffee is wonderful! Do you prefer espresso or a flat white?"
        } else if lower.contains("weather") || lower.contains("rain") || lower.contains("sun") {
            reply = "The weather can really change your day. What kind of day is it where you are?"
        } else if lower.contains("book") || lower.contains("read") {
            reply = "Reading is a great way to explore ideas. What's a book that stayed with you?"
        } else {
            reply = "That's interesting! Could you tell me a little more about that?"
        }

        return RoleplayTurn(reply: reply, correction: suggestion)
    }
}

public struct MockSessionAssessmentModel: SessionAssessmentProviding {
    public init() {}

    public func assessSession(passage: Passage, context: String, languageID: String = "en") async throws -> Assessment {
        let text = passage.text
        var words: [WordProposal] = []
        let tokens = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if let firstWord = tokens.first(where: { $0.count >= 4 }) {
            words.append(WordProposal(
                lemma: firstWord.lowercased(),
                meaning: "practiced word",
                form: firstWord,
                kind: .independent,
                confidence: 0.95,
                sourceIDs: passage.fragments.map(\.id),
                quote: text,
                language: languageID
            ))
        }

        return Assessment(
            passageID: passage.id,
            revisionKey: passage.revisionKey,
            outcome: .success,
            suggestedLevel: 2,
            nextGoal: "Keep practising everyday English conversation.",
            capability: "Communicates everyday ideas in English",
            words: words,
            context: context
        )
    }
}

public enum ModelProviderFactory {
    public static func makeRoleplayModel() -> any RoleplayModelProviding {
        FoundationModelProvider()
    }

    public static func makeAssessmentModel() -> any SessionAssessmentProviding {
        FoundationModelProvider()
    }
}
