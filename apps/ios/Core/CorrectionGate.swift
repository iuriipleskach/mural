import Foundation

/// Deterministic validation between the model and the screen. A correction is shown
/// only if every check passes; suppress-on-doubt is correct behavior — a wrong
/// correction shown is a release blocker. Suppressions carry a reason for audit.
public struct CorrectionGate: Sendable {
    public enum SuppressReason {
        public static let emptyCorrection = "empty-correction"
        public static let originalNotInUtterance = "original-span-not-in-utterance"
        public static let noChange = "no-change"
        public static let nonTargetCharset = "non-target-charset"
        public static let englishContent = "english-content"
        public static let foreignContent = "foreign-content"
        public static let lengthImplausible = "length-implausible"
        public static let categoryMismatch = "category-accent-only-not-register"
    }

    public let languageID: String

    public init(languageID: String = "en") {
        self.languageID = languageID
    }

    public func evaluate(_ suggestion: CorrectionSuggestion, learnerUtterance: String) -> GatedCorrection {
        if let reason = suppressionReason(for: suggestion, learnerUtterance: learnerUtterance) {
            return GatedCorrection(suggestion: suggestion, outcome: .suppressed(reason: reason))
        }
        return GatedCorrection(suggestion: suggestion, outcome: .shown)
    }

    public static func evaluate(turn: RoleplayTurn, learnerUtterance: String, languageID: String = "en") -> GatedCorrection? {
        guard let suggestion = turn.correction else { return nil }
        let gate = CorrectionGate(languageID: languageID)
        return gate.evaluate(suggestion, learnerUtterance: learnerUtterance)
    }

    // MARK: - Checks (ordered; first failure wins)

    public func suppressionReason(for suggestion: CorrectionSuggestion, learnerUtterance: String) -> String? {
        let original = TargetLanguageHeuristics.normalize(suggestion.originalSpan)
        let corrected = TargetLanguageHeuristics.normalize(suggestion.correctedSpan)
        let utterance = TargetLanguageHeuristics.normalize(learnerUtterance)

        if corrected.isEmpty {
            return SuppressReason.emptyCorrection
        }
        if original.isEmpty || !utterance.contains(original) {
            return SuppressReason.originalNotInUtterance
        }
        if corrected == original {
            return SuppressReason.noChange
        }
        if !TargetLanguageHeuristics.usesAllowedCharset(corrected, languageID: languageID) {
            return SuppressReason.nonTargetCharset
        }
        if languageID != "en", TargetLanguageHeuristics.containsEnglishFunctionWords(corrected) {
            return SuppressReason.englishContent
        }
        if languageID == "en", TargetLanguageHeuristics.containsNonEnglishFunctionWords(corrected) {
            return SuppressReason.foreignContent
        }
        if corrected.count > 4 * original.count + 24 {
            return SuppressReason.lengthImplausible
        }
        if suggestion.category == .register,
           TargetLanguageHeuristics.foldDiacritics(corrected) == TargetLanguageHeuristics.foldDiacritics(original)
        {
            return SuppressReason.categoryMismatch
        }
        return nil
    }
}

/// Deterministic, language-aware text heuristics used by the gate.
enum TargetLanguageHeuristics {
    private static let punctuation = CharacterSet(charactersIn: "¿¡!?.,;:()[]\"'«»„“”…")

    private static let allowedLetters: [String: Set<Character>] = [
        "en": Set("abcdefghijklmnopqrstuvwxyz")
    ]

    private static let englishFunctionWords: Set<String> = [
        "i", "the", "you", "your", "would", "should", "could", "like",
        "please", "want", "is", "are", "this", "that", "with", "have",
    ]

    private static let nonEnglishFunctionWords: Set<String> = [
        "por", "para", "con", "quiero", "quisiera", "gracias", "favor",
        "usted", "ustedes", "pero", "nicht", "und", "avec", "pour",
        "merci", "bitte", "danke", "bueno", "hola",
    ]

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = String(String.UnicodeScalarView(lowered.unicodeScalars.filter { !punctuation.contains($0) }))
        return stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func foldDiacritics(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
    }

    static func usesAllowedCharset(_ normalizedText: String, languageID: String) -> Bool {
        guard let allowed = allowedLetters[languageID] else {
            // Default to English letter set if unknown
            return normalizedText.allSatisfy { !$0.isLetter || Set("abcdefghijklmnopqrstuvwxyz").contains($0) }
        }
        for character in normalizedText where character.isLetter {
            if !allowed.contains(character) {
                return false
            }
        }
        return true
    }

    static func containsEnglishFunctionWords(_ normalizedText: String) -> Bool {
        let tokens = normalizedText.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains { englishFunctionWords.contains($0) }
    }

    static func containsNonEnglishFunctionWords(_ normalizedText: String) -> Bool {
        let tokens = normalizedText.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains { nonEnglishFunctionWords.contains($0) }
    }
}
