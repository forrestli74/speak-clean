import Testing
import Foundation
@testable import speak_clean

private final class Box {
    let id: Int
    init(_ id: Int) { self.id = id }
}

/// Gate that holds a loader until `release()` is called. Used to arrange
/// specific interleavings between load, scope entry/exit, and unload.
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { cont in continuations.append(cont) }
    }
    func release() {
        for c in continuations { c.resume() }
        continuations.removeAll()
    }
}

@Suite("ManagedModel")
struct ManagedModelTests {

    @Test @MainActor func withModelLoadsOnFirstUse() async throws {
        var calls = 0
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            calls += 1
            return Box(calls)
        }
        let id = try await m.withModel { $0.id }
        #expect(id == 1)
        #expect(m.status == .idle)
    }

    @Test @MainActor func withModelReusesLoadedInstance() async throws {
        var calls = 0
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            calls += 1
            return Box(calls)
        }
        _ = try await m.withModel { $0.id }
        _ = try await m.withModel { $0.id }
        #expect(calls == 1)
    }

    @Test @MainActor func concurrentScopesShareSingleLoad() async throws {
        var calls = 0
        let gate = Gate()
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            calls += 1
            await gate.wait()
            return Box(calls)
        }

        async let a = m.withModel { $0.id }
        async let b = m.withModel { $0.id }
        // Yield so both scopes are entered and awaiting the same load.
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.release()
        let (idA, idB) = try await (a, b)
        #expect(idA == idB)
        #expect(calls == 1)
    }

    @Test @MainActor func idleTimerUnloadsAfterDelay() async throws {
        let m = ManagedModel<Box>(name: "t", idleDelay: { 0.05 }) { Box(1) }
        _ = try await m.withModel { $0.id }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(m.status == .unloaded)
    }

    @Test @MainActor func reenteringScopeCancelsIdleTimer() async throws {
        // Long idleDelay so we can verify the pending timer from the first
        // exit doesn't force-unload while we're verifying.
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) { Box(1) }
        _ = try await m.withModel { $0.id }
        // Re-enter before timer could possibly fire.
        _ = try await m.withModel { $0.id }
        #expect(m.status == .idle)
    }

    @Test @MainActor func idleTimerOnlyArmsWhenLastScopeExits() async throws {
        let m = ManagedModel<Box>(name: "t", idleDelay: { 0.05 }) { Box(1) }
        let gate = Gate()

        let outer = Task { @MainActor in
            try await m.withModel { _ in
                await gate.wait()
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        // Enter a second scope while the first holds.
        _ = try await m.withModel { $0.id }
        // First still active → idle timer must NOT have unloaded us.
        #expect(m.status == .inUse(scopes: 1))
        await gate.release()
        try await outer.value
        // Now both scopes have exited; timer armed, wait for it.
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(m.status == .unloaded)
    }

    @Test @MainActor func loaderFailurePropagatesAndRetriesOnNextCall() async throws {
        var calls = 0
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            calls += 1
            if calls == 1 { throw CancellationError() }
            return Box(calls)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await m.withModel { $0.id }
        }
        let id = try await m.withModel { $0.id }
        #expect(id == 2)
        #expect(calls == 2)
    }

    @Test @MainActor func unloadWhenIdleWaitsForActiveScope() async throws {
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) { Box(1) }
        let gate = Gate()

        let body = Task { @MainActor in
            try await m.withModel { _ in await gate.wait() }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(m.status == .inUse(scopes: 1))

        var unloadDone = false
        let unload = Task { @MainActor in
            await m.unloadWhenIdle()
            unloadDone = true
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(unloadDone == false)  // blocked on active scope

        await gate.release()
        try await body.value
        await unload.value
        #expect(unloadDone == true)
        #expect(m.status == .unloaded)
    }

    @Test @MainActor func unloadWhenIdleCancelsIdleTimer() async throws {
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) { Box(1) }
        _ = try await m.withModel { $0.id }
        #expect(m.status == .idle)
        await m.unloadWhenIdle()
        #expect(m.status == .unloaded)
    }

    @Test @MainActor func unloadWhenIdleDuringLoadDoesNotResurrect() async throws {
        let gate = Gate()
        var loadSucceeded = false
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            await gate.wait()
            loadSucceeded = true
            return Box(1)
        }

        // Start a prewarm that will block on the gate.
        m.prewarm()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(m.status == .loading)

        // Unload while the load is mid-flight.
        let unload = Task { @MainActor in await m.unloadWhenIdle() }
        try await Task.sleep(nanoseconds: 30_000_000)

        // Now let the loader complete. Its write should be invalidated.
        await gate.release()
        await unload.value
        // Loader may have completed its body, but instance must not have
        // been published.
        #expect(m.status == .unloaded)
        _ = loadSucceeded  // silence unused warning
    }

    @Test @MainActor func prewarmIsNoOpIfAlreadyLoaded() async throws {
        var calls = 0
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            calls += 1
            return Box(calls)
        }
        _ = try await m.withModel { $0.id }
        m.prewarm()
        m.prewarm()
        _ = try await m.withModel { $0.id }
        #expect(calls == 1)
    }

    @Test @MainActor func prewarmJoinedByWithModel() async throws {
        var calls = 0
        let gate = Gate()
        let m = ManagedModel<Box>(name: "t", idleDelay: { 60 }) {
            calls += 1
            await gate.wait()
            return Box(calls)
        }
        m.prewarm()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(m.status == .loading)
        async let result = m.withModel { $0.id }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.release()
        let id = try await result
        #expect(id == 1)
        #expect(calls == 1)
    }
}
