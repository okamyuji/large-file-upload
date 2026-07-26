import Testing
import Foundation

@testable import LargeFileUpload

/// Resume Bug の真因: Document Picker 由来のセキュリティスコープ付き URL は
/// 再起動を跨げないため、Documents/uploads/<sessionId>/ にチャンク単位でステージングして
/// UploadSession がそのディレクトリを持つように変更した。この変更に対する回帰テスト。
///
/// 全体コピーではなくチャンクで持つのは、送信用の一時コピーとの二重持ちを避けて
/// ローカル消費をファイルサイズ1つ分に抑えるためでもある。
@Suite(.serialized)
struct FileStagingTests {

    private func makeTempSource(bytes: Int, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        // 内容を全て0にすると分割の順序ミスを検出できないので、位置ごとに変える
        var payload = Data(count: bytes)
        for index in 0..<bytes {
            payload[index] = UInt8(index % 251)
        }
        try payload.write(to: url)
        return url
    }

    private func stagedRoot() -> URL {
        LargeFileUpload.FileManager.shared.getDocumentsDirectory()
            .appendingPathComponent("uploads", isDirectory: true)
    }

    @Test("stageChunksForUpload はソースをチャンクに分割して保存し、ソース削除後も読める")
    func stagingSurvivesSourceRemoval() throws {
        let src = try makeTempSource(bytes: 4096, name: "photo.dat")
        let sid = "sess-stage-\(UUID().uuidString.prefix(8))"

        let staged = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: src,
            sessionId: sid,
            chunkSize: 1024,
            totalChunks: 4
        )

        #expect(staged.path.hasPrefix(stagedRoot().path))

        // ソースを削除しても
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())

        // 4 チャンクすべてが残っていて、連結すると元の内容に戻る
        var joined = Data()
        for index in 0..<4 {
            let chunkURL = LargeFileUpload.FileManager.shared.chunkFileURL(in: staged, chunkIndex: index)
            let data = try Data(contentsOf: chunkURL)
            #expect(data.count == 1024)
            joined.append(data)
        }
        #expect(joined.count == 4096)
        var contentMatches = true
        for index in 0..<4096 where joined[index] != UInt8(index % 251) {
            contentMatches = false
        }
        #expect(contentMatches)

        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: sid, fileURL: staged)
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test("最終チャンクが chunkSize に満たなくても正しく保存される")
    func lastChunkMayBeShorter() throws {
        let src = try makeTempSource(bytes: 2500, name: "odd.dat")
        let sid = "sess-odd-\(UUID().uuidString.prefix(8))"

        let staged = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: src,
            sessionId: sid,
            chunkSize: 1024,
            totalChunks: 3
        )

        let last = LargeFileUpload.FileManager.shared.chunkFileURL(in: staged, chunkIndex: 2)
        #expect(try Data(contentsOf: last).count == 452)

        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: sid, fileURL: staged)
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
    }

    @Test("cleanupStagedFile は Documents/uploads/ 配下のみ削除し、外部 URL は絶対に触らない")
    func cleanupOnlyTouchesStagedFiles() throws {
        let externalDir = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let external = externalDir.appendingPathComponent("user-photo.jpg")
        try Data(count: 128).write(to: external)

        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: "sid", fileURL: external)
        #expect(FileManager.default.fileExists(atPath: external.path) == true)

        try? FileManager.default.removeItem(at: externalDir)
    }

    @Test("同一 session ID で二度 stage しても作り直される (Resume 経路の冪等性)")
    func stagingIsIdempotent() throws {
        let src1 = try makeTempSource(bytes: 1024, name: "a.bin")
        let src2 = try makeTempSource(bytes: 2048, name: "a.bin")
        let sid = "sess-idem-\(UUID().uuidString.prefix(8))"

        let staged1 = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: src1, sessionId: sid, chunkSize: 1024, totalChunks: 1
        )
        let staged2 = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: src2, sessionId: sid, chunkSize: 1024, totalChunks: 2
        )

        #expect(staged1.path == staged2.path)
        // 1 回目の 1 チャンク構成が残らず、2 回目の 2 チャンク構成になっていること
        let second = LargeFileUpload.FileManager.shared.chunkFileURL(in: staged2, chunkIndex: 1)
        #expect(FileManager.default.fileExists(atPath: second.path) == true)

        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: sid, fileURL: staged2)
        try? FileManager.default.removeItem(at: src1.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: src2.deletingLastPathComponent())
    }

    @Test("送信中のセッションに属さないステージングだけが掃除される")
    func orphanedStagingIsCollected() throws {
        let src = try makeTempSource(bytes: 1024, name: "gc.bin")
        let live = "sess-live-\(UUID().uuidString.prefix(8))"
        let orphan = "sess-orphan-\(UUID().uuidString.prefix(8))"

        let liveDir = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: src, sessionId: live, chunkSize: 1024, totalChunks: 1
        )
        let orphanDir = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: src, sessionId: orphan, chunkSize: 1024, totalChunks: 1
        )

        LargeFileUpload.FileManager.shared.cleanupOrphanedStagingDirectories(activeSessionIds: [live])

        #expect(FileManager.default.fileExists(atPath: liveDir.path) == true)
        #expect(FileManager.default.fileExists(atPath: orphanDir.path) == false)

        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: live, fileURL: liveDir)
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
    }

    @Test("パス要素として危険なセッションIDは弾く")
    func rejectsUnsafeSessionId() {
        for unsafe in ["../escape", "a/b", "", String(repeating: "x", count: 129)] {
            #expect(throws: (any Error).self) {
                _ = try LargeFileUpload.FileManager.shared.stagingDirectory(for: unsafe)
            }
        }
    }
}
