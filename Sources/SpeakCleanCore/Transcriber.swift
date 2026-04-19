import AVFoundation
import Speech

@MainActor
public final class Transcriber {

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedLocale(Locale)
        case alreadyRecording
        case notRecording
        case engineStartFailed(Swift.Error)
        case formatUnavailable

        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let l): return "Unsupported locale: \(l.identifier)"
            case .alreadyRecording: return "Recording already in progress"
            case .notRecording: return "No recording in progress"
            case .engineStartFailed(let e): return "Audio engine failed: \(e.localizedDescription)"
            case .formatUnavailable: return "Could not determine audio format"
            }
        }
    }

    private var session: Session?

    public init() {}

    /// Begin streaming recognition. Captures microphone audio via
    /// `AVAudioEngine`, feeds it to a `SpeechAnalyzer` session, and
    /// accumulates final results. Call `stop()` to finalize and retrieve text.
    public func start() async throws {
        guard session == nil else { throw Error.alreadyRecording }

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw Error.unsupportedLocale(Locale.current)
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Error.formatUnavailable
        }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let engine = AVAudioEngine()
        let hwFormat = engine.inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [inputBuilder] buffer, _ in
            guard let converter else {
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
            var consumed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if err == nil {
                inputBuilder.yield(AnalyzerInput(buffer: out))
            }
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            inputBuilder.finish()
            throw Error.engineStartFailed(error)
        }

        let buffer = TextBuffer()
        let resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results where result.isFinal {
                    buffer.text += String(result.text.characters)
                }
            } catch {
                // Errors propagate via analyzerTask; swallow here.
            }
        }

        let analyzerTask: Task<AVAudioTime?, Swift.Error> = Task {
            try await analyzer.analyzeSequence(inputSequence)
        }

        session = Session(
            analyzer: analyzer,
            transcriber: transcriber,
            engine: engine,
            inputBuilder: inputBuilder,
            resultsTask: resultsTask,
            analyzerTask: analyzerTask,
            buffer: buffer
        )
    }

    /// Stop recording, finalize the session, and return the accumulated text.
    public func stop() async throws -> String {
        guard let s = session else { throw Error.notRecording }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()

        let lastSampleTime = try await s.analyzerTask.value
        if let t = lastSampleTime {
            try await s.analyzer.finalizeAndFinish(through: t)
        } else {
            try s.analyzer.cancelAndFinishNow()
        }

        await s.resultsTask.value
        return s.buffer.text.trimmingCharacters(in: .whitespaces)
    }

    /// Abort without returning text.
    public func cancel() async {
        guard let s = session else { return }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()
        try? s.analyzer.cancelAndFinishNow()
        s.analyzerTask.cancel()
        s.resultsTask.cancel()
    }

    // MARK: - Private

    private final class TextBuffer {
        var text: String = ""
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let transcriber: DictationTranscriber
        let engine: AVAudioEngine
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        let resultsTask: Task<Void, Never>
        let analyzerTask: Task<AVAudioTime?, Swift.Error>
        let buffer: TextBuffer
    }
}
