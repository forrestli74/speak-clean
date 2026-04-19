import Foundation

@MainActor
final class ManagedModel<T: AnyObject> {
    enum Status: Equatable {
        case unloaded
        case loading
        case idle
        case inUse(scopes: Int)
    }

    private let name: String
    private let idleDelayProvider: () -> TimeInterval
    private let loader: @MainActor () async throws -> T

    private var instance: T?
    private var loadTask: Task<Void, Error>?
    private var generation = 0
    private var activeScopes = 0
    private var unloadWorkItem: DispatchWorkItem?

    private(set) var status: Status = .unloaded

    init(
        name: String,
        idleDelay: @escaping () -> TimeInterval,
        loader: @escaping @MainActor () async throws -> T
    ) {
        self.name = name
        self.idleDelayProvider = idleDelay
        self.loader = loader
    }

    /// The only way to USE the model. Loads (or joins an in-flight load)
    /// before calling `body`. Caller's reference is ARC-pinned for the
    /// duration — never nil, never stale. Body runs on the main actor
    /// (consistent with how whisper.cpp is invoked elsewhere).
    func withModel<R>(_ body: @MainActor (T) async throws -> R) async throws -> R {
        cancelIdleTimer()
        activeScopes += 1
        updateStatus()
        defer {
            activeScopes -= 1
            updateStatus()
            if activeScopes == 0 { armIdleUnload() }
        }

        let model = try await ensureLoaded()
        return try await body(model)
    }

    /// Advisory: start loading in the background without opening a scope.
    /// No-op if already loaded or loading. Errors are swallowed; next
    /// `withModel` retries.
    func prewarm() {
        guard instance == nil, loadTask == nil else { return }
        startLoad()
    }

    /// Wait for active scopes to finish, then unload. Cancels any pending
    /// idle timer and any in-flight prewarm load.
    func unloadWhenIdle() async {
        cancelIdleTimer()
        while activeScopes > 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        cancelIdleTimer()
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        instance = nil
        updateStatus()
    }

    // MARK: - Private

    private func ensureLoaded() async throws -> T {
        if let instance { return instance }
        let task = loadTask ?? startLoad()

        try await task.value

        if let instance { return instance }
        // Load completed but was invalidated before it could publish
        // (e.g. unloadWhenIdle ran between completion and resume). Retry.
        let retry = startLoad()
        try await retry.value
        guard let instance else {
            throw ManagedModelError.loadInvalidated
        }
        return instance
    }

    @discardableResult
    private func startLoad() -> Task<Void, Error> {
        generation &+= 1
        let myGen = generation
        let task = Task { @MainActor in
            do {
                let value = try await self.loader()
                guard self.generation == myGen else { return }
                self.instance = value
                self.loadTask = nil
                self.updateStatus()
                print("\(self.name) loaded to memory")
            } catch {
                // Clear loadTask on failure so the next ensureLoaded retries.
                if self.generation == myGen {
                    self.loadTask = nil
                    self.updateStatus()
                }
                throw error
            }
        }
        loadTask = task
        status = .loading
        print("\(self.name) loading into memory")
        return task
    }

    private func armIdleUnload() {
        cancelIdleTimer()
        guard instance != nil else { return }
        let delay = idleDelayProvider()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.activeScopes == 0, self.instance != nil else { return }
                self.generation &+= 1
                self.instance = nil
                self.loadTask?.cancel()
                self.loadTask = nil
                self.unloadWorkItem = nil
                self.updateStatus()
                print("\(self.name) unloaded (idle timeout)")
            }
        }
        unloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelIdleTimer() {
        unloadWorkItem?.cancel()
        unloadWorkItem = nil
    }

    private func updateStatus() {
        if activeScopes > 0 {
            status = .inUse(scopes: activeScopes)
        } else if instance != nil {
            status = .idle
        } else if loadTask != nil {
            status = .loading
        } else {
            status = .unloaded
        }
    }
}

enum ManagedModelError: Error {
    case loadInvalidated
}
