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

    @Test func stepMarkersProduceNumberedList() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "I want to build a recipe step 1 mix the flour step 2 add eggs step 3 bake",
            dictionary: []
        )
        let lower = result.lowercased()
        // Lead-in preserved, ended with colon.
        #expect(lower.contains("recipe"))
        #expect(result.contains(":"))
        // Each item becomes a numbered line.
        let numberedLines = result
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("1.") || t.hasPrefix("2.") || t.hasPrefix("3.")
            }
        #expect(numberedLines.count >= 3)
        // Marker words gone.
        #expect(!lower.contains("step 1"))
        #expect(!lower.contains("step 2"))
        // Content preserved.
        #expect(lower.contains("flour"))
        #expect(lower.contains("eggs"))
        #expect(lower.contains("bake"))
    }

    @Test func revisingAStepViaActuallyReplacesIt() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "step 1 mix the flour step 2 add eggs actually step 1 is preheat the oven",
            dictionary: []
        )
        let lower = result.lowercased()
        // Corrected step 1 content is present.
        #expect(lower.contains("preheat"))
        #expect(lower.contains("oven"))
        // Abandoned step 1 content ("mix the flour") is gone.
        #expect(!lower.contains("mix"))
        // Step 2 content is preserved.
        #expect(lower.contains("eggs"))
        // Numbered list format.
        let numberedLines = result
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("1.") || t.hasPrefix("2.")
            }
        #expect(numberedLines.count == 2)
        // Markers and correction phrase stripped.
        #expect(!lower.contains("step 1"))
        #expect(!lower.contains("step 2"))
        #expect(!lower.contains("actually"))
    }

    @Test func firstSecondProducesNumberedList() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "here are my thoughts first I agree with the plan second I have concerns",
            dictionary: []
        )
        let lower = result.lowercased()
        #expect(lower.contains("thoughts"))
        #expect(result.contains(":"))
        let numberedLines = result
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("1.") || t.hasPrefix("2.")
            }
        #expect(numberedLines.count >= 2)
        #expect(!lower.contains("first i agree"))
        #expect(!lower.contains("second i have"))
    }

    @Test func explicitBulletRequestProducesBullets() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "as bullet points buy groceries go to the bank pick up the kids",
            dictionary: []
        )
        let bulletLines = result
            .split(whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
        #expect(bulletLines.count >= 3)
        let lower = result.lowercased()
        #expect(lower.contains("groceries"))
        #expect(lower.contains("bank"))
        #expect(lower.contains("kids"))
        #expect(!lower.contains("as bullet points"))
    }

    @Test func proseWithoutListTriggerStaysProse() async throws {
        if skipIfUnavailable() { return }
        let result = try await TextCleaner.clean(
            "I went to work and then had lunch before coming home",
            dictionary: []
        )
        // No step/first-second/bullet trigger → should not force-format.
        #expect(!result.contains("\n1."))
        #expect(!result.contains("\n- "))
        #expect(result.lowercased().contains("went to work"))
    }
}
