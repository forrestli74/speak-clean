import FoundationModels

/// Filler-word and self-correction cleanup over a raw STT transcript,
/// implemented as a thin wrapper around Apple's on-device
/// `LanguageModelSession`. Caseless enum — no state, no instances; the
/// session is created fresh per `clean(_:dictionary:)` call so no
/// conversation history leaks between utterances.
public enum TextCleaner {

    /// Run the transcript through the LLM and return the cleaned text.
    /// The `dictionary` words are baked into the system instructions as
    /// "preserve these spellings exactly" so user-defined proper nouns
    /// survive the cleanup pass. Throws whatever `LanguageModelSession`
    /// throws; callers are expected to surface failures via
    /// `AppController.setState(.notReady(...))`. Returns `""` for
    /// whitespace-only input; otherwise returns trimmed LLM output.
    public static func clean(_ raw: String, dictionary: [String]) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        let session = LanguageModelSession(instructions: instructions(dictionary: dictionary))
        let response = try await session.respond(to: trimmed)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the system-instruction string that tells the LLM what to
    /// remove and what to preserve. Pure function; exposed publicly so
    /// unit tests can assert on its output without calling the LLM.
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
