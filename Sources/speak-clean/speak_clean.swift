import AppKit
import AVFoundation
import SpeakCleanCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var isRecording = false
    private var statusItem: NSStatusItem?
    let transcriber: Transcriber

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon for visual feedback
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🎙"
        statusItem?.menu = buildMenu()

        setupGlobalShortcut()

        // Pre-load model so first recording is fast
        statusItem?.button?.title = "⏳"
        let model = AppConfig.model
        let transcriber = self.transcriber
        Task.detached {
            do {
                try await transcriber.preload(model: model)
            } catch {
                print("Failed to preload model: \(error)")
            }
            await MainActor.run { [weak self] in
                self?.statusItem?.button?.title = "🎙"
                print("speak-clean running. Press Option+Space to toggle recording.")
            }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clean Model Cache", action: #selector(cleanModelCache), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func editConfig() {
        AppConfig.openInEditor()
    }

    @objc private func cleanModelCache() {
        let manager = ModelManager(modelsDir: AppConfig.modelsDir)
        do {
            try manager.cleanCache()
        } catch {
            print("Failed to clean model cache: \(error)")
        }
    }

    private func setupGlobalShortcut() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Option+Space: keyCode 49 = space
            if event.modifierFlags.contains(.option) && event.keyCode == 49 {
                self?.toggleRecording()
            }
        }
        // Also monitor local events (when app itself is focused)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.option) && event.keyCode == 49 {
                self?.toggleRecording()
                return nil
            }
            return event
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        let outputDir = FileManager.default.currentDirectoryPath + "/output"
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
            isRecording = true
            statusItem?.button?.title = "⏺"
            print("Recording started: \(filePath)")
            NSSound(named: .init("Tink"))?.play()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false

        guard let url = audioRecorder?.url else { return }
        print("Recording saved: \(url.path)")

        NSSound(named: .init("Pop"))?.play()
        statusItem?.button?.title = "⏳"

        let transcriber = self.transcriber
        let model = AppConfig.model
        Task.detached {
            let result: String?
            do {
                let text = try await transcriber.transcribe(
                    audioFileURL: url, model: model
                )
                result = text.isEmpty ? nil : text
            } catch {
                print("Transcription failed: \(error)")
                result = nil
            }
            let output = result
            await MainActor.run { [weak self] in
                if let text = output {
                    print("Transcription: \(text)")
                    self?.pasteText(text)
                }
                self?.statusItem?.button?.title = "🎙"
            }
        }

        audioRecorder = nil
    }

    private func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 'v'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore previous clipboard after a short delay
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

        if let audioIndex = args.firstIndex(of: "--audio"), audioIndex + 1 < args.count {
            // CLI mode: async is fine, no run loop
            let filePath = args[audioIndex + 1]
            let modelsDir = AppConfig.modelsDir
            let model = AppConfig.model
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let transcriber = Transcriber(
                    modelManager: ModelManager(modelsDir: modelsDir)
                )
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    try await transcriber.preload(model: model)
                    fputs("  preload:     \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s\n", stderr)
                    let url = URL(fileURLWithPath: filePath)
                    let text = try await transcriber.transcribe(audioFileURL: url, model: model)
                    let elapsed = CFAbsoluteTimeGetCurrent() - t0
                    fputs("[\(String(format: "%.2f", elapsed))s total]\n", stderr)
                    print(text)
                } catch {
                    fputs("Error: \(error)\n", stderr)
                    exit(1)
                }
                sem.signal()
            }
            sem.wait()
            return
        }

        // App mode: synchronous main, preload via Task inside run loop
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let transcriber = Transcriber(
            modelManager: ModelManager(modelsDir: AppConfig.modelsDir)
        )
        let delegate = AppDelegate(transcriber: transcriber)
        app.delegate = delegate
        app.run()
    }
}
