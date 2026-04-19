# Native AI Rewrite — Design Spec

**Date:** 2026-04-18
**Branch:** `feature/native-ai`
**Status:** Spec; ready for implementation plan.

## Goal

Replace the whisper.cpp-based STT and regex-based text cleanup with Apple's native on-device models: `SpeechAnalyzer` + `DictationTranscriber` for speech-to-text, and `LanguageModelSession` (Foundation Models / Apple Intelligence) for filler-word cleanup.

Secondary goal: drastically simplify the codebase — remove the entire model-download, model-cache, and memory-management infrastructure that was required for whisper.cpp.

## Non-goals

- No fallback to whisper.cpp or any other STT engine.
- No fallback to regex cleanup.
- No support for devices lacking Apple Intelligence.
- No support for macOS < 26.
- No CLI mode (`--audio`, `--save-audio` are removed).
- No partial/volatile result UI. The transcript only becomes visible after the user releases the hotkey.

## Platform floor

- **macOS 26.0+** (enforced by `Package.swift` and `@available` guards).
- Device must support Apple Intelligence (Apple Silicon + ≥8 GB RAM) and have it enabled in System Settings.
- Microphone permission.
- A locale supported by `DictationTranscriber.supportedLocale(equivalentTo:)`.

If any requirement fails, the app shows a `.notReady(reason)` state with a human-readable explanation in the menu tooltip.

## Scope

### Deleted files

- `Sources/SpeakCleanCore/DownloadManager.swift`
- `Sources/SpeakCleanCore/ModelManager.swift`
- `Sources/speak-clean/ManagedModel.swift`
- `Tests/SpeakCleanTests/DownloadManagerTests.swift`
- `Tests/SpeakCleanTests/ManagedModelTests.swift`

### Package.swift

- Minimum platform: `.macOS(.v26)`.
- Remove the `SwiftWhisper` dependency. No external dependencies remain.

### Rewritten files

- `Sources/SpeakCleanCore/Transcriber.swift` — streaming wrapper around `SpeechAnalyzer` + `DictationTranscriber` driven by an `AVAudioEngine` tap.
- `Sources/SpeakCleanCore/TextCleaner.swift` — thin wrapper around `LanguageModelSession` that injects the user's dictionary into the instructions.
- `Sources/speak-clean/AppController.swift` — 2-state machine (`.ready` / `.notReady(reason)`) with a master `reset()` method.
- `Sources/speak-clean/PersonalLibrary.swift` — drop `model`, `modelsDir`, `modelUnloadDelay` keys.
- `Sources/speak-clean/speak_clean.swift` — streaming recording flow, no WAV pipeline, no CLI mode, simplified menu.
- `Tests/SpeakCleanTests/TextCleanerTests.swift` — replaced with tests of prompt-instruction construction.
- `Tests/SpeakCleanTests/AppControllerTests.swift` — state-transition tests for the simplified machine.

### Kept

- `AppDelegate` orchestration (hotkey monitor, menu bar icon rendering, paste).
- `AppConfig.shortcut`, `AppConfig.dictionaryURL`, `AppConfig.openDictionary()`.
- The dictionary file format at `~/Library/Application Support/SpeakClean/dictionary.txt` (one phrase per line; `#` for comments).

## Architecture

### Two-state machine

```swift
@MainActor
final class AppController {
    enum State {
        case ready
        case notReady(reason: String)
    }

    private(set) var state: State = .notReady(reason: "Initializing…")
    var onStateChange: ((State) -> Void)?

    func reset() async { ... }       // cancel in-flight, re-run availability checks
}
```

**Transitions:**

- Launch → `reset()` runs. All checks pass → `.ready`. Any failure → `.notReady(reason)`.
- Hotkey in `.ready` → recording flow. Any error → `.notReady(reason)`. No retry.
- Hotkey in `.notReady` → no-op.
- Menu "Reset" → `reset()` → re-runs checks.

### Streaming data flow

Three cooperating tasks during a recording:

```
AVAudioEngine tap  ──►  AsyncStream<AnalyzerInput>   (Task A: producer)
                                ▼
                       SpeechAnalyzer actor          (Task C: orchestrator)
                                ▼
                       transcriber.results           (Task B: consumer of final results)
```

**Start (hotkey press):**

1. Build `DictationTranscriber(locale: locale, preset: .transcription)`.
2. Build `AnalysisContext` with `.contextualStrings[.general] = loadDictionary()`.
3. Create `AsyncStream<AnalyzerInput>` and retain its continuation.
4. Create `SpeechAnalyzer(modules: [transcriber])`; attach the context.
5. Query `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`.
6. Start `AVAudioEngine`; install an input-node tap that converts each buffer to the target format (via `AVAudioConverter`) and yields an `AnalyzerInput` into the stream.
7. Launch Task B — consumes `transcriber.results`, keeps only `isFinal` results, appends their text to a running buffer.
8. Launch Task C — `try await analyzer.analyzeSequence(inputSequence)`; stores the returned `lastSampleTime`.

**Stop (hotkey release):**

1. Stop the audio engine; remove the tap.
2. `inputBuilder.finish()`.
3. `try await analyzer.finalizeAndFinish(through: lastSampleTime)`.
4. Await Task B to drain remaining final results.
5. Return accumulated text.
6. Pass to `TextCleaner.clean(_:dictionary:)`.
7. Paste the cleaned result via the existing `pasteText(_:)` code.

**Cancel (on error during recording):** `try analyzer.cancelAndFinishNow()` + `inputBuilder.finish()` + transition to `.notReady(reason)`.

### `TextCleaner`

```swift
@MainActor
public final class TextCleaner {
    public init() {}

    public func clean(_ raw: String, dictionary: [String]) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count < 10_000 else { return trimmed }

        let session = LanguageModelSession(instructions: Self.instructions(dictionary: dictionary))
        let response = try await session.respond(to: trimmed)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func instructions(dictionary: [String]) -> String {
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

Fresh `LanguageModelSession` per call; no conversation history across utterances.

### Availability check (at launch and on Reset)

All synchronous except the asset install, which awaits `downloadAndInstall()`.

```swift
func runAvailabilityChecks() async -> State {
    // 1. LLM
    switch SystemLanguageModel.default.availability {
    case .available: break
    case .unavailable(.deviceNotEligible):
        return .notReady(reason: "This Mac doesn't support Apple Intelligence.")
    case .unavailable(.appleIntelligenceNotEnabled):
        return .notReady(reason: "Turn on Apple Intelligence in System Settings.")
    case .unavailable(.modelNotReady):
        return .notReady(reason: "Apple Intelligence is still setting up. Try again in a bit.")
    case .unavailable(let other):
        return .notReady(reason: "Apple Intelligence unavailable: \(other).")
    }

    // 2. Mic permission (actual API: AVAudioApplication.requestRecordPermission, or
    //    checking AVCaptureDevice.authorizationStatus(for: .audio) — resolved in the
    //    implementation plan).
    guard await requestMicPermission() else {
        return .notReady(reason: "Microphone permission denied. Grant it in System Settings.")
    }

    // 3. Locale
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
        return .notReady(reason: "Dictation doesn't support your locale (\(Locale.current.identifier)).")
    }

    // 4. STT assets
    let transcriber = DictationTranscriber(locale: locale, preset: .transcription)
    do {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    } catch {
        return .notReady(reason: "Could not install dictation assets: \(error.localizedDescription).")
    }

    return .ready
}
```

### Menu bar

Three items:

1. **Edit Dictionary…** — `AppConfig.openDictionary()` (unchanged).
2. **Reset** — `controller.reset()`.
3. **Quit** — `NSApplication.terminate`.

Tooltip on the status item reflects the current state: `"Ready"` when `.ready`, or the reason string when `.notReady(reason)`.

## Config changes

| Key | Before | After |
|---|---|---|
| `shortcut` | `"option+space"` | unchanged |
| `model` | `"base.en"` | removed |
| `modelUnloadDelay` | `300.0` | removed |

`AppConfig.modelsDir` removed (computed property). The `~/Library/Application Support/SpeakClean/models/` directory is no longer created or used. `~/Library/Application Support/SpeakClean/dictionary.txt` is the only file we manage.

## Dictionary file

- Format unchanged.
- Read at the start of each recording (trivial cost).
- Same list consumed by two channels:
  1. `AnalysisContext.contextualStrings[.general]` — biases STT toward these spellings.
  2. `TextCleaner` instructions — tells the LLM not to alter these spellings.

## Testing

Unit tests:

- `TextCleanerTests` — verify `TextCleaner.instructions(dictionary:)` output for empty, single-item, and multi-item dictionaries. Pure string assertions. No LLM call.
- `AppControllerTests` — state transitions with a mocked availability checker. Cannot hit real `SystemLanguageModel` or `DictationTranscriber` in tests; inject a protocol.

No integration tests against the real Apple Intelligence / Speech frameworks. Manual testing only.

## Out of scope (future work)

- Dictation-cleanup or light-rewrite LLM scopes (punctuation fixup, grammar). Current prompt stays minimal.
- Custom pronunciations (`SFCustomLanguageModelData`). `contextualStrings` covers the 90% case.
- Live UI feedback during recording (partial result display).
- CLI mode. Can be re-added later by streaming a file through the same pipeline.

## Risks

1. **`AnalysisContext` wiring to `SpeechAnalyzer`:** the docs list `AnalysisContext` as the mechanism for supplying contextual strings to the new Speech API, but the example code on `developer.apple.com/documentation/Speech/SpeechAnalyzer` doesn't wire it through. The attachment point (init parameter? property on `SpeechAnalyzer` or on a module?) and the exact value for `ContextualStringsTag` (the docs show `.general` in shorthand but it may require an explicit value) both need to be confirmed at implementation time. Fallback: skip contextualStrings on v1, rely on the LLM's "preserve these spellings" instruction only.
2. **Asset install time:** `AssetInventory.downloadAndInstall()` for `DictationTranscriber` has no published size. First launch may block in `.notReady("Downloading…")` for an unknown duration. Acceptable per the "simple failure = reset" approach; users wait or cancel the app.
3. **LLM non-determinism:** the model may occasionally over-edit (remove a legitimate "like" used as a verb) or under-edit (leave a filler in). Tolerated. Users can refine the `dictionary.txt` or edit the pasted text.
4. **Swift 6.2 concurrency:** `AVAudioEngine` tap fires on an audio thread. The tap closure will need careful Sendable handling to yield into `AsyncStream.Continuation`. Expected: straightforward since `Continuation.yield` is documented thread-safe.
