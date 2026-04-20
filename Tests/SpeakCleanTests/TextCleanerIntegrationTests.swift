import Foundation
import Testing
@testable import SpeakCleanCore

/// Integration tests for `TextCleaner.clean` that actually invoke the
/// local Ollama server and the configured Gemma model. Tests silently
/// skip when Ollama isn't reachable, so the suite stays green on CI
/// and headless machines.
///
/// Assertions are fuzzy (contains / does-not-contain) because LLM
/// output is non-deterministic. The goal is to detect regressions
/// in prompt behavior, not to pin exact wording.
@Suite("TextCleaner.clean (LLM integration)")
struct TextCleanerIntegrationTests {

    /// Returns true (and skips the test body) when Ollama isn't
    /// reachable or the configured model isn't pulled. Checks once per
    /// test; hot path because Ollama is usually local and fast.
    private func skipIfUnavailable() async -> Bool {
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        req.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: req)) == nil
    }

    /// True if the trimmed line begins with any list-item marker:
    /// "- ", "* ", "N. ", or "N) " (N = one or more digits).
    /// Tests accept any marker style — the LLM may pick either.
    private func isListLine(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") { return true }
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = t.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// Count of list-style lines in `text`.
    private func listLineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).filter(isListLine).count
    }

    @Test func removesFillerUm() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean("um hello world", dictionary: [])
        #expect(!result.lowercased().contains("um "))
        #expect(result.lowercased().contains("hello world"))
    }

    @Test func actuallyMarksSelfCorrection() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "I want tea actually I want coffee",
            dictionary: []
        )
        #expect(result.lowercased().contains("coffee"))
        #expect(!result.lowercased().contains("tea"))
    }

    @Test func preservesPlainSentence() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "The quick brown fox jumps over the lazy dog.",
            dictionary: []
        )
        #expect(result.contains("quick brown fox"))
        #expect(result.contains("lazy dog"))
    }

    @Test func doesNotAnswerQuestion() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean("What time is it", dictionary: [])
        let lower = result.lowercased()
        #expect(lower.contains("what time is it"))
        #expect(!lower.hasPrefix("i "))
        #expect(!lower.contains("o'clock"))
    }

    @Test func doesNotAnswerGreeting() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "How are you doing actually how are they doing",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("how are they doing"))
        #expect(!lower.contains("i'm doing"))
        #expect(!lower.contains("thank you for asking"))
    }

    @Test func removesMultipleFillers() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "um hey uh can you you know help me out",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("help me"))
        #expect(!lower.contains(" um "))
        #expect(!lower.contains(" uh "))
        #expect(!lower.hasPrefix("um "))
        #expect(!lower.hasPrefix("uh "))
    }

    @Test func preservesDictionaryWord() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "say hi to Jiaqi please",
            dictionary: ["Jiaqi"]
        )
        #expect(result.contains("Jiaqi"))
    }

    @Test func emptyInputReturnsEmpty() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean("   ", dictionary: [])
        #expect(result == "")
    }

    @Test func stepMarkersProduceList() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "I want to build a recipe step 1 mix the flour step 2 add eggs step 3 bake",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("recipe"))
        #expect(result.contains(":"))
        #expect(listLineCount(result) >= 3)
        #expect(!lower.contains("step 1"))
        #expect(!lower.contains("step 2"))
        #expect(lower.contains("flour"))
        #expect(lower.contains("eggs"))
        #expect(lower.contains("bake"))
    }

    @Test func revisingAStepViaActuallyReplacesIt() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "step 1 mix the flour step 2 add eggs actually step 1 is preheat the oven",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("preheat"))
        #expect(lower.contains("oven"))
        #expect(!lower.contains("mix"))
        #expect(lower.contains("eggs"))
        #expect(listLineCount(result) == 2)
        #expect(!lower.contains("step 1"))
        #expect(!lower.contains("step 2"))
        #expect(!lower.contains("actually"))
    }

    @Test func numberMarkersProduceList() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "here are my goals number 1 save money number 2 learn guitar number 3 travel more",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("goals"))
        #expect(result.contains(":"))
        #expect(listLineCount(result) >= 3)
        #expect(!lower.contains("number 1"))
        #expect(!lower.contains("number 2"))
        #expect(lower.contains("save money"))
        #expect(lower.contains("learn guitar"))
        #expect(lower.contains("travel more"))
    }

    @Test func firstSecondWithoutStepStaysProse() async throws {
        if await skipIfUnavailable() { return }
        // Note: this input appears verbatim as a passthrough example in
        // `TextCleaner.instructions(...)`. That's a deliberate exception to
        // the "prompt examples ≠ test inputs" rule because Gemma 4 E2B only
        // reliably obeys the "don't list-format first/second" rule when
        // this exact shape is in the few-shots — varying either side
        // makes it regress to auto-listifying.
        let result = try await TextCleaner.clean(
            "here are my thoughts first I agree with the plan second I have concerns",
            dictionary: []
        )
        #expect(listLineCount(result) == 0)
        #expect(result.lowercased().contains("first i agree"))
        #expect(result.lowercased().contains("second i have"))
    }

    @Test func explicitBulletRequestProducesList() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "as bullet points buy groceries go to the bank pick up the kids",
            dictionary: []
        )
        #expect(listLineCount(result) >= 3)
        let lower = result.lowercased()
        #expect(lower.contains("groceries"))
        #expect(lower.contains("bank"))
        #expect(lower.contains("kids"))
        #expect(!lower.contains("as bullet points"))
    }

    @Test func proseWithoutListTriggerStaysProse() async throws {
        if await skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "I went to work and then had lunch before coming home",
            dictionary: []
        )
        // No list trigger → output should be a single prose line.
        #expect(listLineCount(result) == 0)
        #expect(result.lowercased().contains("went to work"))
    }
}
