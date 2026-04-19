import Testing
@testable import SpeakCleanCore

@Suite("TextCleaner.instructions")
struct TextCleanerInstructionsTests {

    @Test func emptyDictionaryHasNoPreserveBlock() {
        let s = TextCleaner.instructions(dictionary: [])
        #expect(s.contains("text-transformation tool"))
        #expect(!s.contains("Preserve these spellings"))
    }

    @Test func populatedDictionaryIncludesEachWord() {
        let s = TextCleaner.instructions(dictionary: ["Winawer", "Jiaqi"])
        #expect(s.contains("Preserve these spellings exactly:"))
        #expect(s.contains("- Winawer"))
        #expect(s.contains("- Jiaqi"))
    }

    @Test func instructionsListFillerWords() {
        let s = TextCleaner.instructions(dictionary: [])
        #expect(s.contains("um"))
        #expect(s.contains("you know"))
    }
}
