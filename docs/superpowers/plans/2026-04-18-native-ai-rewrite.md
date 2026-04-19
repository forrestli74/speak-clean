# Native AI Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the whisper.cpp + regex-cleaner pipeline with Apple's native `SpeechAnalyzer` + `DictationTranscriber` + `LanguageModelSession`. Drops macOS 13–25 support and all per-app model download/cache/lifetime infrastructure.

**Architecture:** `AppController` is a 2-state machine (`.ready` / `.notReady(reason:)`) driven by an injectable `AvailabilityChecker`. `Transcriber` drives a streaming `SpeechAnalyzer` session fed by an `AVAudioEngine` tap. `TextCleaner` wraps a fresh `LanguageModelSession` per call and bakes the user's dictionary into its instructions. Recovery is one button: **Reset**.

**Tech Stack:** Swift 6.2, macOS 26+, Apple `Speech` + `FoundationModels` + `AVFoundation` + `AppKit`. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-04-18-native-ai-rewrite-design.md`

---

## File Structure

Before defining tasks, here's the final shape:

```
Package.swift                                    # macOS 26+; no SwiftWhisper
Sources/SpeakCleanCore/
  Transcriber.swift                              # rewritten — SpeechAnalyzer streaming
  TextCleaner.swift                              # rewritten — LanguageModelSession wrapper
Sources/speak-clean/
  AppController.swift                            # rewritten — 2-state + AvailabilityChecker
  AvailabilityChecker.swift                      # NEW — protocol + DefaultAvailabilityChecker
  PersonalLibrary.swift                          # trimmed — shortcut + dictionary only
  speak_clean.swift                              # rewritten — streaming flow, no CLI
Tests/SpeakCleanTests/
  AppControllerTests.swift                       # rewritten — state-transition tests with FakeChecker
  TextCleanerTests.swift                         # rewritten — instructions(dictionary:) tests
  PersonalLibraryTests.swift                     # NEW — loadDictionary tests
```

**Deleted:**
- `Sources/SpeakCleanCore/DownloadManager.swift`
- `Sources/SpeakCleanCore/ModelManager.swift`
- `Sources/speak-clean/ManagedModel.swift`
- `Tests/SpeakCleanTests/DownloadManagerTests.swift`
- `Tests/SpeakCleanTests/ManagedModelTests.swift`

---

## Execution order rationale

Steps are ordered so each task produces a **compilable checkpoint** whenever possible. Task 1 is the one exception: the teardown leaves the build broken until Tasks 2-6 complete the replacements. That is acceptable and expected — commit anyway, subsequent tasks restore compilability.

---

### Task 1: Teardown — delete obsolete code and bump platform floor

**Rationale:** Clear the ground. Package.swift change triggers the whole rebuild; file deletions remove the targets of the rewrite. The build will break until Task 6 completes.

**Files:**
- Delete: `Sources/SpeakCleanCore/DownloadManager.swift`
- Delete: `Sources/SpeakCleanCore/ModelManager.swift`
- Delete: `Sources/speak-clean/ManagedModel.swift`
- Delete: `Tests/SpeakCleanTests/DownloadManagerTests.swift`
- Delete: `Tests/SpeakCleanTests/ManagedModelTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Delete the files**

```bash
rm Sources/SpeakCleanCore/DownloadManager.swift
rm Sources/SpeakCleanCore/ModelManager.swift
rm Sources/speak-clean/ManagedModel.swift
rm Tests/SpeakCleanTests/DownloadManagerTests.swift
rm Tests/SpeakCleanTests/ManagedModelTests.swift
```

- [ ] **Step 2: Rewrite `Package.swift`**

Replace file contents with:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "speak-clean",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SpeakCleanCore"),
        .executableTarget(
            name: "speak-clean",
            dependencies: ["SpeakCleanCore"]
        ),
        .testTarget(
            name: "SpeakCleanTests",
            dependencies: ["SpeakCleanCore", "speak-clean"]
        ),
    ]
)
```

- [ ] **Step 3: Resolve packages (drops `SwiftWhisper` + transitive deps)**

Run: `swift package resolve 2>&1 | tail -5`
Expected: completes without error; `Package.resolved` is rewritten or removed.

- [ ] **Step 4: Commit**

```bash
git add -A Package.swift Package.resolved Sources Tests
git commit -m "chore: delete whisper/download/cache infrastructure, bump to macOS 26"
```

---

### Task 2: Trim `AppConfig` and add `loadDictionary()`

**Rationale:** Drop the UserDefaults keys that only existed for whisper model selection. Add a dictionary-file loader that the recording flow will consume.

**Files:**
- Modify: `Sources/speak-clean/PersonalLibrary.swift`
- Create: `Tests/SpeakCleanTests/PersonalLibraryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SpeakCleanTests/PersonalLibraryTests.swift`:

```swift
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
```

- [ ] **Step 2: Rewrite `Sources/speak-clean/PersonalLibrary.swift`**

```swift
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
```

- [ ] **Step 3: Build still broken, but PersonalLibrary compiles standalone — verify via targeted test compile**

Run: `swift build --target SpeakCleanCore 2>&1 | tail -5`
Expected: SpeakCleanCore fails (Transcriber/TextCleaner still reference old API) — that's fine. We can't run the test yet; we will after Task 6. Skip to commit.

- [ ] **Step 4: Commit**

```bash
git add Sources/speak-clean/PersonalLibrary.swift Tests/SpeakCleanTests/PersonalLibraryTests.swift
git commit -m "refactor: trim AppConfig to shortcut+dictionary; add loadDictionary()"
```

---

### Task 3: Rewrite `TextCleaner` around `LanguageModelSession`

**Rationale:** Pure-logic parts (instruction builder) are testable; the LLM call itself is not. Write the tests for what can be tested.

**Files:**
- Modify: `Sources/SpeakCleanCore/TextCleaner.swift`
- Modify: `Tests/SpeakCleanTests/TextCleanerTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace `Tests/SpeakCleanTests/TextCleanerTests.swift` contents:

```swift
import Testing
@testable import SpeakCleanCore

@Suite("TextCleaner.instructions")
struct TextCleanerInstructionsTests {

    @Test func emptyDictionaryHasNoPreserveBlock() {
        let s = TextCleaner.instructions(dictionary: [])
        #expect(s.contains("Clean up a speech transcript"))
        #expect(!s.contains("Preserve these spellings"))
    }

    @Test func populatedDictionaryIncludesEachWord() {
        let s = TextCleaner.instructions(dictionary: ["Winawer", "Jiaqi"])
        #expect(s.contains("Preserve these spellings exactly:"))
        #expect(s.contains("- Winawer"))
        #expect(s.contains("- Jiaqi"))
    }

    @Test func instructionsListFillerWords() {
        let s = TextCleaner.instructions(dictionary: [])
        #expect(s.contains("um"))
        #expect(s.contains("you know"))
    }
}
```

- [ ] **Step 2: Rewrite `Sources/SpeakCleanCore/TextCleaner.swift`**

```swift
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

    /// Build the system-instruction string. Public-for-testing.
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
```

- [ ] **Step 3: Commit**

Build is still broken (Transcriber is next). Commit anyway — the new TextCleaner compiles in isolation once the old API dependencies are cleared.

```bash
git add Sources/SpeakCleanCore/TextCleaner.swift Tests/SpeakCleanTests/TextCleanerTests.swift
git commit -m "feat: rewrite TextCleaner as LanguageModelSession wrapper"
```

---

### Task 4: Rewrite `Transcriber` — `SpeechAnalyzer` + `DictationTranscriber` streaming

**Rationale:** This is the only task without unit tests — all the code calls Apple framework types that can't run in XCTest without a real mic and Apple Intelligence. Manual verification only (done in Task 7).

**Files:**
- Modify: `Sources/SpeakCleanCore/Transcriber.swift`

- [ ] **Step 1: Rewrite the file**

Replace `Sources/SpeakCleanCore/Transcriber.swift` contents:

```swift
import AVFoundation
import Speech

@MainActor
public final class Transcriber {

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedLocale(Locale)
        case alreadyRecording
        case notRecording
        case engineStartFailed(Swift.Error)
        case formatUnavailable

        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let l): return "Unsupported locale: \(l.identifier)"
            case .alreadyRecording: return "Recording already in progress"
            case .notRecording: return "No recording in progress"
            case .engineStartFailed(let e): return "Audio engine failed: \(e.localizedDescription)"
            case .formatUnavailable: return "Could not determine audio format"
            }
        }
    }

    private var session: Session?

    public init() {}

    /// Begin streaming recognition. Captures microphone audio via
    /// `AVAudioEngine`, feeds it to a `SpeechAnalyzer` session, and
    /// accumulates final results. Call `stop()` to finalize and retrieve text.
    public func start() async throws {
        guard session == nil else { throw Error.alreadyRecording }

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw Error.unsupportedLocale(Locale.current)
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Error.formatUnavailable
        }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let engine = AVAudioEngine()
        let hwFormat = engine.inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [inputBuilder] buffer, _ in
            guard let converter else {
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
            var consumed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if err == nil {
                inputBuilder.yield(AnalyzerInput(buffer: out))
            }
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            inputBuilder.finish()
            throw Error.engineStartFailed(error)
        }

        let buffer = TextBuffer()
        let resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results where result.isFinal {
                    buffer.text += String(result.text.characters)
                }
            } catch {
                // Errors propagate via analyzerTask; swallow here to not crash.
            }
        }

        let analyzerTask: Task<AVAudioTime?, Swift.Error> = Task {
            try await analyzer.analyzeSequence(inputSequence)
        }

        session = Session(
            analyzer: analyzer,
            transcriber: transcriber,
            engine: engine,
            inputBuilder: inputBuilder,
            resultsTask: resultsTask,
            analyzerTask: analyzerTask,
            buffer: buffer
        )
    }

    /// Stop recording, finalize the session, and return the accumulated text.
    public func stop() async throws -> String {
        guard let s = session else { throw Error.notRecording }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()

        let lastSampleTime = try await s.analyzerTask.value
        if let t = lastSampleTime {
            try await s.analyzer.finalizeAndFinish(through: t)
        } else {
            try s.analyzer.cancelAndFinishNow()
        }

        await s.resultsTask.value
        return s.buffer.text.trimmingCharacters(in: .whitespaces)
    }

    /// Abort without returning text.
    public func cancel() async {
        guard let s = session else { return }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()
        try? s.analyzer.cancelAndFinishNow()
        s.analyzerTask.cancel()
        s.resultsTask.cancel()
    }

    // MARK: - Private

    private final class TextBuffer {
        var text: String = ""
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let transcriber: DictationTranscriber
        let engine: AVAudioEngine
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        let resultsTask: Task<Void, Never>
        let analyzerTask: Task<AVAudioTime?, Swift.Error>
        let buffer: TextBuffer
    }
}
```

- [ ] **Step 2: Commit**

Build still broken (AppController not updated yet). Commit.

```bash
git add Sources/SpeakCleanCore/Transcriber.swift
git commit -m "feat: rewrite Transcriber as SpeechAnalyzer streaming session"
```

---

### Task 5: Add `AvailabilityChecker` + rewrite `AppController`

**Rationale:** A protocol boundary gives us a testable state machine independent of Apple's frameworks. A `FakeAvailabilityChecker` drives the state-transition tests; the production `DefaultAvailabilityChecker` runs the real checks but isn't itself unit-tested.

**Files:**
- Create: `Sources/speak-clean/AvailabilityChecker.swift`
- Modify: `Sources/speak-clean/AppController.swift`
- Modify: `Tests/SpeakCleanTests/AppControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace `Tests/SpeakCleanTests/AppControllerTests.swift` contents:

```swift
import Testing
@testable import speak_clean

private final class FakeChecker: AvailabilityChecker, @unchecked Sendable {
    var nextResult: AppController.State
    var callCount = 0
    init(_ initial: AppController.State) { self.nextResult = initial }
    func check() async -> AppController.State {
        callCount += 1
        return nextResult
    }
}

@Suite("AppController")
struct AppControllerTests {

    @Test @MainActor func startsInNotReady() {
        let controller = AppController(checker: FakeChecker(.ready))
        if case .notReady = controller.state { } else {
            Issue.record("Expected .notReady at init, got \(controller.state)")
        }
    }

    @Test @MainActor func resetTransitionsToReadyWhenAvailable() async {
        let checker = FakeChecker(.ready)
        let controller = AppController(checker: checker)
        await controller.reset()
        if case .ready = controller.state { } else {
            Issue.record("Expected .ready, got \(controller.state)")
        }
        #expect(checker.callCount == 1)
    }

    @Test @MainActor func resetTransitionsToNotReadyWhenChecksFail() async {
        let checker = FakeChecker(.notReady(reason: "No AI"))
        let controller = AppController(checker: checker)
        await controller.reset()
        if case .notReady(let reason) = controller.state {
            #expect(reason == "No AI")
        } else {
            Issue.record("Expected .notReady, got \(controller.state)")
        }
    }

    @Test @MainActor func onStateChangeFiresForEachTransition() async {
        let checker = FakeChecker(.ready)
        let controller = AppController(checker: checker)
        var log: [String] = []
        controller.onStateChange = { state in
            switch state {
            case .ready: log.append("ready")
            case .notReady(let r): log.append("notReady(\(r))")
            }
        }
        await controller.reset()
        // First transition: transient "Checking availability…"
        // Second: terminal .ready
        #expect(log == ["notReady(Checking availability…)", "ready"])
    }

    @Test @MainActor func secondResetRerunsChecks() async {
        let checker = FakeChecker(.ready)
        let controller = AppController(checker: checker)
        await controller.reset()
        await controller.reset()
        #expect(checker.callCount == 2)
    }
}
```

- [ ] **Step 2: Create `Sources/speak-clean/AvailabilityChecker.swift`**

```swift
import Foundation
import AVFoundation
import Speech
import FoundationModels

protocol AvailabilityChecker: Sendable {
    func check() async -> AppController.State
}

/// Production checker. Runs availability checks in order: Apple Intelligence,
/// microphone permission, locale support, STT asset install. Any failure short-
/// circuits and returns `.notReady(reason:)` with a user-facing message.
struct DefaultAvailabilityChecker: AvailabilityChecker {
    func check() async -> AppController.State {
        // 1. Apple Intelligence (Foundation Models)
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            return .notReady(reason: "This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notReady(reason: "Turn on Apple Intelligence in System Settings.")
        case .unavailable(.modelNotReady):
            return .notReady(reason: "Apple Intelligence is still setting up. Try again shortly.")
        case .unavailable(let other):
            return .notReady(reason: "Apple Intelligence unavailable: \(other).")
        }

        // 2. Microphone permission
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            return .notReady(reason: "Microphone permission denied. Grant it in System Settings.")
        }

        // 3. Locale support
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            return .notReady(reason: "Dictation doesn't support your locale (\(Locale.current.identifier)).")
        }

        // 4. STT assets
        let transcriber = await DictationTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return .notReady(reason: "Could not install dictation assets: \(error.localizedDescription).")
        }

        return .ready
    }
}
```

- [ ] **Step 3: Rewrite `Sources/speak-clean/AppController.swift`**

```swift
import Foundation
import SpeakCleanCore

@MainActor
final class AppController {
    enum State: Sendable, Equatable {
        case ready
        case notReady(reason: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.ready, .ready): return true
            case (.notReady(let a), .notReady(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .notReady(reason: "Initializing…")
    var onStateChange: ((State) -> Void)?

    private let checker: AvailabilityChecker
    let transcriber = Transcriber()
    let cleaner = TextCleaner()

    private var inFlight: Task<Void, Never>?

    init(checker: AvailabilityChecker) {
        self.checker = checker
    }

    /// Cancel any work, re-run availability checks, transition to the result.
    /// Called on launch and from the "Reset" menu item.
    func reset() async {
        inFlight?.cancel()
        inFlight = nil
        await transcriber.cancel()

        transition(to: .notReady(reason: "Checking availability…"))
        transition(to: await checker.check())
    }

    /// Record a failure (e.g., error thrown during a recording). Forces Reset
    /// as the recovery path.
    func markFailed(_ reason: String) {
        transition(to: .notReady(reason: reason))
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}
```

- [ ] **Step 4: Commit**

Build is still broken — `speak_clean.swift` (AppDelegate) still references `ManagedModel` / `markBusy` / `markDone`. Next task fixes.

```bash
git add Sources/speak-clean/AppController.swift Sources/speak-clean/AvailabilityChecker.swift Tests/SpeakCleanTests/AppControllerTests.swift
git commit -m "feat: 2-state AppController with AvailabilityChecker protocol"
```

---

### Task 6: Rewrite `speak_clean.swift` (AppDelegate + main)

**Rationale:** The last piece that restores compilability. Drops CLI mode, replaces markBusy/markDone/waitUntilReady with direct Transcriber + TextCleaner calls, switches to a 3-item menu.

**Files:**
- Modify: `Sources/speak-clean/speak_clean.swift`

- [ ] **Step 1: Replace `Sources/speak-clean/speak_clean.swift`**

```swift
import AppKit
import SpeakCleanCore

// MARK: - Menu bar icons (unchanged from prior version)

enum MenuBarIcon {
    static func idle(height: CGFloat = 18) -> NSImage {
        let width = height
        let scale = height / 36.0
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.black.setStroke()
            let lw: CGFloat = 2.5 * scale
            let cursor = NSBezierPath()
            cursor.lineWidth = lw
            cursor.lineCapStyle = .round
            cursor.move(to: NSPoint(x: 6*scale, y: 6*scale));  cursor.line(to: NSPoint(x: 6*scale, y: 30*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 6*scale));  cursor.line(to: NSPoint(x: 10*scale, y: 6*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 30*scale)); cursor.line(to: NSPoint(x: 10*scale, y: 30*scale))
            cursor.stroke()
            for bar in [(16.0, 14.0, 22.0), (21.0, 8.0, 28.0), (26.0, 11.0, 25.0), (31.0, 14.0, 22.0)] {
                let path = NSBezierPath()
                path.lineWidth = lw
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: bar.0*scale, y: bar.1*scale))
                path.line(to: NSPoint(x: bar.0*scale, y: bar.2*scale))
                path.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static func recording(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: true) { rect in
            NSColor.black.setFill()
            let inset = height * 0.15
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    static func processing(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: true) { _ in
            NSColor.black.setFill()
            let r = height * 0.08
            let cy = height / 2
            let gap = height * 0.22
            for i in -1...1 {
                let cx = height/2 + CGFloat(i) * gap
                NSBezierPath(ovalIn: NSRect(x: cx-r, y: cy-r, width: r*2, height: r*2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var isRecording = false
    private var inFlight: Task<Void, Never>?
    let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    private func setIcon(_ icon: NSImage) { statusItem?.button?.image = icon }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = buildMenu()
        setIcon(MenuBarIcon.processing())

        controller.onStateChange = { [weak self] state in
            guard let self, !self.isRecording else { return }
            switch state {
            case .ready:
                self.setIcon(MenuBarIcon.idle())
                self.statusItem?.button?.toolTip = "Ready"
            case .notReady(let reason):
                self.setIcon(MenuBarIcon.processing())
                self.statusItem?.button?.toolTip = reason
            }
        }

        setupGlobalShortcut()
        Task { await controller.reset() }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit Dictionary…", action: #selector(editDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(resetController), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func editDictionary() { AppConfig.openDictionary() }

    @objc private func resetController() {
        Task { await controller.reset() }
    }

    private func setupGlobalShortcut() {
        guard let s = AppConfig.parsedShortcut else {
            print("Invalid shortcut: \(AppConfig.shortcut)")
            return
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(s.modifiers) && e.keyCode == s.keyCode {
                self?.toggleRecording()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(s.modifiers) && e.keyCode == s.keyCode {
                self?.toggleRecording()
                return nil
            }
            return e
        }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard case .ready = controller.state else { return }
        Task { @MainActor in
            do {
                try await controller.transcriber.start()
                isRecording = true
                setIcon(MenuBarIcon.recording())
                NSSound(named: .init("Tink"))?.play()
            } catch {
                print("Start failed: \(error)")
                controller.markFailed("Recording start failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        setIcon(MenuBarIcon.processing())
        NSSound(named: .init("Pop"))?.play()

        let controller = self.controller
        inFlight = Task { @MainActor [weak self] in
            defer { self?.inFlight = nil }
            do {
                let raw = try await controller.transcriber.stop()
                let dictionary = AppConfig.loadDictionary()
                let cleaned = try await controller.cleaner.clean(raw, dictionary: dictionary)
                if !cleaned.isEmpty {
                    self?.pasteText(cleaned)
                }
                self?.setIcon(MenuBarIcon.idle())
            } catch {
                print("Transcription failed: \(error)")
                controller.markFailed("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let kd = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let ku = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        kd?.flags = .maskCommand
        ku?.flags = .maskCommand
        kd?.post(tap: .cghidEventTap)
        ku?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let p = previous {
                pb.clearContents()
                pb.setString(p, forType: .string)
            }
        }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(checker: DefaultAvailabilityChecker())
        let delegate = AppDelegate(controller: controller)
        app.delegate = delegate
        app.run()
    }
}
```

- [ ] **Step 2: Full build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeded.

- [ ] **Step 3: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass (TextCleaner instructions, PersonalLibrary loadDictionary, AppController state transitions). No `DownloadManagerTests` / `ManagedModelTests` in the suite.

- [ ] **Step 4: Commit**

```bash
git add Sources/speak-clean/speak_clean.swift
git commit -m "feat: streaming AppDelegate on Transcriber+TextCleaner; drop CLI mode"
```

---

### Task 7: Update CLAUDE.md and final verification

**Rationale:** Documentation now wildly out of date — references SwiftWhisper, `--audio` CLI, model cache, `ManagedModel`. Update to reflect the new reality.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rewrite `CLAUDE.md`**

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

speak-clean is an open-source macOS menu bar app (Apple Silicon, macOS 26+) that captures mic audio, transcribes via Apple's on-device `SpeechAnalyzer`, cleans filler words via Apple Intelligence (`LanguageModelSession`), and pastes the result into the active app.

## Build & Run

```bash
swift build                                      # debug build
swift build -c release                           # release build
swift run speak-clean                            # run as menu bar app
swift test                                       # run all tests
swift test --filter AppControllerTests           # run one test class
```

Requires **Swift 6.2+**, **macOS 26.0+**, a Mac that supports Apple Intelligence (Apple Silicon + ≥8 GB RAM) with Apple Intelligence enabled in System Settings. Pure SPM project — no external dependencies, no Xcode project file.

## Architecture

Two targets plus tests:

- **`speak-clean`** (executable): menu bar UI, hotkey, recording orchestration.
  - `speak_clean.swift` — entry point, `AppDelegate` with 3-item menu (Edit Dictionary / Reset / Quit), global shortcut monitor, streaming record/transcribe/clean/paste flow.
  - `AppController.swift` — `@MainActor` 2-state machine (`.ready` / `.notReady(reason:)`). Owns a `Transcriber` and a `TextCleaner`. One public action: `reset()` re-runs availability checks.
  - `AvailabilityChecker.swift` — protocol + `DefaultAvailabilityChecker`. Runs: SystemLanguageModel availability → mic permission → `DictationTranscriber.supportedLocale` → `AssetInventory.assetInstallationRequest`. Any failure produces a user-facing reason string.
  - `PersonalLibrary.swift` — `AppConfig`: UserDefaults-backed `shortcut`, keyboard shortcut parser, dictionary file at `~/Library/Application Support/SpeakClean/dictionary.txt`, `loadDictionary()` helper.
- **`SpeakCleanCore`** (library): reusable core.
  - `Transcriber.swift` — `@MainActor` streaming session around `SpeechAnalyzer` + `DictationTranscriber`. `start()` installs an `AVAudioEngine` tap that converts PCM buffers and yields `AnalyzerInput` into an `AsyncStream`; `stop()` finalizes and returns the accumulated text; `cancel()` aborts.
  - `TextCleaner.swift` — `@MainActor` wrapper around `LanguageModelSession`. Fresh session per `clean(_:dictionary:)` call; dictionary baked into `instructions(dictionary:)` as "preserve these spellings".

## Data flow

Press shortcut → `Transcriber.start()` starts `AVAudioEngine` and the `SpeechAnalyzer` session. Audio buffers stream into the analyzer in parallel with user speech. Release shortcut → `Transcriber.stop()` finalizes and returns the accumulated text → `TextCleaner.clean(raw, dictionary:)` runs the LLM → `pasteText(cleaned)` via `NSPasteboard` + Cmd+V.

## Failure model

**One recovery mechanism: Reset.** Any error during availability checks, recording, or cleanup transitions `AppController` to `.notReady(reason:)`. The hotkey becomes a no-op; the menu tooltip shows the reason. User clicks "Reset" → `AppController.reset()` re-runs all availability checks. No per-error fallback paths, no auto-retry.

## Key design decisions

- **Headless AppKit** — `.accessory` activation policy, no window, no dock icon.
- **`AvailabilityChecker` is a protocol** — `DefaultAvailabilityChecker` for production, `FakeChecker` in tests. `AppController` is unit-testable without any Apple framework availability.
- **No `ManagedModel`-style lifetime wrapper** — `SpeechAnalyzer` and `LanguageModelSession` are cheap to create per session; Apple manages the underlying model memory.
- **Streaming, not batch** — `AVAudioEngine` tap feeds `SpeechAnalyzer` live. No `AVAudioRecorder`, no WAV files. Transcription runs during speech, not after.
- **Fresh `LanguageModelSession` per cleanup call** — no conversation state carries across utterances.
- **Dictionary is read at each recording** — cheap, always fresh, no file watcher.
- **No CLI mode** — removed when we switched off whisper.cpp. If debugging is needed later, add a file-driven harness then.

## Worktrees

Git worktrees should be created in `.worktrees/` directory.

## Files

- `idea.md` — Living document for project ideas, architecture decisions, status, and roadmap.
```

- [ ] **Step 2: Final release build**

Run: `swift build -c release 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 3: Final test run**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for native AI architecture"
```

- [ ] **Step 5: Manual smoke test (performed by human)**

The following cannot be automated; the person running the plan must verify:

1. On an Apple-Intelligence-capable Mac with Apple Intelligence **enabled**:
   - `swift run speak-clean` → menu bar icon appears.
   - After brief pause, tooltip says "Ready".
   - Press the configured shortcut, speak a sentence with fillers, release.
   - Text is pasted into the active app, fillers removed.
2. On a Mac with Apple Intelligence **disabled** in Settings:
   - `swift run speak-clean` → tooltip says "Turn on Apple Intelligence in System Settings."
   - Shortcut is a no-op.
   - Enable Apple Intelligence in Settings → click "Reset" in the menu → tooltip transitions to "Ready".
3. Edit `~/Library/Application Support/SpeakClean/dictionary.txt`, add a proper noun, save. Record a sentence using it. Verify it's spelled as written in the dictionary.

---

## Self-review

**Spec coverage check:**

- Platform floor (macOS 26+): Task 1 Package.swift. ✓
- Delete `DownloadManager`, `ModelManager`, `ManagedModel`: Task 1. ✓
- Rewrite `Transcriber`: Task 4. ✓
- Rewrite `TextCleaner`: Task 3. ✓
- Rewrite `AppController` as 2-state: Task 5. ✓
- `AvailabilityChecker` protocol: Task 5. ✓
- `AppConfig` trim + `loadDictionary`: Task 2. ✓
- Remove CLI mode: Task 6 (entire `--audio` / `--save-audio` branches deleted when file rewritten). ✓
- Menu bar: Edit Dictionary / Reset / Quit: Task 6. ✓
- Streaming data flow (AVAudioEngine tap → AsyncStream → SpeechAnalyzer): Task 4. ✓
- Dictionary injected at both STT and cleanup points: Task 6 calls `AppConfig.loadDictionary()` at stop; passes to `cleaner.clean(_:dictionary:)`. STT-side `contextualStrings` wiring is deferred per spec Risk #1 fallback. ✓
- Availability checks for SystemLanguageModel / mic / locale / AssetInventory: Task 5 `DefaultAvailabilityChecker`. ✓
- Unit tests (TextCleaner instructions, PersonalLibrary loadDictionary, AppController state transitions): Tasks 2, 3, 5. ✓
- CLAUDE.md update: Task 7. ✓

**Placeholder scan:** None found. Every step has either exact code or exact commands.

**Type consistency:**
- `AppController.State` — enum with two cases; used consistently across AppController.swift, AvailabilityChecker.swift, AppControllerTests.swift, AppDelegate.
- `Transcriber.start()` / `stop()` / `cancel()` — same signatures in Transcriber.swift (Task 4) and AppDelegate (Task 6).
- `TextCleaner.clean(_:dictionary:)` — matches in TextCleaner.swift (Task 3) and AppDelegate (Task 6).
- `AppConfig.loadDictionary()` — defined with default `url:` parameter (Task 2), called with no argument in AppDelegate (Task 6).
- `AvailabilityChecker.check()` — protocol requirement, honored by `DefaultAvailabilityChecker` (Task 5) and `FakeChecker` in tests (Task 5).

No inconsistencies found.

**Spec Risk #1 (`AnalysisContext` wiring):** The fallback path is taken — `Transcriber` does not pass contextual strings into `SpeechAnalyzer`. The dictionary is used only in the LLM cleanup instructions. If STT accuracy on dictionary words is poor in practice, a follow-up task can add `AnalysisContext` once the attachment point is confirmed empirically.
