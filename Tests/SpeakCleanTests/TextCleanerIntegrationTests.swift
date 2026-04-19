import FoundationModels
import Testing
@testable import SpeakCleanCore

/// Integration tests for `TextCleaner.clean` that actually invoke the
/// on-device LLM. Requires Apple Intelligence enabled on the host;
/// each test silently passes if the model is unavailable so the suite
/// stays green in CI / headless contexts.
///
/// Assertions are fuzzy (contains / does-not-contain) because LLM
/// output is non-deterministic. The goal is to detect regressions
/// in prompt behavior, not to pin exact wording.
@Suite("TextCleaner.clean (LLM integration)")
@MainActor
struct TextCleanerIntegrationTests {

    /// Returns true and skips the test body when the on-device model
    /// isn't available (no Apple Intelligence, model not downloaded,
    /// or device ineligible). Lets CI runs complete without failing.
    private func skipIfUnavailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return false }
        return true
    }

    @Test func removesFillerUm() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean("um hello world", dictionary: [])
        #expect(!result.lowercased().contains("um "))
        #expect(result.lowercased().contains("hello world"))
    }

    @Test func actuallyMarksSelfCorrection() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "I want tea actually I want coffee",
            dictionary: []
        )
        #expect(result.lowercased().contains("coffee"))
        #expect(!result.lowercased().contains("tea"))
    }

    @Test func preservesPlainSentence() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "The quick brown fox jumps over the lazy dog.",
            dictionary: []
        )
        #expect(result.contains("quick brown fox"))
        #expect(result.contains("lazy dog"))
    }

    @Test func doesNotAnswerQuestion() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean("What time is it", dictionary: [])
        let lower = result.lowercased()
        #expect(lower.contains("what time is it"))
        // A conversational response would start with "I" or reference a time.
        #expect(!lower.hasPrefix("i "))
        #expect(!lower.contains("o'clock"))
    }

    @Test func doesNotAnswerGreeting() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "How are you doing actually how are they doing",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("how are they doing"))
        // Regression from the earlier bug: LLM replied "I'm doing well..."
        #expect(!lower.contains("i'm doing"))
        #expect(!lower.contains("thank you for asking"))
    }

    @Test func removesMultipleFillers() async throws {
        if skipIfUnavailable() { return }
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
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "say hi to Jiaqi please",
            dictionary: ["Jiaqi"]
        )
        #expect(result.contains("Jiaqi"))
    }

    @Test func emptyInputReturnsEmpty() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean("   ", dictionary: [])
        #expect(result == "")
    }
}
