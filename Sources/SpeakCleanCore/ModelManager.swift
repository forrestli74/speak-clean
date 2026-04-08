import Foundation

public final class ModelManager: Sendable {
    private let modelsDir: URL
    private let downloadManager: DownloadManager
    private let session: URLSession

    private static let hfRepo = "ggerganov/whisper.cpp"
    private static let hfBaseURL = "https://huggingface.co/\(hfRepo)/resolve/main/"
    private static let hfAPIURL = "https://huggingface.co/api/models/\(hfRepo)/tree/main"

    public init(modelsDir: URL, session: URLSession = .shared) {
        self.modelsDir = modelsDir
        self.session = session
        self.downloadManager = DownloadManager(session: session)
    }

    public func modelURL(for model: String) async throws -> URL {
        let filename = "ggml-\(model).bin"
        let localURL = modelsDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: localURL.path) {
            let sha = await fetchSHA256(for: filename)
            let remoteURL = URL(string: "\(Self.hfBaseURL)\(filename)")!
            try await downloadManager.fetch(from: remoteURL, to: localURL, expectedSHA256: sha)
        }

        // CoreML encoder
        let coremlDir = modelsDir.appendingPathComponent("ggml-\(model)-encoder.mlmodelc")
        if !FileManager.default.fileExists(atPath: coremlDir.path) {
            try await downloadCoreML(model: model)
        }

        return localURL
    }

    /// Fetches SHA256 for a file from HuggingFace API. Returns nil on failure (best effort).
    public func fetchSHA256(for filename: String) async -> String? {
        guard let apiURL = URL(string: Self.hfAPIURL) else { return nil }

        do {
            let (data, response) = try await session.data(from: apiURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            struct HFFile: Decodable {
                let path: String
                let lfs: LFS?
                struct LFS: Decodable {
                    let sha256: String
                }
            }

            let files = try JSONDecoder().decode([HFFile].self, from: data)
            return files.first(where: { $0.path == filename })?.lfs?.sha256
        } catch {
            return nil
        }
    }

    public func cleanCache() throws {
        if FileManager.default.fileExists(atPath: modelsDir.path) {
            try FileManager.default.removeItem(at: modelsDir)
            print("Model cache cleaned.")
        }
    }

    private func downloadCoreML(model: String) async throws {
        let zipFilename = "ggml-\(model)-encoder.mlmodelc.zip"
        let zipURL = modelsDir.appendingPathComponent(zipFilename)

        let sha = await fetchSHA256(for: zipFilename)
        let remoteURL = URL(string: "\(Self.hfBaseURL)\(zipFilename)")!
        try await downloadManager.fetch(from: remoteURL, to: zipURL, expectedSHA256: sha)

        print("Extracting \(zipFilename)...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", modelsDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelError.extractFailed(zipFilename)
        }

        try? FileManager.default.removeItem(at: zipURL)
        print("CoreML encoder ready: ggml-\(model)-encoder.mlmodelc")
    }
}

public enum ModelError: Error, LocalizedError {
    case extractFailed(String)

    public var errorDescription: String? {
        switch self {
        case .extractFailed(let name): return "Failed to extract: \(name)"
        }
    }
}
