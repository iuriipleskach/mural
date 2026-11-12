import XCTest
@testable import MuralCore

final class CorrectionGateTests: XCTestCase {
    let gate = CorrectionGate(languageID: "en")

    func testValidCorrectionPasses() {
        let suggestion = CorrectionSuggestion(originalSpan: "I goed", correctedSpan: "I went", category: .grammar)
        let result = gate.evaluate(suggestion, learnerUtterance: "Yesterday I goed to the store.")
        XCTAssertEqual(result.outcome, .shown)
        XCTAssertTrue(result.isShown)
        XCTAssertEqual(result.corrected, "I went")
    }

    func testEmptyCorrectionSuppressed() {
        let suggestion = CorrectionSuggestion(originalSpan: "coffee", correctedSpan: "", category: .vocab)
        let result = gate.evaluate(suggestion, learnerUtterance: "I like coffee")
        XCTAssertEqual(result.outcome, .suppressed(reason: CorrectionGate.SuppressReason.emptyCorrection))
    }

    func testOriginalNotInUtteranceSuppressed() {
        let suggestion = CorrectionSuggestion(originalSpan: "tea", correctedSpan: "coffee", category: .vocab)
        let result = gate.evaluate(suggestion, learnerUtterance: "I like water")
        XCTAssertEqual(result.outcome, .suppressed(reason: CorrectionGate.SuppressReason.originalNotInUtterance))
    }

    func testNoChangeSuppressed() {
        let suggestion = CorrectionSuggestion(originalSpan: "coffee", correctedSpan: "coffee", category: .vocab)
        let result = gate.evaluate(suggestion, learnerUtterance: "I like coffee")
        XCTAssertEqual(result.outcome, .suppressed(reason: CorrectionGate.SuppressReason.noChange))
    }

    func testNonTargetCharsetSuppressed() {
        let suggestion = CorrectionSuggestion(originalSpan: "coffee", correctedSpan: "café", category: .vocab)
        let result = gate.evaluate(suggestion, learnerUtterance: "I like coffee")
        XCTAssertEqual(result.outcome, .suppressed(reason: CorrectionGate.SuppressReason.nonTargetCharset))
    }

    func testForeignContentInEnglishSuppressed() {
        let suggestion = CorrectionSuggestion(originalSpan: "please", correctedSpan: "por favor", category: .vocab)
        let result = gate.evaluate(suggestion, learnerUtterance: "one tea please")
        XCTAssertEqual(result.outcome, .suppressed(reason: CorrectionGate.SuppressReason.foreignContent))
    }

    func testLengthImplausibleSuppressed() {
        let suggestion = CorrectionSuggestion(
            originalSpan: "hi",
            correctedSpan: "this is an extraordinarily and unreasonably verbose correction that expands far beyond plausible length",
            category: .grammar
        )
        let result = gate.evaluate(suggestion, learnerUtterance: "hi there")
        XCTAssertEqual(result.outcome, .suppressed(reason: CorrectionGate.SuppressReason.lengthImplausible))
    }

    func testCategoryMismatchSuppressed() {
        let suggestion = CorrectionSuggestion(originalSpan: "resume", correctedSpan: "resume", category: .register)
        XCTAssertEqual(gate.suppressionReason(for: suggestion, learnerUtterance: "my resume"), CorrectionGate.SuppressReason.noChange)
        let s2 = CorrectionSuggestion(originalSpan: "café", correctedSpan: "cafe", category: .register)
        XCTAssertNotNil(gate.suppressionReason(for: s2, learnerUtterance: "my café"))
    }

    func testSessionRecordCorrectionStorageAndPassageAttachment() throws {
        var session = SessionRecord(languageID: "en", title: "Practice")
        let frag = Fragment(id: "frag-1", speaker: .user, text: "I goed there yesterday.", startMS: 0, endMS: 1500)
        session.append(frag)

        XCTAssertEqual(session.passages.count, 1)
        XCTAssertNil(session.passages.first?.correction)

        let suggestion = CorrectionSuggestion(originalSpan: "I goed", correctedSpan: "I went", category: .grammar)
        let gated = gate.evaluate(suggestion, learnerUtterance: "I goed there yesterday.")
        XCTAssertTrue(gated.isShown)

        // Store correction keyed by passage ID (which matches the first fragment ID)
        let passageID = session.passages[0].id
        session.corrections[passageID] = gated

        // Verify passages attaches correction
        XCTAssertEqual(session.passages.first?.correction, gated)
        XCTAssertEqual(session.passages.first?.correction?.corrected, "I went")

        // Verify JSON roundtrip preserves corrections
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded.corrections[passageID], gated)
        XCTAssertEqual(decoded.passages.first?.correction, gated)
    }

    func testTranscriptPassagesPreservesCorrectionsByKey() {
        let frag1 = Fragment(id: "f-100", speaker: .user, text: "Hello", startMS: 0, endMS: 500)
        let suggestion = CorrectionSuggestion(originalSpan: "Hello", correctedSpan: "Hi", category: .register)
        let gated = GatedCorrection(suggestion: suggestion, outcome: .shown)

        let passages = Transcript.passages([frag1], corrections: ["f-100": gated])
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages.first?.correction, gated)
    }
}
