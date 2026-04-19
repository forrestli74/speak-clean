import AVFoundation
import CoreMedia
import Speech

@MainActor
public final class Transcriber {

    public struct Error: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    private var session: Session?

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
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        // @Sendable closure + TapBridge → runs on AVFoundation's audio thread
        // without a main-actor executor check.
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

        let buffer = TextBuffer()
        let resultsTask = Task { @MainActor in
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                print("[stt result] isFinal=\(result.isFinal) text=\(text.isEmpty ? "(empty)" : text)")
                if result.isFinal {
                    buffer.text += text
                }
            }
            print("[stt results stream ended]")
        }

        let analyzerTask: Task<CMTime?, Swift.Error> = Task {
            try await analyzer.analyzeSequence(inputSequence)
        }

        print("[tap] hwFormat=\(hwFormat) targetFormat=\(targetFormat)")

        session = Session(
            analyzer: analyzer,
            engine: engine,
            inputBuilder: inputBuilder,
            resultsTask: resultsTask,
            analyzerTask: analyzerTask,
            buffer: buffer,
            bridge: bridge
        )
    }

    /// Stop recording, finalize, return the accumulated text.
    public func stop() async throws -> String {
        guard let s = session else { throw Error(reason: "No recording in progress") }
        defer { session = nil }

        s.engine.inputNode.removeTap(onBus: 0)
        s.engine.stop()
        s.inputBuilder.finish()

        print("[stop] yielded \(s.bridge.yieldCount) buffers, \(s.bridge.failedConversions) failed conversions")

        let lastSampleTime = try await s.analyzerTask.value
        print("[stop] analyzerTask lastSampleTime = \(String(describing: lastSampleTime))")
        try await s.analyzer.finalizeAndFinishThroughEndOfInput()

        try? await s.resultsTask.value
        let text = s.buffer.text.trimmingCharacters(in: .whitespaces)
        print("[stop] accumulated text: \(text.isEmpty ? "(empty)" : text)")
        return text
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

    private final class TextBuffer {
        var text: String = ""
    }

    private final class TapBridge: @unchecked Sendable {
        let builder: AsyncStream<AnalyzerInput>.Continuation
        let converter: AVAudioConverter?
        let targetFormat: AVAudioFormat
        let hwFormat: AVAudioFormat
        var yieldCount = 0
        var failedConversions = 0

        init(builder: AsyncStream<AnalyzerInput>.Continuation,
             converter: AVAudioConverter?,
             targetFormat: AVAudioFormat,
             hwFormat: AVAudioFormat) {
            self.builder = builder
            self.converter = converter
            self.targetFormat = targetFormat
            self.hwFormat = hwFormat
        }

        func handle(buffer: AVAudioPCMBuffer) {
            guard let converter else {
                builder.yield(AnalyzerInput(buffer: buffer))
                yieldCount += 1
                return
            }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                failedConversions += 1
                return
            }
            var consumed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if err == nil {
                builder.yield(AnalyzerInput(buffer: out))
                yieldCount += 1
            } else {
                failedConversions += 1
            }
        }
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let engine: AVAudioEngine
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        let resultsTask: Task<Void, Swift.Error>
        let analyzerTask: Task<CMTime?, Swift.Error>
        let buffer: TextBuffer
        let bridge: TapBridge
    }
}
