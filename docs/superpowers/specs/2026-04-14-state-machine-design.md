# State Machine Design

## Overview

Replace the ad-hoc `isRecording` bool and scattered icon updates with two explicit state machines: one for the app (model lifecycle) and one per recording (mic-to-paste cycle). All transitions are synchronous mutations. Async work runs in Tasks and fires sync transitions on completion.

## App State Machine

### States

```swift
enum AppState: Equatable {
    case noModel          // startup, reading config, checking disk
    case downloading      // fetching model from HuggingFace
    case ready            // model on disk, not in memory
    case loading          // loading model into memory
    case loaded           // model in memory, idle timer running
    case error(String)    // failed, manual reset via menu bar
}
```

### Transitions

```
launch → noModel
noModel (no model on disk) → downloading
noModel (model on disk) → ready
downloading (success) → ready
downloading (failure) → error
ready (recording starts) → loading
loading (success) → loaded
loading (failure) → error
loaded (idle timeout) → ready
loaded (recording starts) → loaded (reset timer)
any (clean cache) → noModel
error (menu bar Retry) → noModel
```

### Menu bar icon by app state

| App State | Recording exists | Icon |
|---|---|---|
| noModel | no | processing (dots) |
| downloading | no | processing (dots) |
| ready | no | idle (waveform) |
| loading | yes | recording (circle) |
| loaded | no | idle (waveform) |
| loaded | yes, Recording | recording (circle) |
| loaded | yes, Transcribing+ | processing (dots) |
| error | no | idle (waveform) + error in menu |

### Actions (all sync)

```swift
@MainActor
final class AppStateMachine: ObservableObject {
    @Published private(set) var state: AppState = .noModel
    private var loadTask: Task<Void, Never>?
    private var idleTimer: Timer?
    private let modelManager: ModelManager
    private let transcriber: Transcriber
    private let unloadTimeout: TimeInterval  // from UserDefaults

    // Called once at launch
    func start() {
        transition(to: .noModel)
        evaluate()
    }

    // Re-evaluate disk state and advance
    private func evaluate() {
        guard case .noModel = state else { return }
        if modelExistsOnDisk() {
            transition(to: .ready)
        } else {
            transition(to: .downloading)
            loadTask = Task { [weak self] in
                do {
                    _ = try await self?.modelManager.modelURL(for: AppConfig.model)
                    await MainActor.run { self?.onDownloadComplete() }
                } catch {
                    await MainActor.run { self?.onDownloadFailed(error) }
                }
            }
        }
    }

    private func onDownloadComplete() {
        loadTask = nil
        transition(to: .ready)
    }

    private func onDownloadFailed(_ error: Error) {
        loadTask = nil
        transition(to: .error(error.localizedDescription))
    }

    // Called when a recording needs the model in memory
    func requestModelLoad() {
        switch state {
        case .ready:
            transition(to: .loading)
            loadTask = Task { [weak self] in
                do {
                    try await self?.transcriber.preloadAndWait(model: AppConfig.model)
                    await MainActor.run { self?.onLoadComplete() }
                } catch {
                    await MainActor.run { self?.onLoadFailed(error) }
                }
            }
        case .loaded:
            resetIdleTimer()
        case .loading:
            break  // already loading
        default:
            break  // noModel, downloading, error — recording shouldn't exist
        }
    }

    private func onLoadComplete() {
        loadTask = nil
        transition(to: .loaded)
        resetIdleTimer()
    }

    private func onLoadFailed(_ error: Error) {
        loadTask = nil
        transition(to: .error(error.localizedDescription))
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: unloadTimeout, repeats: false) {
            [weak self] _ in
            self?.unloadModel()
        }
    }

    private func unloadModel() {
        idleTimer = nil
        transcriber.unload()
        transition(to: .ready)
    }

    func retry() {
        guard case .error = state else { return }
        transition(to: .noModel)
        evaluate()
    }

    func cleanCache() {
        loadTask?.cancel()
        loadTask = nil
        idleTimer?.invalidate()
        idleTimer = nil
        transcriber.unload()
        try? modelManager.cleanCache()
        transition(to: .noModel)
        evaluate()
    }

    private func transition(to newState: AppState) {
        state = newState
        // Icon update driven by @Published state + recording state
    }

    private func modelExistsOnDisk() -> Bool {
        let filename = "ggml-\(AppConfig.model).bin"
        let url = modelManager.modelsDir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
```

## Recording State Machine

### States

```swift
enum RecordingState: Equatable {
    case recording        // mic capturing
    case waitingForModel  // mic done, app not yet loaded
    case transcribing     // whisper running
    case pasting          // clipboard + Cmd+V
    case done             // discard
}
```

### Transitions

```
(created) → recording
recording (shortcut, app loaded) → transcribing
recording (shortcut, app not loaded) → waitingForModel
waitingForModel (app loaded) → transcribing
waitingForModel (app error) → done
transcribing (text produced) → pasting
transcribing (empty/error) → done
pasting (clipboard restored) → done
```

### Actions (all sync)

```swift
@MainActor
final class RecordingSession {
    private(set) var state: RecordingState = .recording
    private var audioRecorder: AVAudioRecorder?
    private var audioURL: URL?
    private var transcribeTask: Task<Void, Never>?
    private let transcriber: Transcriber
    private let onDone: () -> Void  // callback to clear from app

    init(transcriber: Transcriber, saveDir: String, onDone: @escaping () -> Void) {
        self.transcriber = transcriber
        self.onDone = onDone
        startMic(saveDir: saveDir)
    }

    // User pressed shortcut to stop
    func stop(appState: AppState) {
        guard state == .recording else { return }
        stopMic()
        if case .loaded = appState {
            startTranscribing()
        } else {
            transition(to: .waitingForModel)
        }
    }

    // Called by app when it reaches .loaded
    func onModelLoaded() {
        guard state == .waitingForModel else { return }
        startTranscribing()
    }

    // Called by app when it reaches .error
    func onModelError() {
        guard state == .waitingForModel else { return }
        transition(to: .done)
    }

    // MARK: - Sync actions

    private func startMic(saveDir: String) {
        let url = // ... build URL with timestamp
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.record()
        audioURL = url
        NSSound(named: .init("Tink"))?.play()
    }

    private func stopMic() {
        audioRecorder?.stop()
        audioRecorder = nil
        NSSound(named: .init("Pop"))?.play()
    }

    private func startTranscribing() {
        transition(to: .transcribing)
        guard let url = audioURL else {
            transition(to: .done)
            return
        }
        transcribeTask = Task { [weak self] in
            do {
                let text = try await transcriber.transcribe(
                    audioFileURL: url, model: AppConfig.model
                )
                await MainActor.run {
                    if text.isEmpty {
                        self?.transition(to: .done)
                    } else {
                        self?.startPasting(text)
                    }
                }
            } catch {
                await MainActor.run { self?.transition(to: .done) }
            }
        }
    }

    private func startPasting(_ text: String) {
        transition(to: .pasting)
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore clipboard after delay, then done
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
            self?.transition(to: .done)
        }
    }

    private func transition(to newState: RecordingState) {
        state = newState
        if newState == .done {
            if let url = audioURL {
                try? FileManager.default.removeItem(at: url)
            }
            onDone()
        }
    }
}
```

## Coordinator

Glues the two state machines together and handles shortcut input:

```swift
@MainActor
final class AppCoordinator {
    let app: AppStateMachine
    var recording: RecordingSession?

    func handleShortcut() {
        if let recording {
            // Stop current recording
            recording.stop(appState: app.state)
        } else if case .error = app.state {
            // Error state — shortcut ignored, use menu bar Retry
            return
        } else {
            // Start new recording
            app.requestModelLoad()
            recording = RecordingSession(transcriber: app.transcriber, saveDir: NSTemporaryDirectory()) { [weak self] in
                self?.recording = nil
                self?.app.resetIdleTimer()
            }
        }
    }

    // Called when app state changes
    func onAppStateChanged(_ newState: AppState) {
        switch newState {
        case .loaded:
            recording?.onModelLoaded()
        case .error:
            recording?.onModelError()
        default:
            break
        }
        updateIcon()
    }

    func updateIcon() {
        if let recording {
            switch recording.state {
            case .recording: setIcon(.recording)
            case .waitingForModel, .transcribing, .pasting: setIcon(.processing)
            case .done: setIcon(.idle)
            }
        } else {
            switch app.state {
            case .noModel, .downloading, .loading: setIcon(.processing)
            case .ready, .loaded: setIcon(.idle)
            case .error: setIcon(.idle)  // error shown in menu text
            }
        }
    }
}
```

## Config

New UserDefaults key:
- `unloadTimeout` — seconds before unloading model from memory (default: `300`)

## Testability

Each state machine is a plain Swift class with sync transitions. Tests can:
- Create `AppStateMachine`, call `start()`, assert state sequence
- Create `RecordingSession`, call `stop()`, assert transitions
- Mock `Transcriber` and `ModelManager` — no AppKit, no mic, no network
- Test coordinator shortcut handling with different app/recording state combinations

## Files

| File | Action | Responsibility |
|---|---|---|
| `Sources/SpeakCleanCore/AppStateMachine.swift` | Create | App state machine |
| `Sources/SpeakCleanCore/RecordingSession.swift` | Create | Recording state machine |
| `Sources/speak-clean/AppCoordinator.swift` | Create | Glue + shortcut handling + icon |
| `Sources/speak-clean/speak_clean.swift` | Modify | Simplify to create coordinator |
| `Sources/SpeakCleanCore/Transcriber.swift` | Modify | Add `unload()` and `preloadAndWait()` |
| `Tests/SpeakCleanTests/AppStateMachineTests.swift` | Create | App state transition tests |
| `Tests/SpeakCleanTests/RecordingSessionTests.swift` | Create | Recording state transition tests |
