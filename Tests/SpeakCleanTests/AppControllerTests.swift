import Testing
import Foundation
@testable import SpeakCleanCore
@testable import speak_clean

@Suite("AppController", .serialized)
struct AppControllerTests {
    /// Creates a temp dir with a fake model file so ModelManager.modelURL() returns without downloading.
    private func makeTempModelsDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Place fake GGML file
        let modelFile = tmp.appendingPathComponent("ggml-base.en.bin")
        try Data("fake-model".utf8).write(to: modelFile)
        // Place fake CoreML dir
        let coremlDir = tmp.appendingPathComponent("ggml-base.en-encoder.mlmodelc")
        try FileManager.default.createDirectory(at: coremlDir, withIntermediateDirectories: true)
        return tmp
    }

    @Test @MainActor func startsInNotReady() throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        guard case .notReady = controller.state else {
            Issue.record("Expected .notReady, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func resetTransitionsToReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        guard case .ready = controller.state else {
            Issue.record("Expected .ready, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func markBusyOnlyFromReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))

        // notReady → markBusy should fail
        #expect(controller.markBusy() == false)

        controller.reset()
        try await controller.waitForDownload()

        // ready → markBusy should succeed
        #expect(controller.markBusy() == true)
        guard case .busy = controller.state else {
            Issue.record("Expected .busy, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func markDoneTransitionsToReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        controller.markDone()
        guard case .ready = controller.state else {
            Issue.record("Expected .ready, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func resetRejectedDuringBusy() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        controller.reset()
        guard case .busy = controller.state else {
            Issue.record("Expected .busy, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func clearCacheRejectedDuringBusy() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        try controller.clearCache()
        guard case .busy = controller.state else {
            Issue.record("Expected .busy, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func clearCacheTransitionsToNotReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        try controller.clearCache()
        guard case .notReady = controller.state else {
            Issue.record("Expected .notReady, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func markBusyRejectedDuringBusy() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        #expect(controller.markBusy() == true)
        #expect(controller.markBusy() == false)
    }

    @Test @MainActor func markErrorTransitionsToError() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        controller.markError(TranscriberError.modelNotLoaded)
        guard case .error = controller.state else {
            Issue.record("Expected .error, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func markBusyRejectedInError() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        controller.markError(TranscriberError.modelNotLoaded)
        #expect(controller.markBusy() == false)
    }

    @Test @MainActor func resetFromErrorTransitionsToReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        controller.markError(TranscriberError.modelNotLoaded)
        controller.reset()
        try await controller.waitForDownload()
        guard case .ready = controller.state else {
            Issue.record("Expected .ready, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func resetFromReadyTransitionsBackToReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        guard case .ready = controller.state else {
            Issue.record("Expected .ready after first reset")
            return
        }
        controller.reset()
        try await controller.waitForDownload()
        guard case .ready = controller.state else {
            Issue.record("Expected .ready after second reset")
            return
        }
    }

    @Test @MainActor func clearCacheFromNotReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try controller.clearCache()
        guard case .notReady = controller.state else {
            Issue.record("Expected .notReady, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func onStateChangeCallbackFires() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        var states: [String] = []
        controller.onStateChange = { state in
            switch state {
            case .notReady: states.append("notReady")
            case .ready: states.append("ready")
            case .busy: states.append("busy")
            case .error: states.append("error")
            }
        }
        controller.reset()
        try await controller.waitForDownload()
        _ = controller.markBusy()
        controller.markDone()
        #expect(states == ["ready", "busy", "ready"])
    }
}
