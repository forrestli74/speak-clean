import AVFoundation
import SwiftWhisper

public final class Transcriber: @unchecked Sendable {
    private let modelManager: ModelManager
    private let cleaner = TextCleaner()
    private var whisper: Whisper?
    private var currentModel: String?

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    public func preload(model: String) async throws {
        let url = try await modelManager.modelURL(for: model)
        var params = WhisperParams(strategy: .greedy)
        params.language = .english
        // Use half the cores — CoreML handles encoder on ANE, threads are for decoder only
        params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
        params.print_progress = false
        params.print_timestamps = false
        whisper = Whisper(fromFileURL: url, withParams: params)
        currentModel = model
        print("Model loaded: ggml-\(model).bin (threads: \(params.n_threads))")
    }

    public func transcribe(audioFileURL: URL, model: String) async throws -> String {
        var t = CFAbsoluteTimeGetCurrent()

        // Reload model if changed or first use
        if whisper == nil || currentModel != model {
            try await preload(model: model)
            fputs("  model load: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s\n", stderr)
            t = CFAbsoluteTimeGetCurrent()
        }

        let audioFrames = try loadAudioFrames(from: audioFileURL)
        fputs("  audio load:  \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s\n", stderr)
        t = CFAbsoluteTimeGetCurrent()

        guard let whisper else { throw TranscriberError.modelNotLoaded }
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        fputs("  transcribe:  \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s\n", stderr)

        let rawText = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        guard !rawText.isEmpty else { return "" }
        return cleaner.clean(rawText)
    }

    private func loadAudioFrames(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriberError.audioFormatError
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriberError.audioBufferError
        }

        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw TranscriberError.audioBufferError
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }
}

public enum TranscriberError: Error, LocalizedError {
    case audioFormatError
    case audioBufferError
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .audioFormatError: return "Failed to create audio format"
        case .audioBufferError: return "Failed to read audio buffer"
        case .modelNotLoaded: return "Whisper model not loaded"
        }
    }
}
