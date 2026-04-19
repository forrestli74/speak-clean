import Testing
import Foundation
@testable import SpeakCleanCore
@testable import speak_clean

@Suite("AppController", .serialized)
struct AppControllerTests {
    private func makeTempModelsDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let modelFile = tmp.appendingPathComponent("ggml-base.en.bin")
        try Data("fake-model".utf8).write(to: modelFile)
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

    @Test @MainActor func clearCacheTransitionsToNotReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        try await controller.clearCache()
        guard case .notReady = controller.state else {
            Issue.record("Expected .notReady, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func markErrorTransitionsToError() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        controller.markError(TranscriberError.modelNotLoaded)
        guard case .error = controller.state else {
            Issue.record("Expected .error, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func resetFromErrorTransitionsToReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
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
        controller.reset()
        try await controller.waitForDownload()
        guard case .ready = controller.state else {
            Issue.record("Expected .ready, got \(controller.state)")
            return
        }
    }

    @Test @MainActor func clearCacheFromNotReady() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.clearCache()
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
            case .error: states.append("error")
            }
        }
        controller.reset()
        try await controller.waitForDownload()
        controller.markError(TranscriberError.modelNotLoaded)
        #expect(states == ["ready", "error"])
    }

    @Test @MainActor func pinnedModelNameRecordedOnReset() async throws {
        let tmp = try makeTempModelsDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let controller = AppController(modelManager: ModelManager(modelsDir: tmp))
        controller.reset()
        try await controller.waitForDownload()
        #expect(controller.pinnedModelName == "base.en")
    }
}
