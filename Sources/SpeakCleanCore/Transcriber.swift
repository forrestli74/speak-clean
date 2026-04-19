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

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let engine = AVAudioEngine()
        let hwFormat = engine.inputNode.outputFormat(forBus: 0)

        // Pass hw-format buffers straight through. Skip the manual
        // AVAudioConverter — its streaming pattern produced near-empty output
        // buffers and the analyzer handles format conversion internally.
        let bridge = TapBridge(builder: inputBuilder)
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

        print("[tap] hwFormat=\(hwFormat)")

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
        var yieldCount = 0
        var failedConversions = 0   // kept for compatibility with [stop] log

        init(builder: AsyncStream<AnalyzerInput>.Continuation) {
            self.builder = builder
        }

        func handle(buffer: AVAudioPCMBuffer) {
            builder.yield(AnalyzerInput(buffer: buffer))
            yieldCount += 1
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
