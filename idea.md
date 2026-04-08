# speak-clean

- Free, open-source Typeless alternative (Apple Silicon Mac only)
- Speech to text for typing, filters filler words (um, uh, like, you know, etc.)
- Minimal setup and memory footprint
- Single app bundle, no external dependencies

## Architecture

- **Swift Package Manager** project (`swift build` / `swift run`)
- **Headless AppKit app** — no window, no dock icon (`.accessory` activation policy)
  - Gives access to `NSEvent`, `NSPasteboard`, `NSWorkspace`
  - Proper app bundle for Accessibility permissions and distribution
- **whisper.cpp** bundled as static library (`libwhisper.a`)
  - Linked via C bridging header into Swift
  - CoreML/Metal acceleration on Apple Silicon
  - Model file (ggml-base.en) bundled in app resources
  - Reference: https://huggingface.co/openai/whisper-large-v3-turbo
- **Shortcut: Option+Space** — toggle recording (press to start, press again to stop)
  - On start: notification sound/visual feedback, begin mic capture
  - On stop: save audio to output folder, transcribe → filter → paste into focused text input
  - `NSEvent.addGlobalMonitorForEvents` for keyDown
  - Requires Accessibility permission
- **Filler word filtering** via LLM post-processing on transcription output
  - **llama.cpp** bundled as static library (same pattern as whisper.cpp)
  - C bridging header into Swift, Metal acceleration
  - **Qwen 2.5 0.5B Instruct** (GGUF Q4, ~400MB) — smallest model with reliable instruction following
  - Fallback: Qwen 2.5 1.5B if 0.5B isn't accurate enough
  - System prompt: "Rewrite removing filler words and verbal hesitations. Keep meaning and wording otherwise identical."
  - Pipeline: mic → whisper.cpp → llama.cpp → paste
- **Paste to active app** via `NSPasteboard` + simulated Cmd+V
  - Saves and restores previous clipboard contents

## Status

### Done
- Swift Package Manager project with headless AppKit app (`.accessory` activation policy)
- Menu bar icon (🎙 idle / ⏺ recording) via `NSStatusItem`
- Global shortcut (Option+Space) via `NSEvent.addGlobalMonitorForEvents` + local monitor
- Mic capture to 16kHz mono WAV files in `output/`
- Sound feedback (Tink on start, Pop on stop)
- Paste to active app via `NSPasteboard` + simulated Cmd+V (currently pastes "hello world" placeholder)
- Clipboard save/restore around paste

### Next
- Integrate llama.cpp + Qwen 2.5 0.5B for filler word filtering
- Wire full pipeline: mic → whisper.cpp → llama.cpp → paste
- **Menu bar reload button** — dropdown action that:
  - Reloads `config.json`
  - Re-downloads model if previous download failed
  - Download supports resume from last stopping point (HTTP Range requests)
- **Configurable shortcut** — UserDefaults as source of truth + menu bar item to change it
  - Library: **KeyboardShortcuts** (sindresorhus/KeyboardShortcuts) — Swift, SPM, actively maintained
  - No sync layer needed — KeyboardShortcuts uses UserDefaults natively
  - Menu bar dropdown item opens key capture dialog to set new shortcut

### TODO
- Show status line in menu-bar dropdown (idle / recording / transcribing)

### Notes
- `SpeakCleanCore/TextCleaner` has a regex-based filler/self-correction cleaner with test suite as spec; implementation will be swapped for LLM post-processing.
- Models cached at `~/Library/Application Support/SpeakClean/models/`
- Changing model in config auto-downloads new model on next use

## Config

- **Bundle ID**: `local.speakclean`
- **UserDefaults** (`~/Library/Preferences/local.speakclean.plist`) for app settings:
  - `shortcut` — keyboard shortcut string (default: `"option+space"`)
  - `model` — whisper model name (default: `"base.en"`)
- **Dictionary** (`~/Library/Application Support/SpeakClean/dictionary.txt`) — user-editable text file, one entry per line
  - Separate from plist because it's user data, not a preference
- Defaults registered via `UserDefaults.standard.register(defaults:)` at launch — no default file on disk
- KeyboardShortcuts library uses UserDefaults natively — no sync layer needed
