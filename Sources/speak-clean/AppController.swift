import Foundation
import SwiftWhisper
import SpeakCleanCore

@MainActor
final class AppController {
    enum State {
        case notReady
        case ready
        case error(Error)
    }

    private(set) var state: State = .notReady
    private(set) var pinnedModelName: String?

    private var downloadTask: Task<Void, Error>?
    private let modelManager: ModelManager
    let transcriber = Transcriber()
    var onStateChange: ((State) -> Void)?
    private(set) var whisper: ManagedModel<Whisper>!

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.whisper = ManagedModel(
            name: "whisper",
            idleDelay: { AppConfig.modelUnloadDelay },
            loader: { [unowned self] in
                let name = self.pinnedModelName ?? AppConfig.model
                let url = try await self.modelManager.modelURL(for: name)
                var params = WhisperParams(strategy: .greedy)
                params.language = .english
                params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
                params.print_progress = false
                params.print_timestamps = false
                return Whisper(fromFileURL: url, withParams: params)
            }
        )
    }

    // MARK: - Actions

    /// Reload config, download model files. Unloads any in-memory model
    /// when scopes drain, so the next `withModel` loads the current name.
    func reset() {
        downloadTask?.cancel()
        downloadTask = nil

        let newModelName = AppConfig.model
        let shouldUnload = pinnedModelName != nil
        pinnedModelName = newModelName

        switch state {
        case .notReady: break
        case .ready, .error: transition(to: .notReady)
        }

        downloadTask = Task { [self] in
            if shouldUnload {
                await whisper.unloadWhenIdle()
            }
            _ = try await modelManager.modelURL(for: newModelName)
            self.transition(to: .ready)
            print("Model files ready: ggml-\(newModelName).bin")
        }
    }

    /// Wait for the current download to complete. For testing.
    func waitForDownload() async throws {
        try await downloadTask?.value
    }

    /// Delete model files on disk. Waits for any in-flight scope to finish.
    func clearCache() async throws {
        downloadTask?.cancel()
        downloadTask = nil
        await whisper.unloadWhenIdle()
        pinnedModelName = nil
        try modelManager.cleanCache()
        transition(to: .notReady)
    }

    /// Record a fatal error. Does not force-unload — any in-flight scope
    /// completes normally; the idle timer will unload afterward.
    func markError(_ error: Error) {
        transition(to: .error(error))
    }

    // MARK: - Private

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}
