import Testing
@testable import SpeakCleanCore

@Suite("TextCleaner")
struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test func removesBasicFillers() {
        #expect(cleaner.clean("I went to the um store") == "I went to the store")
        #expect(cleaner.clean("It was uh really good") == "It was really good")
        #expect(cleaner.clean("She said hmm okay") == "She said okay")
    }

    @Test func removesDiscourseFillers() {
        #expect(cleaner.clean("I actually think it works") == "I think it works")
        #expect(cleaner.clean("It basically does the same thing") == "It does the same thing")
        #expect(cleaner.clean("He literally ran a mile") == "He ran a mile")
        #expect(cleaner.clean("You know that sounds right") == "That sounds right")
        #expect(cleaner.clean("I mean it could work") == "It could work")
    }

    @Test func removesClauseStartFillers() {
        #expect(cleaner.clean("So, I think we should go") == "I think we should go")
        #expect(cleaner.clean("Well, that was interesting") == "That was interesting")
        #expect(cleaner.clean("Like, why would you do that") == "Why would you do that")
    }

    @Test func handlesSelfCorrectionWithDash() {
        #expect(cleaner.clean("The carg-- car is red") == "The car is red")
        #expect(cleaner.clean("I want the blu—blue one") == "I want the blue one")
    }

    @Test func handlesSelfCorrectionWithSorryOrNo() {
        #expect(cleaner.clean("Meet me Tuesday, no, Wednesday") == "Meet me Wednesday")
        #expect(cleaner.clean("It costs ten, sorry, twelve dollars") == "It costs twelve dollars")
    }

    @Test func handlesMultipleFillers() {
        #expect(
            cleaner.clean("Um, so, I actually think, you know, it works")
            == "I think it works")
    }

    @Test func preservesCleanText() {
        let clean = "The quick brown fox jumps over the lazy dog."
        #expect(cleaner.clean(clean) == clean)
    }

    @Test func capitalizesResult() {
        #expect(cleaner.clean("um hello") == "Hello")
    }
}
