import AppKit
import AVFoundation
import SpeakCleanCore

// MARK: - Menu Bar Icons

enum MenuBarIcon {
    /// Idle: I-beam cursor + waveform bars
    static func idle(height: CGFloat = 18) -> NSImage {
        let width = height // square
        let scale = height / 36.0
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.black.setStroke()

            let lw: CGFloat = 2.5 * scale
            // I-beam cursor
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

            // Waveform bars
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

// MARK: - App Delegate (menu bar lifecycle + recording flow)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var isRecording = false
    private var statusItem: NSStatusItem?
    let transcriber: Transcriber
    /// If set, recordings are kept here instead of being deleted after transcription
    let saveAudioDir: String?

    init(transcriber: Transcriber, saveAudioDir: String? = nil) {
        self.transcriber = transcriber
        self.saveAudioDir = saveAudioDir
    }

    private func setIcon(_ icon: NSImage) {
        statusItem?.button?.image = icon
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon for visual feedback
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(MenuBarIcon.idle())
        statusItem?.menu = buildMenu()

        setupGlobalShortcut()

        // TODO(Task 6): rewrite using AppController
        setIcon(MenuBarIcon.idle())
        print("speak-clean running. Press Option+Space to toggle recording.")
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
        let manager = ModelManager(modelsDir: AppConfig.modelsDir)
        do {
            try manager.cleanCache()
        } catch {
            print("Failed to clean model cache: \(error)")
        }
    }

    // Register both global (other apps focused) and local (our app focused) key monitors
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
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Record 16kHz mono WAV — the format whisper.cpp expects
    private func startRecording() {
        let outputDir = saveAudioDir ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Timestamp in filename for --save-audio mode
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
            setIcon(MenuBarIcon.recording())
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
        setIcon(MenuBarIcon.processing())

        let deleteAfter = saveAudioDir == nil
        Task.detached {
            let result: String?
            // TODO(Task 6): rewrite using AppController / ManagedModel<Whisper>
            result = nil
            if deleteAfter {
                try? FileManager.default.removeItem(at: url)
            }
            let output = result
            await MainActor.run { [weak self] in
                if let text = output {
                    print("Transcription: \(text)")
                    self?.pasteText(text)
                }
                self?.setIcon(MenuBarIcon.idle())
            }
        }

        audioRecorder = nil
    }

    /// Paste text into the active app by temporarily hijacking the clipboard
    private func pasteText(_ text: String) {
        // Save current clipboard so we can restore it after pasting
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Synthesize Cmd+V keypress via CGEvent
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

// MARK: - Entry Point (CLI vs menu bar app)

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

        // Parse --save-audio
        var saveAudioDir: String?
        if let idx = args.firstIndex(of: "--save-audio"), idx + 1 < args.count {
            saveAudioDir = args[idx + 1]
        }

        if let audioIndex = args.firstIndex(of: "--audio"), audioIndex + 1 < args.count {
            // TODO(Task 6): rewrite CLI mode using AppController
            fputs("--audio mode not yet implemented in this build.\n", stderr)
            exit(1)
        } else {
            // App mode: synchronous main, preload via Task inside run loop
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let transcriber = Transcriber()
            let delegate = AppDelegate(transcriber: transcriber, saveAudioDir: saveAudioDir)
            app.delegate = delegate
            app.run()
        }
    }
}
