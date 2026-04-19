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
  - `AvailabilityChecker.swift` — protocol + `DefaultAvailabilityChecker`. Runs: `SystemLanguageModel` availability → mic permission → `DictationTranscriber.supportedLocale` → `AssetInventory.assetInstallationRequest`. Any failure produces a user-facing reason string.
  - `PersonalLibrary.swift` — `AppConfig`: UserDefaults-backed `shortcut`, keyboard shortcut parser, dictionary file at `~/Library/Application Support/SpeakClean/dictionary.txt`, `loadDictionary()` helper.
- **`SpeakCleanCore`** (library): reusable core.
  - `Transcriber.swift` — `@MainActor` streaming session around `SpeechAnalyzer` + `DictationTranscriber`. `start()` installs an `AVAudioEngine` tap that converts PCM buffers and yields `AnalyzerInput` into an `AsyncStream`; `stop()` finalizes and returns the accumulated text; `cancel()` aborts.
  - `TextCleaner.swift` — `@MainActor` wrapper around `LanguageModelSession`. Fresh session per `clean(_:dictionary:)` call; dictionary baked into `instructions(dictionary:)` as "preserve these spellings". `instructions` is `nonisolated` (pure string) so tests don't need `@MainActor`.

## Data flow

Press shortcut → `Transcriber.start()` starts `AVAudioEngine` and the `SpeechAnalyzer` session. Audio buffers stream into the analyzer in parallel with user speech. Release shortcut → `Transcriber.stop()` finalizes and returns accumulated text → `TextCleaner.clean(raw, dictionary:)` runs the LLM → `pasteText(cleaned)` via `NSPasteboard` + Cmd+V.

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
- **`AnalysisContext.contextualStrings` is not wired yet** — per the design spec, the attachment point on `SpeechAnalyzer` wasn't confirmable from the docs alone. The dictionary is injected only into the LLM cleanup prompt ("preserve these spellings"). STT-side biasing can be added later if accuracy on dictionary words turns out to be the bottleneck.

## Worktrees

Git worktrees should be created in `.worktrees/` directory.

## Files

- `idea.md` — Living document for project ideas, architecture decisions, status, and roadmap.
- `docs/superpowers/specs/2026-04-18-native-ai-rewrite-design.md` — design spec for this rewrite.
- `docs/superpowers/plans/2026-04-18-native-ai-rewrite.md` — implementation plan for this rewrite.
