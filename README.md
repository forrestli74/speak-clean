# SpeakClean

Push-to-talk dictation for macOS. Capture audio, transcribe on-device, clean up filler words with a local LLM, paste into the active app.

## Download

[**Download SpeakClean.dmg** (latest)](https://github.com/forrestli74/speak-clean/releases/latest/download/SpeakClean.dmg)

### First-time install

1. Open the DMG and drag `SpeakClean.app` to `Applications`.
2. In `/Applications`, **right-click** `SpeakClean.app` → **Open**. Click **Open** in the "Apple cannot verify..." dialog. (One-time per install — standard macOS flow for apps not on the App Store.)
3. On first launch, grant:
    - **Microphone** permission (prompted automatically)
    - **Accessibility** permission (required for the global hotkey and paste — add SpeakClean in System Settings → Privacy & Security → Accessibility)

### Updates

Download the new DMG from the same URL and drag the new `.app` into `/Applications`, replacing the old one. Your permission grants carry over automatically — no re-granting needed.

### Requirements

macOS 26+, Apple Silicon. Ollama (`brew install ollama`) + `ollama pull gemma4:e2b` provides the local cleanup model.

## How it works

Hold the configured shortcut (default: `option+space`). macOS captures microphone audio and streams it through Apple's on-device `SpeechAnalyzer`. Release the shortcut — the transcript is sent to a local Ollama-served Gemma 4 E2B model for filler-word cleanup, then pasted into whatever app has focus.

All speech recognition runs on-device. Cleanup runs locally via Ollama — nothing leaves your machine.

## Setup

After installing the app (above):

    brew install ollama
    brew services start ollama
    ollama pull gemma4:e2b   # ~7 GB download, one time

The menu-bar icon shows readiness. Click it for Settings (change shortcut or Ollama model) and a Reset action if something needs re-checking.

## Development

See `CLAUDE.md` for architecture, build instructions, and design decisions. Pure Swift Package Manager project — `swift build`, `swift test`. Requires Swift 6.2+, macOS 26+, Apple Silicon.
