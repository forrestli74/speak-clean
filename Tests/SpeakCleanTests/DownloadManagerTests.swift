import Foundation
import Testing
@testable import SpeakCleanCore

@Suite("DownloadManager")
struct DownloadManagerTests {
    @Test func cacheHitReturnsImmediately() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let destination = tmp.appendingPathComponent("model.bin")
        let sentinel = Data("cached".utf8)
        try sentinel.write(to: destination)

        // Use default session — fetch should never hit the network because file exists
        let manager = DownloadManager()
        try await manager.fetch(
            from: URL(string: "https://should-not-be-called.invalid/model.bin")!,
            to: destination,
            expectedSHA256: nil
        )

        // File should be unchanged (proves no download happened)
        let contents = try Data(contentsOf: destination)
        #expect(contents == sentinel)
    }
}
