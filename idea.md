# speak-clean

- Free, open-source Typeless alternative (Apple Silicon Mac only)
- Speech to text for typing, filters filler words (um, uh, like, you know, etc.)
- Minimal setup and memory footprint
- Single app bundle, no external dependencies

## Architecture

- **Swift Package Manager** project (`swift build` / `swift run`)
- **Headless AppKit app** — no window, no dock icon (`.accessory` activation policy)
  - Menu bar icon with status (idle / recording / processing)
  - Configurable shortcut via UserDefaults (default: Option+Space)
- **SwiftWhisper** SPM dependency (wraps whisper.cpp)
  - CoreML acceleration on Apple Silicon (Neural Engine) — ~5x faster than CPU
  - Models auto-downloaded from HuggingFace on first use (GGML + CoreML encoder)
  - Default model: `base.en` (~142 MB GGML + ~36 MB CoreML encoder)
- **Filler word filtering** via LLM post-processing on transcription output (planned)
  - **llama.cpp** bundled as static library
  - **Qwen 2.5 0.5B Instruct** (GGUF Q4, ~400MB)
  - Fallback: Qwen 2.5 1.5B if 0.5B isn't accurate enough
  - Pipeline: mic → whisper.cpp → llama.cpp → paste
- **Paste to active app** via `NSPasteboard` + simulated Cmd+V
  - Saves and restores previous clipboard contents
- **`--audio file.wav`** CLI mode for profiling — same code path as app mode

## Status

### Done
- Headless AppKit app with menu bar icon (idle / recording / processing states)
- Configurable shortcut via UserDefaults (default: Option+Space)
- Mic capture to 16kHz mono WAV → whisper transcription → regex cleanup → paste
- CoreML (ANE) acceleration — ~2s transcription for 37s audio on M-series
- Auto-download GGML model + CoreML encoder from HuggingFace with progress
- Model swappable via UserDefaults `model` key (auto-downloads on change)
- `--audio file.wav` CLI mode for profiling (same pipeline as app)
- Sound feedback (Tink on start, Pop on stop)
- Clipboard save/restore around paste
- Menu bar: Edit Dictionary, Clean Model Cache, Quit

### Next
- Integrate llama.cpp + Qwen 2.5 0.5B for filler word filtering (replace regex TextCleaner)
- Wire full pipeline: mic → whisper.cpp → llama.cpp → paste
- **Robust model download manager** — unified design covering:
  - **Resume**: check for `.download` temp file, send `Range: bytes=<size>-` header, handle 206/416
  - **Checksum**: fetch SHA256 from HuggingFace API, verify after download, reject corrupt files
  - **Abandon**: delete temp `.download` file + any corrupt final file on checksum mismatch
  - **Reuse cached**: skip download if final file exists and checksum matches
  - Applies to both GGML model and CoreML encoder zip

### TODO
- Show status line in menu-bar dropdown (idle / recording / transcribing)

### Notes
- `SpeakCleanCore/TextCleaner` — regex-based filler/self-correction cleaner with test suite as spec; will be swapped for LLM post-processing
- Models cached at `~/Library/Application Support/SpeakClean/models/` (GGML + CoreML encoder)
- CoreML encoder auto-downloaded from `huggingface.co/ggerganov/whisper.cpp`, placed alongside GGML model
- Whisper auto-uses CoreML if `.mlmodelc` exists, falls back to CPU if not — no toggle needed
- `Transcriber` is `@unchecked Sendable` (not an actor) due to SwiftWhisper Sendable conflicts with Swift 6.2
- `--audio` CLI uses `dispatchMain()` + `exit(0)` instead of `DispatchSemaphore` — semaphore blocks main thread which CoreML needs

## Config

- **Bundle ID**: `local.speakclean`
- **UserDefaults** (`~/Library/Preferences/local.speakclean.plist`) for app settings:
  - `shortcut` — keyboard shortcut string (default: `"option+space"`)
  - `model` — whisper model name (default: `"base.en"`)
- **Dictionary** (`~/Library/Application Support/SpeakClean/dictionary.txt`) — user-editable text file, one entry per line
  - Separate from plist because it's user data, not a preference
- Defaults registered via `UserDefaults.standard.register(defaults:)` at launch — no default file on disk
- KeyboardShortcuts library uses UserDefaults natively — no sync layer needed
