import XCTest
@testable import MuralCore

final class ThemeConversationTests: XCTestCase {
    func testEveryCatalogThemeControlsTheSessionAndFirstQuestion() throws {
        for language in LanguageRegistry.all {
            let learner = LearningEngine.project([], languageID: language.id)
            var openings = Set<String>()
            for theme in language.themes {
                let prompt = TeachingPolicy.voice(language: language, learner: learner, theme: theme,
                    interests: "An unrelated interest", meaningLanguage: "English")
                let direction = try XCTUnwrap(prompt.components(separatedBy: "Conversation direction:\n").last)
                XCTAssertTrue(direction.contains(theme.situation), "\(language.id)/\(theme.id)")
                XCTAssertFalse(prompt.contains("Suggested situation:"))
                let opening = TeachingPolicy.greeting(language: language, theme: theme)
                XCTAssertTrue(opening.contains(theme.situation), "\(language.id)/\(theme.id)")
                XCTAssertTrue(opening.contains("one short, specific question"))
                XCTAssertTrue(opening.contains("Continue ONLY in \(language.name)"))
                XCTAssertLessThanOrEqual(opening.count, 1000, "Opening must survive the transport limit: \(theme.id)")
                XCTAssertTrue(openings.insert(opening).inserted, "Two themes must not produce the same opening")
            }
        }
    }

    func testSelectingAnotherThemeReplacesThePreviousDirectionWithoutAnotherConfirmation() {
        let language = LanguageModule.english
        let coffee = language.themes.first { $0.id == "coffee" }!
        let dinner = language.themes.first { $0.id == "dinner" }!
        let update = TeachingPolicy.theme(dinner, language: language)
        XCTAssertTrue(update.contains(dinner.situation))
        XCTAssertFalse(update.contains(coffee.situation))
        XCTAssertTrue(update.contains("already confirmed"))
        XCTAssertTrue(update.contains("replaces the earlier theme"))
        XCTAssertTrue(TeachingPolicy.theme(nil, language: language).contains("Free conversation"))
    }

    func testFreeConversationAndContinuationKeepTheirDifferentOpenings() {
        let language = LanguageModule.english
        XCTAssertTrue(TeachingPolicy.greeting(language: language).contains(language.greeting))
        let resume = TeachingPolicy.greeting(language: language, theme: language.themes[0], continuing: true)
        XCTAssertTrue(resume.contains("supplied history"))
        XCTAssertTrue(resume.contains("Do not restart introductions"))
        XCTAssertFalse(resume.contains(language.greeting))
        XCTAssertFalse(resume.contains("Open inside this situation"))
    }
}
