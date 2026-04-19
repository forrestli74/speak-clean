import Foundation
import AVFoundation
import Speech
import FoundationModels

protocol AvailabilityChecker: Sendable {
    func check() async -> AppController.State
}

/// Production checker. Runs availability checks in order: Apple Intelligence,
/// microphone permission, locale support, STT asset install. Any failure short-
/// circuits and returns `.notReady(reason:)` with a user-facing message.
struct DefaultAvailabilityChecker: AvailabilityChecker {
    func check() async -> AppController.State {
        // 1. Apple Intelligence (Foundation Models)
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            return .notReady(reason: "This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notReady(reason: "Turn on Apple Intelligence in System Settings.")
        case .unavailable(.modelNotReady):
            return .notReady(reason: "Apple Intelligence is still setting up. Try again shortly.")
        case .unavailable(let other):
            return .notReady(reason: "Apple Intelligence unavailable: \(other).")
        }

        // 2. Microphone permission
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            return .notReady(reason: "Microphone permission denied. Grant it in System Settings.")
        }

        // 3. Locale support
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            return .notReady(reason: "Dictation doesn't support your locale (\(Locale.current.identifier)).")
        }

        // 4. STT assets
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return .notReady(reason: "Could not install dictation assets: \(error.localizedDescription).")
        }

        return .ready
    }
}
