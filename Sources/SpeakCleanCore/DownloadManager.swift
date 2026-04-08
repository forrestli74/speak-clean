import CryptoKit
import Foundation

public enum DownloadError: Error, LocalizedError {
    case downloadFailed(statusCode: Int)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let code):
            return "Download failed with HTTP status \(code)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        }
    }
}

public struct DownloadManager: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(
        from url: URL,
        to destination: URL,
        expectedSHA256: String?
    ) async throws {
        // Cache hit: file already exists at destination
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }

        let tempURL = destination.appendingPathExtension("download")

        // Check for partial download to support resume
        var request = URLRequest(url: url)
        let existingBytes = Self.fileSize(at: tempURL)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.downloadFailed(statusCode: 0)
        }

        switch httpResponse.statusCode {
        case 200:
            // Fresh download — truncate any existing partial file
            try await streamToFile(bytes: bytes, to: tempURL, append: false)

        case 206:
            // Partial content — append to existing temp file
            try await streamToFile(bytes: bytes, to: tempURL, append: true)

        case 416:
            // Range not satisfiable — delete partial and retry fresh
            try? FileManager.default.removeItem(at: tempURL)
            try await fetchFresh(from: url, to: destination, tempURL: tempURL)
            return

        default:
            throw DownloadError.downloadFailed(statusCode: httpResponse.statusCode)
        }

        // Verify checksum if provided
        if let expectedSHA256 {
            let actual = try Self.sha256(of: tempURL)
            if actual != expectedSHA256.lowercased() {
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.checksumMismatch(expected: expectedSHA256.lowercased(), actual: actual)
            }
        }

        // Atomic move temp -> destination
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Private helpers

    /// Fresh download without resume — used as 416 retry path.
    private func fetchFresh(from url: URL, to destination: URL, tempURL: URL) async throws {
        let request = URLRequest(url: url)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.downloadFailed(statusCode: code)
        }

        try await streamToFile(bytes: bytes, to: tempURL, append: false)

        // Atomic move temp -> destination (no checksum check here — caller already deleted partial)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Stream bytes to file with 256KB flush interval and cancellation checks.
    private func streamToFile(
        bytes: URLSession.AsyncBytes,
        to fileURL: URL,
        append: Bool
    ) async throws {
        if !append || !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        if append {
            handle.seekToEndOfFile()
        }

        let flushThreshold = 256 * 1024  // 256 KB
        var buffer = Data()
        buffer.reserveCapacity(flushThreshold)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)

            if buffer.count >= flushThreshold {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // Flush remaining bytes
        if !buffer.isEmpty {
            handle.write(buffer)
        }
    }

    /// Returns file size or 0 if file does not exist.
    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64
        else {
            return 0
        }
        return size
    }

    /// Compute lowercase hex SHA256 of file at URL.
    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
