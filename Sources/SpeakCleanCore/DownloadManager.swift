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

        let computedSHA256: String

        switch httpResponse.statusCode {
        case 200:
            // Fresh download — truncate any existing partial file
            computedSHA256 = try await streamToFile(bytes: bytes, to: tempURL, append: false)

        case 206:
            // Partial content — append to existing temp file
            computedSHA256 = try await streamToFile(bytes: bytes, to: tempURL, append: true)

        case 416:
            // Range not satisfiable — delete partial and retry fresh
            try? FileManager.default.removeItem(at: tempURL)
            try await fetchFresh(from: url, to: destination, tempURL: tempURL, expectedSHA256: expectedSHA256)
            return

        default:
            throw DownloadError.downloadFailed(statusCode: httpResponse.statusCode)
        }

        try verifyAndMove(
            tempURL: tempURL,
            destination: destination,
            expectedSHA256: expectedSHA256,
            computedSHA256: computedSHA256
        )
    }

    // MARK: - Private helpers

    /// Fresh download without resume — used as 416 retry path.
    private func fetchFresh(
        from url: URL,
        to destination: URL,
        tempURL: URL,
        expectedSHA256: String?
    ) async throws {
        let request = URLRequest(url: url)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.downloadFailed(statusCode: code)
        }

        let computedSHA256 = try await streamToFile(bytes: bytes, to: tempURL, append: false)

        try verifyAndMove(
            tempURL: tempURL,
            destination: destination,
            expectedSHA256: expectedSHA256,
            computedSHA256: computedSHA256
        )
    }

    /// Verify checksum (if expected) and atomically move temp file to destination.
    private func verifyAndMove(
        tempURL: URL,
        destination: URL,
        expectedSHA256: String?,
        computedSHA256: String
    ) throws {
        if let expectedSHA256 {
            let expected = expectedSHA256.lowercased()
            if computedSHA256 != expected {
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.checksumMismatch(expected: expected, actual: computedSHA256)
            }
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Stream bytes to file with 256KB flush interval and cancellation checks.
    /// Returns the lowercase hex SHA256 digest computed incrementally during streaming.
    private func streamToFile(
        bytes: URLSession.AsyncBytes,
        to fileURL: URL,
        append: Bool
    ) async throws -> String {
        if !append || !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        if append {
            handle.seekToEndOfFile()
        }

        var hasher = SHA256()
        let flushThreshold = 256 * 1024  // 256 KB
        var buffer = Data()
        buffer.reserveCapacity(flushThreshold)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)

            if buffer.count >= flushThreshold {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // Flush remaining bytes
        if !buffer.isEmpty {
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
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

}
