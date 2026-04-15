import Foundation
import SwiftWhisper
import SpeakCleanCore

@MainActor
final class AppController {
    enum State {
        case notReady
        case ready
        case busy
        case error(Error)
    }

    private(set) var state: State = .notReady
    let whisper = ManagedModel<Whisper>(name: "whisper")

    private var downloadTask: Task<Void, Error>?
    private var loadedModelName: String?

    private let modelManager: ModelManager
    let transcriber = Transcriber()
    var onStateChange: ((State) -> Void)?

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    // MARK: - Actions

    /// Reload config, download model files. Not allowed in busy.
    func reset() {
        switch state {
        case .busy: return
        case .notReady:
            downloadTask?.cancel()
            downloadTask = nil
            whisper.unload()
        case .ready:
            whisper.unload()
            transition(to: .notReady)
        case .error:
            whisper.unload()
            transition(to: .notReady)
        }

        let modelName = AppConfig.model
        loadedModelName = modelName
        downloadTask = Task { [self] in
            _ = try await modelManager.modelURL(for: modelName)
            self.transition(to: .ready)
            print("Model files ready: ggml-\(modelName).bin")
        }
    }

    /// Wait for download task to complete. For testing.
    func waitForDownload() async throws {
        try await downloadTask?.value
    }

    /// Delete model files on disk. Not allowed in busy.
    func clearCache() throws {
        switch state {
        case .busy: return
        default: break
        }
        downloadTask?.cancel()
        downloadTask = nil
        whisper.unload()
        loadedModelName = nil
        try modelManager.cleanCache()
        transition(to: .notReady)
    }

    /// Enter busy state. Load models to memory. Only from ready.
    func markBusy() -> Bool {
        guard case .ready = state else { return false }
        whisper.cancelUnload()

        let modelName = loadedModelName ?? AppConfig.model
        whisper.load { [self] in
            let url = try await modelManager.modelURL(for: modelName)
            var params = WhisperParams(strategy: .greedy)
            params.language = .english
            params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
            params.print_progress = false
            params.print_timestamps = false
            return Whisper(fromFileURL: url, withParams: params)
        }

        transition(to: .busy)
        return true
    }

    /// Return to ready after transcription. Starts per-model unload timers.
    func markDone() {
        let delay = AppConfig.modelUnloadDelay
        whisper.scheduleUnload(delay: delay)
        transition(to: .ready)
    }

    func markError(_ error: Error) {
        whisper.unload()
        transition(to: .error(error))
    }

    // MARK: - Private

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}
