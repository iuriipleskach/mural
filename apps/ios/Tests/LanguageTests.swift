import XCTest
@testable import MuralCore

final class LanguageTests: XCTestCase {
    func testExistingArchivesRequireConsentAndAcceptedVersionRoundTrips() throws {
        var archive = Archive()
        archive.preferences.hasOnboarded = true
        let legacy = try Archive.decode(archive.encoded())
        XCTAssertTrue(legacy.preferences.hasOnboarded)
        XCTAssertNil(legacy.preferences.aiConsentVersion)
        archive.preferences.aiConsentVersion = 1
        XCTAssertEqual(try Archive.decode(archive.encoded()).preferences.aiConsentVersion, 1)
    }

    private func evidence(languageID: String = "en", day: Int = 0, supported: Bool = false) -> SessionRecord {
        let date = Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86400)
        var session = SessionRecord(languageID: languageID, themeID: "coffee")
        session.startedAt = date
        session.append(Fragment(speaker: .user, text: "coffee", startMS: 1000, endMS: 2000, receivedAt: date, meaningVisible: supported))
        let passage = session.passages[0]
        session.assessments = [Assessment(passageID: passage.id, revisionKey: passage.revisionKey, outcome: .success,
            suggestedLevel: 3, nextGoal: "A goal for \(languageID)", capability: "Describes a drink",
            words: [WordProposal(lemma: "coffee", meaning: "coffee", form: "coffee", kind: .independent, confidence: 0.95,
                sourceIDs: passage.fragments.map(\.id), quote: "coffee", language: languageID)], createdAt: date)]
        return session
    }

    func testProgressAndVocabularyStayWithinEnglish() {
        let sessions = [evidence(day: 0), evidence(day: 2)]
        let english = LearningEngine.project(sessions, languageID: "en", now: sessions[1].startedAt)
        XCTAssertEqual(english.challenge, 1)
        XCTAssertEqual(english.words.first?.bars, 2)
        XCTAssertEqual(english.words.first?.lemma, "coffee")
    }

    func testHidingWordExcludesFromLearnerState() {
        let sessions = [evidence(day: 0)]
        let wordKey = sessions[0].assessments[0].words[0].key
        XCTAssertTrue(LearningEngine.project(sessions, languageID: "en", hiddenWords: [wordKey]).words.isEmpty)
        XCTAssertEqual(LearningEngine.project(sessions, languageID: "en", hiddenWords: []).words.count, 1)
    }

    func testEvidenceInAnotherLanguageIsNeverCredited() {
        for kind in [EvidenceKind.independent, .assisted, .understanding, .exposure, .lapse] {
            var session = evidence()
            session.assessments[0].words[0].language = "fr"
            session.assessments[0].words[0].kind = kind
            XCTAssertTrue(LearningEngine.validate(session.assessments[0], session: session)!.words.isEmpty)
        }
    }

    func testEnglishWithMeaningSupportIsAssisted() {
        let session = evidence(supported: true)
        XCTAssertEqual(LearningEngine.validate(session.assessments[0], session: session)?.words.first?.kind, .assisted)
        XCTAssertEqual(LearningEngine.project([session], languageID: "en").words.first?.independentCount, 0)
    }

    func testEnglishArchiveRoundTrip() throws {
        var archive = Archive()
        archive.preferences.learningLanguageID = "en"
        archive.preferences.meaningLanguage = "Ukrainian"
        archive.sessions = [evidence(day: 0), evidence(day: 2)]
        let restored = try Archive.decode(archive.encoded())
        XCTAssertEqual(restored.preferences.learningLanguageID, "en")
        XCTAssertEqual(restored.preferences.meaningLanguage, "Ukrainian")
        XCTAssertEqual(restored.sessions.count, 2)
        XCTAssertEqual(LearningEngine.project(restored.sessions, languageID: "en").words.count, 1)
    }

    func testArchiveRejectsUnsupportedLanguage() throws {
        var archive = Archive()
        archive.sessions = [SessionRecord(languageID: "not-installed")]
        XCTAssertThrowsError(try Archive.decode(archive.encoded()))
    }

    func testEnglishModuleHasCompleteCurriculumAndStableThemeIDs() {
        XCTAssertEqual(LanguageRegistry.all.count, 1)
        guard let language = LanguageRegistry.module(for: "en") else {
            XCTFail("English module missing")
            return
        }
        XCTAssertEqual(language.id, "en")
        XCTAssertEqual(language.name, "English")
        XCTAssertEqual(language.teachingFocus.count, 6)
        XCTAssertTrue(language.teachingFocus.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(language.themes.map(\.id)), Set(ConversationTheme.shared.map(\.id)))
        XCTAssertEqual(language.themes.count, 23)
        XCTAssertFalse(language.speechGuidance.isEmpty)
        XCTAssertFalse(language.lemmaGuidance.isEmpty)
        XCTAssertFalse(language.lookupUnavailableReply.isEmpty)
    }

    func testEnglishPromptsAndUkrainianMeaning() {
        let language = LanguageModule.english
        let learner = LearningEngine.project([], languageID: language.id)
        let voice = TeachingPolicy.voice(language: language, learner: learner, theme: nil, interests: "", meaningLanguage: "Ukrainian")
        let typed = TeachingPolicy.typedReply(language: language)
        let redirect = TeachingPolicy.redirect(language: language)
        let lookup = TeachingPolicy.lookup(language: language, meaningLanguage: "Ukrainian")
        let translation = TeachingPolicy.translation(language: language, meaningLanguage: "Ukrainian")

        XCTAssertTrue(voice.contains("Speak ONLY English."))
        XCTAssertTrue(voice.contains("Meaning subtitles in Ukrainian"))
        XCTAssertTrue(typed.contains("Reply only in English"))
        XCTAssertTrue(redirect.contains("continue ONLY in English"))
        XCTAssertTrue(lookup.contains("Ukrainian"))
        XCTAssertTrue(translation.contains("Ukrainian"))
        XCTAssertEqual(MeaningLanguages.all, ["Ukrainian"])
        XCTAssertEqual(MeaningLanguages.greeting(in: "Ukrainian"), "Привіт!")
    }

    func testLanguageRedirectUsesSelectedTarget() {
        let language = LanguageModule.english
        XCTAssertFalse(TeachingPolicy.shouldRedirectSpeech(language: language, detectedLanguageID: "en", confidence: 0.99))
        XCTAssertTrue(TeachingPolicy.shouldRedirectSpeech(language: language, detectedLanguageID: "fr", confidence: 0.99))
        for confidence in [0.0, 0.88, .nan, .infinity, 1.1] {
            XCTAssertFalse(TeachingPolicy.shouldRedirectSpeech(language: language, detectedLanguageID: "fr", confidence: confidence))
        }
        XCTAssertFalse(TeachingPolicy.shouldRedirectSpeech(language: language, detectedLanguageID: "und", confidence: 0.99))
        XCTAssertFalse(TeachingPolicy.shouldRedirectSpeech(language: language, detectedLanguageID: "", confidence: 0.99))
    }
}
