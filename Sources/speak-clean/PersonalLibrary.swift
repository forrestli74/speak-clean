import AppKit

/// App-wide configuration backed by UserDefaults and Application Support files.
@MainActor
enum AppConfig {
    static let suiteName = "local.speakclean"

    private static let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: suiteName)!
        d.register(defaults: [
            "shortcut": "option+space",
        ])
        return d
    }()

    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SpeakClean")
    }()

    static let dictionaryURL: URL = appSupportDir.appendingPathComponent("dictionary.txt")

    // MARK: - Preferences

    static var shortcut: String {
        get { defaults.string(forKey: "shortcut")! }
        set { defaults.set(newValue, forKey: "shortcut") }
    }

    /// Parse shortcut string like "option+space" into modifiers and key code.
    static var parsedShortcut: (modifiers: NSEvent.ModifierFlags, keyCode: UInt16)? {
        let parts = shortcut.lowercased().split(separator: "+").map(String.init)
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

    /// Read the dictionary file and return non-empty, non-comment lines, trimmed.
    /// Returns `[]` if the file is missing or unreadable.
    static func loadDictionary(from url: URL = dictionaryURL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Opens the dictionary file, creating it if needed.
    static func openDictionary() {
        ensureAppSupportDir()
        if !FileManager.default.fileExists(atPath: dictionaryURL.path) {
            FileManager.default.createFile(
                atPath: dictionaryURL.path,
                contents: Data("# Custom dictionary — one entry per line\n".utf8)
            )
        }
        NSWorkspace.shared.open(dictionaryURL)
    }

    private static func ensureAppSupportDir() {
        if !FileManager.default.fileExists(atPath: appSupportDir.path) {
            try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
    }
}
