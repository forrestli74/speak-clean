import AppKit
import AVFoundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var isRecording = false
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon for visual feedback
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🎙"
        statusItem?.menu = buildMenu()

        setupGlobalShortcut()
        print("speak-clean running. Press Option+Space to toggle recording.")
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
        // TODO: implement model cache cleanup
        print("Clean model cache: not yet implemented")
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
        statusItem?.button?.title = "🎙"

        if let url = audioRecorder?.url {
            print("Recording saved: \(url.path)")
        }

        NSSound(named: .init("Pop"))?.play()
        pasteHelloWorld()
        audioRecorder = nil
    }

    private func pasteHelloWorld() {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString("hello world", forType: .string)

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
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
