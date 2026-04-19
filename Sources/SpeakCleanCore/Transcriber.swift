import AVFoundation
import Speech

@MainActor
public final class Transcriber {

    public struct Error: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    private var session: Session?
    private var accumulated: String = ""

    public init() {}

    /// Begin streaming recognition. Call `stop()` to finalize and retrieve text.
    public func start() async throws {
        guard session == nil else { throw Error(reason: "Recording already in progress") }

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw Error(reason: "Unsupported locale: \(Locale.current.identifier)")
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Error(reason: "Could not determine audio format")
        }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let engine = AVAudioEngine()
        let hwFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw Error(reason: "Could not build audio converter \(hwFormat) → \(targetFormat)")
        }

        let bridge = TapBridge(
            builder: inputBuilder,
            converter: converter,
            targetFormat: targetFormat,
            hwFormat: hwFormat
        )
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { @Sendable buffer, _ in
            bridge.handle(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            inputBuilder.finish()
            throw Error(reason: "Audio engine failed: \(error.localizedDescription)")
        }

        accumulated = ""
        let resultsTask = Task { @MainActor [weak self] in
            for try await result in transcriber.results where result.isFinal {
                self?.accumulated += String(result.text.characters)
            }
        }

        let analyzerTask = Task {
            try await analyzer.analyzeSequence(inputSequence)
        }

        session = Session(
            analyzer: analyzer,
            engine: engine,
            inputBuilder: inputBuilder,
            resultsTask: resultsTask,
            analyzerTask: analyzerTask
        )
    }

    /// Stop recording, finalize, return the accumulated text.
    public func stop() async throws -> String {
        guard let s = session else { throw Error(reason: "No recording in progress") }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()

        _ = try await s.analyzerTask.value
        try await s.analyzer.finalizeAndFinishThroughEndOfInput()
        try? await s.resultsTask.value

        return accumulated.trimmingCharacters(in: .whitespaces)
    }

    /// Abort without returning text.
    public func cancel() async {
        guard let s = session else { return }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()
        await s.analyzer.cancelAndFinishNow()
        s.analyzerTask.cancel()
        s.resultsTask.cancel()
    }

    // MARK: - Private

    private final class TapBridge: @unchecked Sendable {
        let builder: AsyncStream<AnalyzerInput>.Continuation
        let converter: AVAudioConverter
        let targetFormat: AVAudioFormat
        let hwFormat: AVAudioFormat

        init(builder: AsyncStream<AnalyzerInput>.Continuation,
             converter: AVAudioConverter,
             targetFormat: AVAudioFormat,
             hwFormat: AVAudioFormat) {
            self.builder = builder
            self.converter = converter
            self.targetFormat = targetFormat
            self.hwFormat = hwFormat
        }

        func handle(buffer: AVAudioPCMBuffer) {
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                return
            }
            var provided = false
            var err: NSError?
            // .noDataNow (not .endOfStream) keeps the converter's resampler
            // state alive between tap callbacks. .endOfStream would flush on
            // every call, producing tiny output buffers.
            _ = converter.convert(to: out, error: &err) { _, statusPtr in
                if provided {
                    statusPtr.pointee = .noDataNow
                    return nil
                }
                provided = true
                statusPtr.pointee = .haveData
                return buffer
            }
            if err == nil && out.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: out))
            }
        }
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let engine: AVAudioEngine
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        let resultsTask: Task<Void, Swift.Error>
        let analyzerTask: Task<CMTime?, Swift.Error>
    }
}
