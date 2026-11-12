import Foundation

public struct CaptionSegment: Equatable, Sendable {
    public let text: String
    public let lookup: String?

    public init(text: String, lookup: String? = nil) {
        self.text = text
        self.lookup = lookup
    }
}

public enum CaptionWords {
    /// Segments English text into words and whitespace/punctuation for following captions.
    public static func segments(_ text: String, languageID: String = "en") -> [CaptionSegment] {
        var result: [CaptionSegment] = []
        var run = ""
        for character in text {
            if let last = run.last, last.isWhitespace != character.isWhitespace {
                result.append(segment(run))
                run = ""
            }
            run.append(character)
        }
        if !run.isEmpty {
            result.append(segment(run))
        }
        return result
    }

    private static func segment(_ text: String) -> CaptionSegment {
        let word = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return CaptionSegment(text: text, lookup: word.contains(where: \.isLetter) ? word : nil)
    }
}
