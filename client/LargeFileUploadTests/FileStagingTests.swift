import Testing
import Foundation

@testable import LargeFileUpload

/// Resume Bug の真因: Document Picker 由来のセキュリティスコープ付き URL は
/// 再起動を跨げないため、Documents/uploads/ にステージングして永続的なコピーを
/// UploadSession が持つように変更した。この変更に対する回帰テスト。
@Suite(.serialized)
struct FileStagingTests {

    private func makeTempSource(bytes: Int, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let data = Data(count: bytes)
        try data.write(to: url)
        return url
    }

    private func stagedRoot() -> URL {
        LargeFileUpload.FileManager.shared.getDocumentsDirectory()
            .appendingPathComponent("uploads", isDirectory: true)
    }

    @Test("stageFileForUpload はソースを Documents/uploads/ にコピーし、以降ソース削除しても読める")
    func stagingSurvivesSourceRemoval() throws {
        let src = try makeTempSource(bytes: 4096, name: "photo.dat")
        let sid = "sess-stage-\(UUID().uuidString.prefix(8))"

        let staged = try LargeFileUpload.FileManager.shared.stageFileForUpload(
            sourceURL: src,
            sessionId: sid
        )

        // ステージング先が Documents/uploads/ 配下
        #expect(staged.path.hasPrefix(stagedRoot().path))
        // ソースを削除しても
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
        // ステージング先はまだ読める
        let data = try Data(contentsOf: staged)
        #expect(data.count == 4096)

        // 後始末
        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: sid, fileURL: staged)
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test("cleanupStagedFile は Documents/uploads/ 配下のみ削除し、外部 URL は絶対に触らない")
    func cleanupOnlyTouchesStagedFiles() throws {
        // 外部の重要ファイルを模擬
        let externalDir = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let external = externalDir.appendingPathComponent("user-photo.jpg")
        try Data(count: 128).write(to: external)

        // cleanupStagedFile を外部 URL に対して呼んでも消えないこと
        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: "sid", fileURL: external)
        #expect(FileManager.default.fileExists(atPath: external.path) == true)

        try? FileManager.default.removeItem(at: externalDir)
    }

    @Test("同一 session ID で二度 stage しても上書きされる (Resume 経路の冪等性)")
    func stagingIsIdempotent() throws {
        let src1 = try makeTempSource(bytes: 100, name: "a.bin")
        let src2 = try makeTempSource(bytes: 200, name: "a.bin")
        let sid = "sess-idem-\(UUID().uuidString.prefix(8))"

        let staged1 = try LargeFileUpload.FileManager.shared.stageFileForUpload(sourceURL: src1, sessionId: sid)
        let staged2 = try LargeFileUpload.FileManager.shared.stageFileForUpload(sourceURL: src2, sessionId: sid)

        #expect(staged1.path == staged2.path)
        let data = try Data(contentsOf: staged2)
        #expect(data.count == 200)

        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: sid, fileURL: staged2)
        try? FileManager.default.removeItem(at: src1.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: src2.deletingLastPathComponent())
    }
}
