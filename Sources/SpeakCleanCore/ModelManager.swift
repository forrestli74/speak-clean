import Foundation

public final class ModelManager: Sendable {
    private let modelsDir: URL

    public init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    /// Returns local URL for model, downloading from HuggingFace if not cached.
    public func modelURL(for model: String) async throws -> URL {
        let filename = "ggml-\(model).bin"
        let localURL = modelsDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: localURL.path) {
            try await download(
                filename: filename, to: localURL,
                baseURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
            )
        }

        // Download CoreML encoder for ANE acceleration if not present
        let coremlDir = modelsDir.appendingPathComponent("ggml-\(model)-encoder.mlmodelc")
        if !FileManager.default.fileExists(atPath: coremlDir.path) {
            try await downloadCoreML(model: model)
        }

        return localURL
    }

    /// Deletes all cached models.
    public func cleanCache() throws {
        if FileManager.default.fileExists(atPath: modelsDir.path) {
            try FileManager.default.removeItem(at: modelsDir)
            print("Model cache cleaned.")
        }
    }

    private func downloadCoreML(model: String) async throws {
        let zipFilename = "ggml-\(model)-encoder.mlmodelc.zip"
        let zipURL = modelsDir.appendingPathComponent(zipFilename)

        try await download(
            filename: zipFilename, to: zipURL,
            baseURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        )

        // Unzip
        print("Extracting \(zipFilename)...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", modelsDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelError.extractFailed(zipFilename)
        }

        // Clean up zip
        try? FileManager.default.removeItem(at: zipURL)
        print("CoreML encoder ready: ggml-\(model)-encoder.mlmodelc")
    }

    private func download(filename: String, to destination: URL, baseURL: String) async throws {
        let url = URL(string: "\(baseURL)\(filename)")!
        let tempURL = destination.appendingPathExtension("download")

        // Clean up temp file on failure
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path),
               !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        print("Downloading \(filename)...")
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelError.downloadFailed(filename)
        }

        // Move to temp location first (download file is auto-deleted by URLSession)
        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)

        let totalBytes = httpResponse.expectedContentLength
        let mbTotal = Double(totalBytes) / (1024 * 1024)
        print("Downloaded \(filename): \(String(format: "%.1f", mbTotal)) MB")

        // Atomic move to final location
        try FileManager.default.moveItem(at: tempURL, to: destination)
        print("Model ready: \(filename)")
    }

}

public enum ModelError: Error, LocalizedError {
    case downloadFailed(String)
    case extractFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let name): return "Failed to download model: \(name)"
        case .extractFailed(let name): return "Failed to extract: \(name)"
        }
    }
}
