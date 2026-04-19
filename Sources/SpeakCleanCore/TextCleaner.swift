import FoundationModels

@MainActor
public final class TextCleaner {
    public init() {}

    /// Clean a raw transcript via the on-device LLM. Throws if the LLM session
    /// fails. Callers decide what to do on failure (spec: transition to .notReady
    /// and require Reset).
    public func clean(_ raw: String, dictionary: [String]) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count < 10_000 else { return trimmed }

        let session = LanguageModelSession(instructions: Self.instructions(dictionary: dictionary))
        let response = try await session.respond(to: trimmed)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the system-instruction string. Public for testing.
    public static func instructions(dictionary: [String]) -> String {
        let preserveBlock = dictionary.isEmpty
            ? ""
            : "\n\nPreserve these spellings exactly:\n" + dictionary.map { "- \($0)" }.joined(separator: "\n")

        return """
            Clean up a speech transcript. Return only the cleaned text with no preamble or explanation.

            Remove:
            - Filler words: um, uh, ah, er, like (as filler), you know, sort of, kind of, I mean
            - Self-corrections: when the speaker restarts mid-sentence, drop the abandoned phrase and keep the corrected one

            Preserve exactly:
            - Wording, punctuation, and capitalization of everything that remains
            - Do not add content, rephrase, expand abbreviations, or fix grammar\(preserveBlock)
            """
    }
}
