import AppKit

@MainActor
enum AppConfig {
    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SpeakClean")
    }()

    static let fileURL: URL = appSupportDir.appendingPathComponent("config.json")
    static let modelsDir: URL = appSupportDir.appendingPathComponent("models")

    static var model: String {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String, !model.isEmpty
        else {
            return "base.en"
        }
        return model
    }

    static func openInEditor() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupportDir.path) {
            try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: Data("{}\n".utf8))
        }
        NSWorkspace.shared.open(fileURL)
    }
}
