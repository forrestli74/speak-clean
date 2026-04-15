import Foundation

@MainActor
final class ManagedModel<T> {
    private(set) var instance: T?
    private var loadTask: Task<Void, Error>?
    private var unloadWorkItem: DispatchWorkItem?
    private let name: String

    init(name: String) {
        self.name = name
    }

    /// Load model into memory. No-op if already loaded or loading.
    func load(_ loader: @escaping () async throws -> T) {
        guard instance == nil, loadTask == nil else { return }
        loadTask = Task {
            self.instance = try await loader()
            print("\(self.name) loaded to memory")
        }
    }

    /// Wait for in-flight load to finish.
    func waitUntilReady() async throws {
        try await loadTask?.value
    }

    /// Start unload timer. Cancels any existing timer.
    func scheduleUnload(delay: TimeInterval) {
        unloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.instance = nil
                self.loadTask = nil
                self.unloadWorkItem = nil
                print("\(self.name) unloaded (idle timeout)")
            }
        }
        unloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cancel pending unload timer.
    func cancelUnload() {
        unloadWorkItem?.cancel()
        unloadWorkItem = nil
    }

    /// Immediately unload: cancel timer, cancel load, nil instance.
    func unload() {
        unloadWorkItem?.cancel()
        unloadWorkItem = nil
        loadTask?.cancel()
        loadTask = nil
        instance = nil
    }
}
