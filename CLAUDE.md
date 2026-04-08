# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

speak-clean is a free, open-source macOS menu bar app (Apple Silicon) that captures mic audio, transcribes via whisper.cpp, removes filler words, and pastes clean text into the active app. A Typeless alternative.

## Build & Run

```bash
swift build                          # debug build
swift build -c release               # release build
swift run speak-clean                # run as menu bar app
swift run speak-clean --audio f.wav  # CLI mode (profiling)
swift test                           # run tests
```

Requires **Swift 6.2+**, macOS 13.0+. Pure SPM project — no Xcode project file.

## Architecture

Two targets plus tests (see `Package.swift`):

- **`speak-clean`** (executable) — AppDelegate, menu bar UI, global shortcut, mic recording, paste orchestration
  - `speak_clean.swift` — entry point, NSApplication lifecycle, NSStatusBar icon with 3 states, Option+Space shortcut monitor, AVAudioRecorder → transcribe → paste flow
  - `PersonalLibrary.swift` — `AppConfig` wrapping UserDefaults (`local.speakclean` suite), keyboard shortcut parser, dictionary file path
- **`SpeakCleanCore`** (library) — shared logic, testable
  - `Transcriber.swift` — loads audio via AVAudioFile, manages Whisper model lifecycle, calls whisper.cpp, post-processes via TextCleaner
  - `ModelManager.swift` — downloads GGML + CoreML encoder from HuggingFace, atomic file ops, cache at `~/Library/Application Support/SpeakClean/models/`
  - `TextCleaner.swift` — regex filler/self-correction removal (temporary; will be replaced by llama.cpp + Qwen 2.5 0.5B LLM)

**Data flow**: Mic → AVAudioRecorder (16kHz mono WAV) → Transcriber → whisper.cpp (CoreML ANE if available) → TextCleaner → NSPasteboard (save/restore) → CGEvent Cmd+V paste

**Single external dependency**: [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (wraps whisper.cpp with CoreML support)

## Key Design Decisions

- **Headless AppKit** — `.accessory` activation policy, no window, no dock icon
- **`Transcriber` is `@unchecked Sendable`** (not actor) due to SwiftWhisper Sendable conflicts with Swift 6.2
- **CLI `--audio` mode** uses `dispatchMain()` + `exit(0)` instead of DispatchSemaphore — semaphore blocks main thread which CoreML needs
- **CoreML encoder** auto-downloaded alongside GGML model; Whisper auto-uses it if `.mlmodelc` exists, no toggle needed

## Worktrees

Git worktrees should be created in `.worktrees/` directory.

## Files

- `idea.md` — Living document for project ideas, architecture decisions, status, and roadmap. Updated as the project evolves.
