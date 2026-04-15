import Testing
@testable import speak_clean

@Suite("ManagedModel")
struct ManagedModelTests {
    @Test @MainActor func loadSetsInstance() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "loaded" }
        try await model.waitUntilReady()
        #expect(model.instance == "loaded")
    }

    @Test @MainActor func loadIsNoOpWhenAlreadyLoaded() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "first" }
        try await model.waitUntilReady()
        model.load { "second" }
        try await model.waitUntilReady()
        #expect(model.instance == "first")
    }

    @Test @MainActor func loadIsNoOpWhileLoading() async throws {
        let model = ManagedModel<Int>(name: "test")
        var callCount = 0
        model.load {
            callCount += 1
            return 42
        }
        model.load {
            callCount += 1
            return 99
        }
        try await model.waitUntilReady()
        #expect(model.instance == 42)
        #expect(callCount == 1)
    }

    @Test @MainActor func unloadNilsInstance() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "loaded" }
        try await model.waitUntilReady()
        model.unload()
        #expect(model.instance == nil)
    }

    @Test @MainActor func unloadAllowsReload() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "first" }
        try await model.waitUntilReady()
        model.unload()
        model.load { "second" }
        try await model.waitUntilReady()
        #expect(model.instance == "second")
    }

    @Test @MainActor func waitUntilReadyWithNoLoadIsNoOp() async throws {
        let model = ManagedModel<String>(name: "test")
        try await model.waitUntilReady()
        #expect(model.instance == nil)
    }

    @Test @MainActor func scheduleUnloadNilsInstanceAfterDelay() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "loaded" }
        try await model.waitUntilReady()
        model.scheduleUnload(delay: 0.05)
        // Wait for timer to fire
        try await Task.sleep(nanoseconds: 150_000_000)  // 150ms
        #expect(model.instance == nil)
    }

    @Test @MainActor func cancelUnloadPreventsUnload() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "loaded" }
        try await model.waitUntilReady()
        model.scheduleUnload(delay: 0.05)
        model.cancelUnload()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(model.instance == "loaded")
    }

    @Test @MainActor func unloadCancelsPendingTimer() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "loaded" }
        try await model.waitUntilReady()
        model.scheduleUnload(delay: 0.05)
        model.unload()
        #expect(model.instance == nil)
        // Reload and verify timer doesn't interfere
        model.load { "reloaded" }
        try await model.waitUntilReady()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(model.instance == "reloaded")
    }

    @Test @MainActor func loadAfterTimerUnloadWorks() async throws {
        let model = ManagedModel<String>(name: "test")
        model.load { "first" }
        try await model.waitUntilReady()
        model.scheduleUnload(delay: 0.05)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(model.instance == nil)
        // Should be able to reload
        model.load { "second" }
        try await model.waitUntilReady()
        #expect(model.instance == "second")
    }
}
