import Testing
import Foundation
@testable import speak_clean

@Suite("loadDictionary")
struct LoadDictionaryTests {

    private func writing(_ contents: String, run body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakclean-dict-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test func emptyFileReturnsEmpty() throws {
        try writing("") { url in
            #expect(AppConfig.loadDictionary(from: url) == [])
        }
    }

    @Test func commentsAndBlanksIgnored() throws {
        try writing("# header comment\n\n  \n# another\n") { url in
            #expect(AppConfig.loadDictionary(from: url) == [])
        }
    }

    @Test func entriesAreTrimmed() throws {
        try writing("  Winawer  \nTartakower\n   \n# note\nJiaqi\n") { url in
            #expect(AppConfig.loadDictionary(from: url) == ["Winawer", "Tartakower", "Jiaqi"])
        }
    }

    @Test func missingFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).txt")
        #expect(AppConfig.loadDictionary(from: url) == [])
    }
}
