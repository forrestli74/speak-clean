import Testing
import AppKit
@testable import speak_clean

@Suite("AppConfig.parse")
@MainActor
struct AppConfigParseTests {

    @Test func validBasic() {
        let r = AppConfig.parse("option+space")
        #expect(r?.modifiers == .option)
        #expect(r?.keyCode == 49)
    }

    @Test func uppercaseNormalized() {
        let r = AppConfig.parse("OPTION+SPACE")
        #expect(r?.modifiers == .option)
        #expect(r?.keyCode == 49)
    }

    @Test func whitespaceAroundTokens() {
        let r = AppConfig.parse("option + space")
        #expect(r?.modifiers == .option)
        #expect(r?.keyCode == 49)
    }

    @Test func multipleModifiers() {
        let r = AppConfig.parse("cmd+shift+d")
        #expect(r?.modifiers == [.command, .shift])
        #expect(r?.keyCode == 2)
    }

    @Test func aliasesAccepted() {
        #expect(AppConfig.parse("alt+space")?.modifiers == .option)
        #expect(AppConfig.parse("ctrl+space")?.modifiers == .control)
        #expect(AppConfig.parse("command+space")?.modifiers == .command)
    }

    @Test func rejectsNoModifier() {
        #expect(AppConfig.parse("space") == nil)
    }

    @Test func rejectsUnknownModifier() {
        #expect(AppConfig.parse("fn+space") == nil)
    }

    @Test func rejectsUnknownKey() {
        #expect(AppConfig.parse("option+foo") == nil)
    }

    @Test func rejectsEmpty() {
        #expect(AppConfig.parse("") == nil)
    }

    @Test func rejectsTrailingPlus() {
        #expect(AppConfig.parse("option+") == nil)
    }

    @Test func defaultShortcutParses() {
        #expect(AppConfig.parse(AppConfig.defaultShortcut) != nil)
    }
}
