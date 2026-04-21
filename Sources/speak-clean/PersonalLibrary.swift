import AppKit

/// App-wide user configuration, split across two backing stores:
/// UserDefaults for simple preferences (shortcut) and a plain text file
/// in `Application Support` for the custom dictionary. Caseless enum so
/// everything is module-scoped; no instances.
@MainActor
enum AppConfig {
    /// UserDefaults suite name; also doubles as the app's bundle
    /// identifier when editing the plist via `defaults write`.
    static let suiteName = "local.speakclean"

    /// Registered default for the global recording shortcut.
    /// Source of truth for both `defaults.register(...)` and the
    /// "Reset to Defaults" button in the Settings view.
    static let defaultShortcut = "option+space"

    /// Registered default for the Ollama cleanup model tag.
    static let defaultCleanupModel = "gemma4:e2b"

    /// The configured UserDefaults with registered defaults for any
    /// missing keys. Force-unwrapped because `suiteName` is a valid
    /// non-nil identifier.
    private static let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: suiteName)!
        d.register(defaults: [
            "shortcut": defaultShortcut,
            "cleanupModel": defaultCleanupModel,
        ])
        return d
    }()

    /// `~/Library/Application Support/SpeakClean/` — created lazily by
    /// `openDictionary()` on first use. Holds the dictionary file.
    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SpeakClean")
    }()

    /// Absolute path to the user's custom-dictionary text file.
    /// Read at the start of every recording via `loadDictionary()`.
    static let dictionaryURL: URL = appSupportDir.appendingPathComponent("dictionary.txt")

    // MARK: - Preferences

    /// Global keyboard shortcut, e.g. `"option+space"`. Change with
    /// `defaults write local.speakclean shortcut "cmd+shift+d"`.
    static var shortcut: String {
        get { defaults.string(forKey: "shortcut")! }
        set { defaults.set(newValue, forKey: "shortcut") }
    }

    /// Ollama model tag used for transcript cleanup, e.g. `"gemma4:e2b"`.
    /// Change with `defaults write local.speakclean cleanupModel "llama3.2:3b"`.
    /// The app re-checks availability on launch and from the Reset menu
    /// item, so `ollama pull <model>` is the only other step needed.
    ///
    /// Note: the prompt in `TextCleaner.instructions` is hand-tuned against
    /// Gemma 4 E2B. Other models will still work but may need prompt-example
    /// tweaks to hit the same pass rate on the integration test suite.
    static var cleanupModel: String {
        get { defaults.string(forKey: "cleanupModel")! }
        set { defaults.set(newValue, forKey: "cleanupModel") }
    }

    /// Parse an arbitrary shortcut string like `"cmd+shift+d"` into an
    /// `(NSEvent.ModifierFlags, keyCode)` pair. Returns `nil` if the
    /// string has no modifiers, uses unknown modifier names, or uses an
    /// unknown key. Case-insensitive; tolerant of whitespace around `+`.
    ///
    /// Used by both `parsedShortcut` (on the stored value) and the
    /// Settings view (on candidate input before persisting).
    static func parse(_ s: String) -> (modifiers: NSEvent.ModifierFlags, keyCode: UInt16)? {
        let parts = s.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "option", "alt": modifiers.insert(.option)
            case "command", "cmd": modifiers.insert(.command)
            case "control", "ctrl": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard let keyCode = keyCodeMap[parts.last!] else { return nil }
        return (modifiers, keyCode)
    }

    /// Parse `shortcut` (the stored preference) into an
    /// `(NSEvent.ModifierFlags, keyCode)` pair. Returns `nil` if the
    /// stored string is malformed — `installHotkey()` treats this as a
    /// no-op and logs a warning.
    static var parsedShortcut: (modifiers: NSEvent.ModifierFlags, keyCode: UInt16)? {
        parse(shortcut)
    }

    /// macOS virtual-keycode table for `parsedShortcut`. Covers letters,
    /// digits, function keys, and the common named keys. Anything not
    /// listed here will cause `parsedShortcut` to return `nil`.
    private static let keyCodeMap: [String: UInt16] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // MARK: - Dictionary

    /// Read the user dictionary (one entry per line) and return the
    /// non-empty, non-`#` lines with surrounding whitespace trimmed.
    /// Returns `[]` silently if the file doesn't exist yet — valid
    /// first-run state. The `from:` parameter is for test injection;
    /// production callers pass no argument.
    static func loadDictionary(from url: URL = dictionaryURL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Reveal the user dictionary in their default text editor, creating
    /// the file (with a comment-only bootstrap) and the enclosing
    /// Application Support directory if needed. Bound to the "Edit
    /// Dictionary…" menu item.
    static func openDictionary() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dictionaryURL.path) {
            FileManager.default.createFile(
                atPath: dictionaryURL.path,
                contents: Data("# Custom dictionary — one entry per line\n".utf8)
            )
        }
        NSWorkspace.shared.open(dictionaryURL)
    }
}
