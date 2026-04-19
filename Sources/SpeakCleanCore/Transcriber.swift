import AVFoundation
import Speech

/// Streaming microphone-to-text wrapper around Apple's `SpeechAnalyzer` +
/// `DictationTranscriber`. One `Transcriber` instance hosts a single active
/// recording session at a time: `start()` spins up an `AVAudioEngine` tap
/// that feeds audio buffers into the analyzer concurrently with the user
/// speaking; `stop()` finalizes and returns the accumulated text.
///
/// The class is `@MainActor`-isolated. The realtime audio tap hops through
/// a non-isolated `TapBridge` so the audio thread doesn't trip Swift 6's
/// executor-isolation check.
@MainActor
public final class Transcriber {

    /// Single-reason thrown error type. All failure modes (unsupported
    /// locale, engine init failure, double-start, etc.) surface as an
    /// `Error` with a user-facing `reason` string; callers typically
    /// forward this into `AppController.setState(.notReady(reason:))`.
    public struct Error: LocalizedError {
        /// Human-readable failure reason, shown in the menu tooltip.
        public let reason: String
        /// Bridges `reason` into `Swift.Error.localizedDescription`.
        public var errorDescription: String? { reason }
    }

    /// The active recording session, if any. `nil` between recordings.
    /// Presence of a non-nil value means `start()` succeeded and neither
    /// `stop()` nor `cancel()` has run yet.
    private var session: Session?

    /// Final-result text accumulated from `transcriber.results` during the
    /// current session. Reset to `""` in `start()`, appended-to from the
    /// `resultsTask`, read and returned by `stop()`.
    private var accumulated: String = ""

    public init() {}

    /// Begin a streaming recognition session.
    ///
    /// Creates a `DictationTranscriber` for the user's locale, wires up
    /// `AVAudioEngine` with an input tap that converts the hardware
    /// format down to the analyzer's best-available format, and launches
    /// two background tasks: one driving `analyzer.analyzeSequence(...)`
    /// and one consuming `transcriber.results` to build up
    /// `accumulated`.
    ///
    /// Throws `Error` on any setup failure (unsupported locale, format
    /// incompatibility, engine init failure, or if another session is
    /// still active). Caller (AppDelegate) should treat any throw as
    /// terminal — the app goes to `.notReady` and awaits Reset.
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

    /// Stop recording, finalize the analyzer, and return the accumulated
    /// text trimmed of surrounding whitespace.
    ///
    /// Tears down the audio tap + engine, closes the input stream, awaits
    /// the analyzer's `analyzeSequence` (discarding its `CMTime?` result),
    /// calls `finalizeAndFinishThroughEndOfInput()` so the transcriber
    /// emits any pending final results, then awaits the results task to
    /// drain. Throws `Error` if no session is active.
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

    /// Abort the current session without attempting to return text.
    ///
    /// Used from `AppController.reset()` to wipe any in-flight session
    /// before re-running availability checks. Safe to call when no
    /// session is active (no-op).
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

    /// Non-actor bridge between the realtime audio tap and the analyzer's
    /// input stream.
    ///
    /// `AVFoundation` invokes the tap closure on a realtime audio thread
    /// with no actor context. Swift 6 would flag a `@MainActor`-isolated
    /// closure here as a concurrency error. This class is marked
    /// `@unchecked Sendable` so it can be captured by an explicitly
    /// `@Sendable` tap closure. Thread safety is provided by AVFoundation
    /// itself — each tap invocation is serialized on its audio thread,
    /// and `AsyncStream.Continuation.yield` is documented thread-safe.
    private final class TapBridge: @unchecked Sendable {
        /// Sink that delivers converted buffers to `SpeechAnalyzer`.
        let builder: AsyncStream<AnalyzerInput>.Continuation
        /// Reused sample-rate / format converter. Its filter state must
        /// persist across tap calls — see `handle(buffer:)` for why.
        let converter: AVAudioConverter
        /// Format `SpeechAnalyzer.bestAvailableAudioFormat` asked for.
        let targetFormat: AVAudioFormat
        /// Format the microphone hardware emits. Used to size output.
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

        /// Called once per mic tap. Converts the hw-format buffer to the
        /// analyzer's preferred format and yields it into the input
        /// stream. Critical detail: the input callback reports
        /// `.noDataNow` (not `.endOfStream`) once the single input buffer
        /// has been handed over, so the converter keeps its resampler
        /// filter state across calls. `.endOfStream` would flush and
        /// reset per call, producing near-empty output buffers for
        /// downsampling (e.g. 48kHz → 16kHz).
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

    /// Bundle of objects that together make up one recording session.
    /// Kept as a single optional on `Transcriber` so start/stop can
    /// treat "active session" as a single piece of state.
    private struct Session {
        /// The analyzer orchestrating the transcriber module.
        let analyzer: SpeechAnalyzer
        /// Audio engine driving the mic tap.
        let engine: AVAudioEngine
        /// Continuation for `AsyncStream<AnalyzerInput>`. Finished in
        /// `stop()`/`cancel()` to signal end of input.
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        /// Consumes `transcriber.results`, writing finals to
        /// `Transcriber.accumulated`.
        let resultsTask: Task<Void, Swift.Error>
        /// Runs `analyzer.analyzeSequence`; returns the last-sample
        /// `CMTime` (unused — we call
        /// `finalizeAndFinishThroughEndOfInput` instead).
        let analyzerTask: Task<CMTime?, Swift.Error>
    }
}
