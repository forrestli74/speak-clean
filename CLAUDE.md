# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

speak-clean is a free, open-source macOS menu bar app (Apple Silicon) that captures mic audio, transcribes via whisper.cpp, removes filler words, and pastes clean text into the active app. A Typeless alternative.

## Build & Run

```bash
swift build                                      # debug build
swift build -c release                           # release build
swift run speak-clean                            # run as menu bar app
swift run speak-clean --audio f.wav              # CLI mode (profiling)
swift test                                       # run all tests
swift test --filter AppControllerTests           # run one test class
swift test --filter AppControllerTests/testReset # run one test method
```

Requires **Swift 6.2+**, macOS 13.0+. Pure SPM project — no Xcode project file.

## Architecture

Two targets plus tests (see `Package.swift`):

- **`speak-clean`** (executable) — AppDelegate, menu bar UI, global shortcut, mic recording, paste orchestration
  - `speak_clean.swift` — entry point, CLI arg parsing, `AppDelegate` with NSStatusBar icon (3 states: idle/recording/processing), global shortcut monitor, AVAudioRecorder → transcribe → paste flow
  - `AppController.swift` — `@MainActor` disk-state machine (`notReady` / `ready` / `error`). Owns `ManagedModel<Whisper>` and `Transcriber`; exposes `reset / clearCache (async) / markError`, and `pinnedModelName` (the model name locked-in by the last `reset()` so config changes don't race in-flight loads). Memory lifetime is owned by `ManagedModel` — no `busy` state, no `markBusy`/`markDone`.
  - `ManagedModel<T>.swift` — **scoped lifetime** wrapper enforcing race-safe model access. Public API is three methods: `withModel { t in ... }` (load-or-join, refcount++, run body with ARC-pinned reference, refcount—, re-arm idle timer), `prewarm()` (advisory background load, no scope), `unloadWhenIdle() async` (wait for scopes to drain, then unload). `instance` is **not** observable — it cannot be read outside a scope, so callers can never see a nil-after-unload or half-loaded model. Generation counter in `startLoad` suppresses post-unload writes from in-flight loaders.
  - `PersonalLibrary.swift` — `AppConfig` wrapping UserDefaults (`local.speakclean` suite), keyboard shortcut parser + virtual-keycode map, models/dictionary paths under `~/Library/Application Support/SpeakClean/`
- **`SpeakCleanCore`** (library) — shared logic, testable without AppKit
  - `Transcriber.swift` — pure stateless transcriber; caller passes in a `Whisper` instance. Loads audio via AVAudioFile (resamples to 16kHz mono float32), calls whisper.cpp, post-processes via TextCleaner
  - `ModelManager.swift` — downloads GGML + CoreML encoder `.mlmodelc.zip` from HuggingFace `ggerganov/whisper.cpp`, unzips via `/usr/bin/unzip`, honors `Task.checkCancellation` between steps
  - `DownloadManager.swift` — URLSession download with optional SHA256 verification (fetched best-effort from HF LFS metadata), atomic move into place
  - `TextCleaner.swift` — regex filler/self-correction removal (temporary; will be replaced by llama.cpp + Qwen 2.5 0.5B LLM)

**Data flow**: Press shortcut → `startRecording` calls `whisper.prewarm()` (background load starts) + `AVAudioRecorder.record()` (16kHz mono WAV) in parallel → release shortcut → `stopRecording` opens `whisper.withModel { whisper in transcriber.transcribe(...) }`, which awaits the prewarm, pins the model reference for the body's duration, runs whisper.cpp (CoreML ANE if available) → TextCleaner → NSPasteboard (save/restore) → CGEvent Cmd+V paste → scope exits → `ManagedModel` arms `AppConfig.modelUnloadDelay` (default 300s) idle-unload timer.

**Single external dependency**: [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (wraps whisper.cpp with CoreML support)

## Key Design Decisions

- **Headless AppKit** — `.accessory` activation policy, no window, no dock icon
- **Scoped model lifetime (`withModel`) is the one pattern for race safety.** Races like "loader writes `instance` after `unload()` nil'd it" or "detached task reads `instance` and sees nil" are **unrepresentable** — `instance` is private, and the only access path is via a scope that pins the reference for the caller's body. If you find yourself wanting to add `waitUntilReady` / `instance` back, resist: the correct answer is almost always to expand what happens *inside* a `withModel` body.
- **`AppController` owns disk state only** (`notReady`/`ready`/`error`). Memory lifetime (load, idle unload, cancel) is internal to `ManagedModel`. `markError` records the error but does **not** force-unload — any in-flight `withModel` body completes normally; the scope's exit arms the idle timer as usual.
- **`pinnedModelName`** is set by `reset()` and read by the `ManagedModel`'s loader closure — it stops the race where the user changes `AppConfig.model` between download and first memory-load. `reset()` triggers `unloadWhenIdle` before the new download so the next `withModel` loads under the new name.
- **UI icon has three driving signals**, all in `AppDelegate`: `audioRecorder != nil` (recording icon), `isTranscribing` flag set inside the `withModel` Task (processing icon), and `controller.onStateChange` (processing for `.notReady`, idle for `.ready`/`.error`) as the fallback when neither recording nor transcribing.
- **Whisper crosses actor boundary via `nonisolated(unsafe)`** — `Whisper` is non-Sendable but thread-safe internally. The `withModel` body is `@MainActor` (loader and transcribe calls run on main, like the constructor already did); inside the body, `nonisolated(unsafe) let unsafeWhisper = whisper` lets us pass the reference into the nonisolated `Transcriber.transcribe`.
- **`Transcriber` is `@unchecked Sendable`** (not an actor) due to SwiftWhisper Sendable conflicts with Swift 6.2.
- **CLI `--audio` mode bypasses `AppController` / `ManagedModel`** — constructs its own `ModelManager` + `Whisper` + `Transcriber` in a `Task.detached`, uses `dispatchMain()` + `exit(0)` instead of DispatchSemaphore (semaphore blocks main thread which CoreML needs). Prints timing breakdown to stderr, transcription to stdout.
- **CoreML encoder** auto-downloaded alongside GGML model; Whisper auto-uses it if `.mlmodelc` exists, no toggle needed.
- **`--save-audio <dir>`** keeps recorded WAVs for debugging; without it, recordings land in `NSTemporaryDirectory()` and are deleted after transcription.

## Worktrees

Git worktrees should be created in `.worktrees/` directory.

## Files

- `idea.md` — Living document for project ideas, architecture decisions, status, and roadmap. Updated as the project evolves.
