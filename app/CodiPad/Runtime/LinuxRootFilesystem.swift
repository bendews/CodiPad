import CryptoKit
import Foundation

// Prepares and verifies the bundled Linux rootfs archive on first launch.
// The bundled build receipt supplies the expected archive digest; once installed,
// the root preserves user package changes.
enum LinuxRootFilesystem {
    private struct BaseReceipt: Codable {
        let schemaVersion: Int
        let archiveSHA256: String
    }

    private struct StorageError: LocalizedError {
        var errorDescription: String? {
            "The Linux development environment requires case-sensitive storage."
        }
    }

    static func prepare(archive: URL, expectedSHA256: String, root: URL,
                        importArchive: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let receiptName = "base-receipt.json"
        if fm.fileExists(atPath: root.path) {
            let installed = try JSONDecoder().decode(BaseReceipt.self,
                from: Data(contentsOf: root.appendingPathComponent(receiptName)))
            guard installed.schemaVersion == 1,
                  fm.fileExists(atPath: root.appendingPathComponent("meta.db").path),
                  fm.fileExists(atPath: root.appendingPathComponent("data").path) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return
        }

        let storage = try root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard storage.volumeSupportsCaseSensitiveNames == true else { throw StorageError() }
        guard expectedSHA256.utf8.count == 64,
              expectedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let staging = root.appendingPathExtension("installing")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        defer { try? fm.removeItem(at: staging) }
        try importArchive(archive, staging)
        guard fm.fileExists(atPath: staging.appendingPathComponent("meta.db").path),
              fm.fileExists(atPath: staging.appendingPathComponent("data").path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let receipt = BaseReceipt(schemaVersion: 1, archiveSHA256: expectedSHA256)
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(receiptName), options: .atomic)
        try fm.moveItem(at: staging, to: root)
    }
}
