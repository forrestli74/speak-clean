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

        // CoreML encoder download disabled — SwiftWhisper's CoreML integration
        // hangs during transcription. CPU + Accelerate fallback works fine.
        // TODO: re-enable when SwiftWhisper fixes CoreML inference
        // let coremlDir = modelsDir.appendingPathComponent("ggml-\(model)-encoder.mlmodelc")
        // if !FileManager.default.fileExists(atPath: coremlDir.path) {
        //     try await downloadCoreML(model: model)
        // }

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

        print("Downloading \(filename)...")
        let (bytes, response) = try await URLSession.shared.bytes(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelError.downloadFailed(filename)
        }

        let totalBytes = httpResponse.expectedContentLength
        let tempURL = destination.appendingPathExtension("download")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        let chunkSize = 1024 * 1024 // flush every 1MB

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                downloadedBytes += Int64(buffer.count)
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
                printProgress(downloaded: downloadedBytes, total: totalBytes, filename: filename)
            }
        }

        // Write remaining bytes
        if !buffer.isEmpty {
            downloadedBytes += Int64(buffer.count)
            handle.write(buffer)
        }
        handle.closeFile()

        printProgress(downloaded: downloadedBytes, total: totalBytes, filename: filename)
        print("") // newline after progress

        // Atomic move to final location
        try FileManager.default.moveItem(at: tempURL, to: destination)
        print("Model ready: \(filename)")
    }

    private func printProgress(downloaded: Int64, total: Int64, filename: String) {
        let mbDown = Double(downloaded) / (1024 * 1024)
        if total > 0 {
            let mbTotal = Double(total) / (1024 * 1024)
            let pct = Double(downloaded) / Double(total) * 100
            print("\rDownloading \(filename)... \(String(format: "%.1f", mbDown)) MB / \(String(format: "%.1f", mbTotal)) MB (\(String(format: "%.1f", pct))%)", terminator: "")
        } else {
            print("\rDownloading \(filename)... \(String(format: "%.1f", mbDown)) MB", terminator: "")
        }
        fflush(stdout)
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
