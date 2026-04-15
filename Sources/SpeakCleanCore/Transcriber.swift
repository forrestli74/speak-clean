import AVFoundation
import SwiftWhisper

public final class Transcriber: @unchecked Sendable {
    private let cleaner = TextCleaner()

    public init() {}

    public func transcribe(whisper: Whisper, audioFileURL: URL) async throws -> String {
        var t = CFAbsoluteTimeGetCurrent()

        let audioFrames = try loadAudioFrames(from: audioFileURL)
        fputs("  audio load:  \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))s\n", stderr)
        t = CFAbsoluteTimeGetCurrent()

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

        let frameCount = AVAudioFrameCount(Double(file.length) * 16000.0 / file.fileFormat.sampleRate)
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
