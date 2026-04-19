import AppKit
import AVFoundation
import SpeakCleanCore
import SwiftWhisper

// MARK: - Menu Bar Icons

enum MenuBarIcon {
    /// Idle: I-beam cursor + waveform bars
    static func idle(height: CGFloat = 18) -> NSImage {
        let width = height
        let scale = height / 36.0
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.black.setStroke()

            let lw: CGFloat = 2.5 * scale
            let cursor = NSBezierPath()
            cursor.lineWidth = lw
            cursor.lineCapStyle = .round
            cursor.move(to: NSPoint(x: 6*scale, y: 6*scale))
            cursor.line(to: NSPoint(x: 6*scale, y: 30*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 6*scale))
            cursor.line(to: NSPoint(x: 10*scale, y: 6*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 30*scale))
            cursor.line(to: NSPoint(x: 10*scale, y: 30*scale))
            cursor.stroke()

            let bars: [(x: CGFloat, y1: CGFloat, y2: CGFloat)] = [
                (16, 14, 22), (21, 8, 28), (26, 11, 25), (31, 14, 22),
            ]
            for bar in bars {
                let path = NSBezierPath()
                path.lineWidth = lw
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: bar.x*scale, y: bar.y1*scale))
                path.line(to: NSPoint(x: bar.x*scale, y: bar.y2*scale))
                path.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Recording: filled circle (record indicator)
    static func recording(height: CGFloat = 18) -> NSImage {
        let width = height
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.black.setFill()
            let inset: CGFloat = height * 0.15
            let oval = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            oval.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Processing: ellipsis (three dots)
    static func processing(height: CGFloat = 18) -> NSImage {
        let width = height
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.black.setFill()
            let r: CGFloat = height * 0.08
            let cy = height / 2
            let gap = height * 0.22
            for i in -1...1 {
                let cx = width/2 + CGFloat(i) * gap
                NSBezierPath(ovalIn: NSRect(x: cx-r, y: cy-r, width: r*2, height: r*2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var statusItem: NSStatusItem?
    private var isTranscribing = false
    let controller: AppController
    let saveAudioDir: String?

    init(controller: AppController, saveAudioDir: String? = nil) {
        self.controller = controller
        self.saveAudioDir = saveAudioDir
    }

    private func setIcon(_ icon: NSImage) {
        statusItem?.button?.image = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(MenuBarIcon.processing())
        statusItem?.menu = buildMenu()
        setupGlobalShortcut()

        controller.onStateChange = { [weak self] state in
            guard let self, self.audioRecorder == nil, !self.isTranscribing else { return }
            switch state {
            case .notReady: self.setIcon(MenuBarIcon.processing())
            case .ready: self.setIcon(MenuBarIcon.idle())
            case .error: self.setIcon(MenuBarIcon.idle())
            }
        }

        controller.reset()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit Dictionary…", action: #selector(editDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clean Model Cache", action: #selector(cleanModelCache), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func editDictionary() {
        AppConfig.openDictionary()
    }

    @objc private func cleanModelCache() {
        Task {
            do {
                try await controller.clearCache()
            } catch {
                print("Failed to clean model cache: \(error)")
            }
        }
    }

    private func setupGlobalShortcut() {
        guard let shortcut = AppConfig.parsedShortcut else {
            print("Invalid shortcut: \(AppConfig.shortcut)")
            return
        }
        let modifiers = shortcut.modifiers
        let keyCode = shortcut.keyCode

        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(modifiers) && event.keyCode == keyCode {
                self?.toggleRecording()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(modifiers) && event.keyCode == keyCode {
                self?.toggleRecording()
                return nil
            }
            return event
        }
    }

    private func toggleRecording() {
        if audioRecorder != nil {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard case .ready = controller.state else { return }
        controller.whisper.prewarm()

        let outputDir = saveAudioDir ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filePath = outputDir + "/recording-\(timestamp).wav"
        let url = URL(fileURLWithPath: filePath)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            setIcon(MenuBarIcon.recording())
            print("Recording started: \(filePath)")
            NSSound(named: .init("Tink"))?.play()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        guard let url = audioRecorder?.url else { return }
        audioRecorder = nil

        print("Recording saved: \(url.path)")
        NSSound(named: .init("Pop"))?.play()
        setIcon(MenuBarIcon.processing())
        isTranscribing = true

        let controller = self.controller
        let deleteAfter = saveAudioDir == nil
        Task { @MainActor [weak self] in
            defer {
                if deleteAfter { try? FileManager.default.removeItem(at: url) }
                self?.isTranscribing = false
                if case .ready = controller.state {
                    self?.setIcon(MenuBarIcon.idle())
                }
            }
            do {
                let text = try await controller.whisper.withModel { whisper in
                    // Whisper is non-Sendable but thread-safe internally.
                    nonisolated(unsafe) let unsafeWhisper = whisper
                    return try await controller.transcriber.transcribe(
                        whisper: unsafeWhisper, audioFileURL: url
                    )
                }
                if !text.isEmpty {
                    print("Transcription: \(text)")
                    self?.pasteText(text)
                }
            } catch {
                print("Transcription failed: \(error)")
                controller.markError(error)
            }
        }
    }

    private func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
                speak-clean — speech to text with filler word removal

                Usage:
                  speak-clean                          Run as menu bar app
                  speak-clean --audio <file.wav>       Transcribe a file to stdout
                  speak-clean --save-audio <dir>       Save recordings to <dir> instead of temp

                Options:
                  --audio <file>        Transcribe an audio file and exit
                  --save-audio <dir>    Keep recorded WAV files in <dir>
                  --help, -h            Show this help
                """)
            return
        }

        var saveAudioDir: String?
        if let idx = args.firstIndex(of: "--save-audio"), idx + 1 < args.count {
            saveAudioDir = args[idx + 1]
        }

        if let audioIndex = args.firstIndex(of: "--audio"), audioIndex + 1 < args.count {
            // CLI mode: transcribe a file and print to stdout
            let filePath = args[audioIndex + 1]
            let modelsDir = AppConfig.modelsDir
            let model = AppConfig.model
            Task.detached {
                let modelManager = ModelManager(modelsDir: modelsDir)
                let transcriber = Transcriber()
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    let url = try await modelManager.modelURL(for: model)
                    fputs("  download:    \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s\n", stderr)

                    var params = WhisperParams(strategy: .greedy)
                    params.language = .english
                    params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
                    params.print_progress = false
                    params.print_timestamps = false
                    let whisper = Whisper(fromFileURL: url, withParams: params)
                    fputs("  model load:  \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s\n", stderr)

                    let audioURL = URL(fileURLWithPath: filePath)
                    let text = try await transcriber.transcribe(whisper: whisper, audioFileURL: audioURL)
                    let elapsed = CFAbsoluteTimeGetCurrent() - t0
                    fputs("[\(String(format: "%.2f", elapsed))s total]\n", stderr)
                    print(text)
                } catch {
                    fputs("Error: \(error)\n", stderr)
                    exit(1)
                }
                exit(0)
            }
            dispatchMain()
        } else {
            // App mode
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let controller = AppController(
                modelManager: ModelManager(modelsDir: AppConfig.modelsDir)
            )
            let delegate = AppDelegate(controller: controller, saveAudioDir: saveAudioDir)
            app.delegate = delegate
            app.run()
        }
    }
}
