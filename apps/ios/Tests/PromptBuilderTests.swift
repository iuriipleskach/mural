import XCTest
@testable import MuralCore

final class PromptBuilderTests: XCTestCase {
    let builder = PromptBuilder()

    func testBoundedInstructionsSize() {
        let instructions = builder.instructions(
            theme: ConversationTheme.shared.first,
            interests: "Travel, cooking, photography",
            ephemeralDirective: "The learner asked for help."
        )
        let estimator = TokenEstimator()
        let tokenCount = estimator.tokens(in: instructions)
        XCTAssertLessThanOrEqual(tokenCount, 150)
        XCTAssertTrue(instructions.contains("Mural"))
        XCTAssertTrue(instructions.contains("Directive for this turn:"))
    }

    func testEphemeralDirectiveReplacement() {
        let d1 = builder.instructions(ephemeralDirective: "Directive A")
        let d2 = builder.instructions(ephemeralDirective: "Directive B")
        XCTAssertTrue(d1.contains("Directive A"))
        XCTAssertFalse(d1.contains("Directive B"))
        XCTAssertTrue(d2.contains("Directive B"))
        XCTAssertFalse(d2.contains("Directive A"))
    }

    func testRenderOutputStructure() {
        let prompt = RoleplayPrompt(
            instructions: "You are Mural.",
            history: ConversationHistory(
                summary: "Discussed coffee",
                exchanges: [ConversationExchange(index: 0, learner: "Hi", partner: "Hello!")]
            ),
            learnerUtterance: "I'd like an espresso."
        )
        let rendered = builder.render(prompt)
        XCTAssertTrue(rendered.contains("You are Mural."))
        XCTAssertTrue(rendered.contains("Earlier in this conversation (condensed): Discussed coffee"))
        XCTAssertTrue(rendered.contains("Learner: Hi"))
        XCTAssertTrue(rendered.contains("Mural: Hello!"))
        XCTAssertTrue(rendered.contains("Learner: I'd like an espresso."))
        XCTAssertTrue(rendered.contains("Respond with the next structured turn."))
    }

    func testRenderDeduplicatesInstructionsWhenRequested() {
        let prompt = RoleplayPrompt(
            instructions: "You are Mural English Assistant.",
            history: ConversationHistory(
                summary: nil,
                exchanges: [ConversationExchange(index: 0, learner: "Hi", partner: "Hello!")]
            ),
            learnerUtterance: "What is your name?"
        )
        let renderedWithout = builder.render(prompt, includeInstructions: false)
        XCTAssertFalse(renderedWithout.contains("You are Mural English Assistant."))
        XCTAssertTrue(renderedWithout.contains("Learner: Hi"))
        XCTAssertTrue(renderedWithout.contains("Mural: Hello!"))
        XCTAssertTrue(renderedWithout.contains("Learner: What is your name?"))

        let renderedWith = builder.render(prompt, includeInstructions: true)
        XCTAssertTrue(renderedWith.contains("You are Mural English Assistant."))
    }
}
