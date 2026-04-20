import Foundation
import AVFoundation
import Speech
import SpeakCleanCore

/// Production availability checker for `AppController`.
///
/// Runs checks in fixed order; the first one that fails short-circuits
/// with a user-facing `reason`:
///
/// 1. Ollama reachable at `localhost:11434` — HTTP GET to `/api/tags`.
/// 2. The configured cleanup model is pulled.
/// 3. `AVCaptureDevice.requestAccess(for: .audio)` — microphone
///    permission (prompts the user on first run).
/// 4. `DictationTranscriber.supportedLocale(equivalentTo:)` — whether
///    the user's system locale has dictation assets available.
/// 5. `AssetInventory.assetInstallationRequest(supporting:)` — if the
///    STT assets aren't installed, download them (this can block on
///    the first run on a fresh OS install).
///
/// Returns `.ready` only if all checks pass. Called on launch and from
/// the "Reset" menu action. `cleanupModel` should be the value of
/// `AppConfig.cleanupModel` at check time, passed in so this function
/// stays off the main actor.
func runAvailabilityChecks(cleanupModel: String) async -> AppController.State {
    // 1. + 2. Ollama + model
    switch await ollamaStatus(model: cleanupModel) {
    case .ok:
        break
    case .unreachable:
        return .notReady(reason: "Ollama isn't running. Run: brew services start ollama")
    case .missingModel:
        return .notReady(reason: "Model isn't installed. Run: ollama pull \(cleanupModel)")
    case .error(let reason):
        return .notReady(reason: "Ollama check failed: \(reason)")
    }

    // 3. Microphone permission
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
        return .notReady(reason: "Microphone permission denied. Grant it in System Settings.")
    }

    // 4. Locale support
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
        return .notReady(reason: "Dictation doesn't support your locale (\(Locale.current.identifier)).")
    }

    // 5. STT assets
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

// MARK: - Ollama probe

/// Outcome of probing the local Ollama server.
enum OllamaStatus {
    /// Server responded and the configured model is in the pulled list.
    case ok
    /// Server didn't answer (not installed, not running, or wrong port).
    case unreachable
    /// Server answered but the configured model isn't pulled.
    case missingModel
    /// Server answered but returned unexpected data.
    case error(reason: String)
}

/// Hits Ollama's `/api/tags` endpoint and verifies the given model tag
/// appears in the listed tags. Used only by `runAvailabilityChecks`.
func ollamaStatus(model: String) async -> OllamaStatus {
    let url = URL(string: "http://localhost:11434/api/tags")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 5

    let data: Data
    do {
        (data, _) = try await URLSession.shared.data(for: request)
    } catch {
        return .unreachable
    }

    struct Tags: Decodable {
        let models: [Entry]
        struct Entry: Decodable { let name: String }
    }
    do {
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        let names = tags.models.map(\.name)
        // Match the configured tag exactly.
        if names.contains(model) {
            return .ok
        }
        return .missingModel
    } catch {
        return .error(reason: error.localizedDescription)
    }
}
