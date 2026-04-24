# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

speak-clean is an open-source macOS menu bar app (Apple Silicon, macOS 26+) that captures mic audio, transcribes via Apple's on-device `SpeechAnalyzer`, cleans filler words via a local Ollama-served Gemma 4 E2B model, and pastes the result into the active app.

## Build & Run

```bash
brew install ollama                   # once
brew services start ollama            # once (persists across reboots)
ollama pull gemma4:e2b                # once, ~7 GB download (default)
# Or switch model from the Settings window (menu bar → Settings…) or via CLI:
# defaults write local.speakclean cleanupModel "llama3.2:3b"
# ollama pull llama3.2:3b

swift build                           # debug build
swift build -c release                # release build
swift run speak-clean                 # run as menu bar app
swift test                            # run all tests (integration tests skip if Ollama is down)
swift test --filter AppControllerTests
```

Requires **Swift 6.2+**, **macOS 26.0+**, Apple Silicon. Ollama + `gemma4:e2b` is the external runtime dependency — there is no bundled LLM. Pure SPM project — no Swift package dependencies, no Xcode project file.

## Architecture

Two targets plus tests:

- **`speak-clean`** (executable): menu bar UI, hotkey, recording orchestration.
  - `SpeakCleanApp.swift` — `@main` SwiftUI app. Two scenes: `MenuBarExtra` (menu with Settings…/Edit Dictionary/Reset/Quit) and `Settings` hosting `SettingsView`. `.accessory` activation policy set in `init()` before the scene renders.
  - `SettingsView.swift` — SwiftUI `Form` with two text fields (shortcut, Ollama model) and a "Reset to Defaults" button. Apply-on-commit: shortcut triggers `coordinator.reinstallHotkey()`; model triggers `coordinator.reset()`.
  - `RecordingCoordinator.swift` — `@Observable @MainActor` class. Owns the `AppController`, the global/local hotkey `NSEvent` monitors, and the per-press record/stop/paste Task. `reinstallHotkey()` lets the Settings view apply shortcut changes without restarting the app.
  - `AppController.swift` — `@MainActor` 2-state machine (`.ready` / `.notReady(reason:)`). Owns the `Transcriber`. One public action: `reset()` re-runs availability checks.
  - `AvailabilityChecker.swift` — `runAvailabilityChecks()` free function. Checks, in order: Ollama reachable → model pulled → mic permission → `DictationTranscriber.supportedLocale` → `AssetInventory.assetInstallationRequest`. Any failure produces a user-facing reason string with the shell command to fix it.
  - `PersonalLibrary.swift` — `AppConfig`: UserDefaults-backed `shortcut` and `cleanupModel` (Ollama tag), `defaultShortcut` / `defaultCleanupModel` constants (source of truth for registered defaults and the Reset button), `parse(_:)` shortcut string parser, dictionary file at `~/Library/Application Support/SpeakClean/dictionary.txt`, `loadDictionary()` helper.
- **`SpeakCleanCore`** (library): reusable core.
  - `Transcriber.swift` — `@MainActor` streaming session around `SpeechAnalyzer` + `DictationTranscriber`. `start()` installs an `AVAudioEngine` tap that converts PCM buffers and yields `AnalyzerInput` into an `AsyncStream`; `stop()` finalizes and returns the accumulated text; `cancel()` aborts.
  - `TextCleaner.swift` — caseless enum that POSTs to Ollama's `/api/chat` endpoint. `clean(_:dictionary:model:)` accepts the model tag as a parameter (default `TextCleaner.defaultModel = "gemma4:e2b"`); the app target passes `AppConfig.cleanupModel` so the user can swap models via `defaults write`. `instructions(dictionary:)` exposes prompt-building for unit tests.

## Data flow

Press shortcut → `Transcriber.start()` starts `AVAudioEngine` and the `SpeechAnalyzer` session. Audio buffers stream into the analyzer in parallel with user speech. Release shortcut → `Transcriber.stop()` finalizes and returns accumulated text → `TextCleaner.clean(raw, dictionary:)` POSTs to Ollama → `pasteText(cleaned)` via `NSPasteboard` + Cmd+V.

## Failure model

**One recovery mechanism: Reset.** Any error during availability checks, recording, or cleanup transitions `AppController` to `.notReady(reason:)`. The hotkey becomes a no-op; the menu tooltip shows the reason. User clicks "Reset" → `AppController.reset()` re-runs all availability checks. No per-error fallback paths, no auto-retry.

Reasons surfaced by the availability checker are actionable — e.g. `"Ollama isn't running. Run: brew services start ollama"` or `"Gemma model isn't installed. Run: ollama pull gemma4:e2b"`.

## Key design decisions

- **Headless AppKit** — `.accessory` activation policy, no window, no dock icon.
- **Local Ollama + Gemma 4 E2B for cleanup** — chose over Apple's Foundation Models (`LanguageModelSession`) after a benchmark showed Gemma 4 E2B passes 27/27 prompt tests deterministically while Apple's 3B foundation model had 4 intermittently-failing cases (over-helpful responses to questions and greetings). The tradeoff is a 7 GB local model download and an Ollama runtime dependency.
- **Streaming STT (Apple-native), not batch** — `AVAudioEngine` tap feeds `SpeechAnalyzer` live. No `AVAudioRecorder`, no WAV files. Transcription runs during speech, not after.
- **Fresh Ollama chat session per `clean` call** — no conversation state carries across utterances.
- **Dictionary is read at each recording** — cheap, always fresh, no file watcher.
- **`TextCleaner` is a caseless enum (no instance, not @MainActor)** — it's a stateless HTTP client; `URLSession` is thread-safe.
- **No CLI mode** — removed when we switched off whisper.cpp. If debugging is needed later, add a file-driven harness then.
- **`AnalysisContext.contextualStrings` is not wired yet** — per the design spec, the attachment point on `SpeechAnalyzer` wasn't confirmable from the docs. The dictionary is injected only into the cleanup prompt. STT-side biasing can be added later if accuracy on dictionary words turns out to be the bottleneck.

## App icon

Authored in `scripts/render-icon.swift` (SwiftUI `ImageRenderer`, 1024 px canvas, squircle + gradient + the menu-bar glyph). Regenerate with `scripts/build-icon.sh` — writes `Resources/AppIcon/icon-1024.png` and `Resources/AppIcon/AppIcon.icns`, both committed. `scripts/build-app.sh` copies the `.icns` into the bundle; it is not built at `swift build` time.

## Worktrees

Git worktrees should be created in `.worktrees/` directory.

## Files

- `idea.md` — Living document for project ideas, architecture decisions, status, and roadmap.
- `docs/superpowers/specs/2026-04-18-native-ai-rewrite-design.md` — design spec for the native-AI rewrite (Apple FM era; cleaner has since been swapped for Gemma 4 E2B).
- `docs/superpowers/plans/2026-04-18-native-ai-rewrite.md` — implementation plan for the same rewrite.
