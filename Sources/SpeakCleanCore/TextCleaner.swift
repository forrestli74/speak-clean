import Foundation

public struct TextCleaner {
    public init() {}

    public func clean(_ text: String) -> String {
        var result = text

        // Remove filler words (standalone, case-insensitive)
        // Matches: um, uh, uh huh, hmm, ah, er, like, you know, I mean, basically, actually, literally, right, so, well
        let fillers = [
            #"(?i)\b(?:um+|uh+|uh\s+huh|hmm+|ah+|er+)\b"#,
            #"(?i)\b(?:you know|I mean|basically|actually|literally)\b"#,
            // "like", "so", "right", "well" only when used as fillers (start of clause or between commas)
            #"(?i)(?:^|(?<=,\s?))\s*(?:like|so|right|well)\b\s*,?"#,
        ]
        for pattern in fillers {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }

        // Remove self-corrections: "word-- I mean otherWord" or "word, no, otherWord" or "word, sorry, otherWord"
        // Keeps the correction (the part after), drops the false start
        let selfCorrections = [
            #"(\w+)\s*(?:--|—)\s*(?:I mean\s+|or rather\s+|no(?:,)?\s+|sorry(?:,)?\s+)?(\w+)"#,
        ]
        for pattern in selfCorrections {
            result = result.replacingOccurrences(
                of: pattern, with: "$2", options: .regularExpression)
        }

        // "word, no, correction" / "word, sorry, correction"
        result = result.replacingOccurrences(
            of: #"\b(\w+),?\s+(?:no|sorry),?\s+(\w+)"#,
            with: "$2",
            options: .regularExpression)

        // Collapse double commas (from removed filler between commas) into single space
        result = result.replacingOccurrences(
            of: #"\s*,\s*,\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\s+([.,!?])"#, with: "$1", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading commas after trimming
        result = result.replacingOccurrences(
            of: #"^[,\s]+"#, with: "", options: .regularExpression)

        // Capitalize first letter
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }
}
