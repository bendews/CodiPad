import CodiPadWorkspace
import Foundation
import XCTest

final class StagedSaveTests: XCTestCase {
    private let original = Data("original contents\n".utf8)

    private func beginSave() throws -> (file: URL, workspace: WorkspaceFileSystem, handle: Int) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("notes.txt")
        try original.write(to: file)
        let workspace = WorkspaceFileSystem(access: WorkspaceAccess())
        let uri = try workspace.grantFile(file, securityScoped: false)
        let result = try workspace.perform("fs.stageBegin", params: [
            "uri": uri, "create": false, "overwrite": true
        ])
        let handle = try XCTUnwrap((result as? [String: Int])?["handle"])
        return (file, workspace, handle)
    }

    func testCommitPublishesAllChunksTogether() throws {
        let (file, workspace, handle) = try beginSave()
        let first = Data(repeating: 0x61, count: 256 * 1024)
        let last = Data("end\n".utf8)
        _ = try workspace.perform("fs.stageWrite", params: [
            "handle": handle, "position": 0, "data": first.base64EncodedString()
        ])
        _ = try workspace.perform("fs.stageWrite", params: [
            "handle": handle, "position": first.count, "data": last.base64EncodedString()
        ])
        XCTAssertEqual(try Data(contentsOf: file), original)

        let result = try workspace.perform("fs.stageCommit", params: ["handle": handle])
        XCTAssertEqual((result as? [String: Bool])?["created"], false)
        XCTAssertEqual(try Data(contentsOf: file), first + last)
    }

    func testAbortDiscardsPartialSaveAndPreservesOriginal() throws {
        let (file, workspace, handle) = try beginSave()
        _ = try workspace.perform("fs.stageWrite", params: [
            "handle": handle, "position": 0, "data": Data("partial".utf8).base64EncodedString()
        ])
        _ = try workspace.perform("fs.stageAbort", params: ["handle": handle])

        XCTAssertThrowsError(try workspace.perform("fs.stageCommit", params: ["handle": handle]))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
                       [file.lastPathComponent])
    }
}
