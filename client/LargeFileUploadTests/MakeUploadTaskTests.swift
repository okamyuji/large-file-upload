import Testing
import Foundation

@testable import LargeFileUpload

extension SerializedSingletonTests {
struct MakeUploadTaskTests {

    /// session.fileURL はステージング済みチャンクを収めたディレクトリを指す。
    /// makeUploadTask はそのチャンクをそのまま送るので、テストでも同じ形を用意する。
    private func makeStagedSession(id: String, size: Int = 100, chunkSize: Int = 20) throws -> UploadSession {
        let source = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("mut_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: source.path, contents: Data(repeating: 7, count: size))
        defer { try? Foundation.FileManager.default.removeItem(at: source) }

        let totalChunks = (size + chunkSize - 1) / chunkSize
        let stagedDir = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: source, sessionId: id, chunkSize: chunkSize, totalChunks: totalChunks
        )
        return UploadSession(
            id: id, fileName: source.lastPathComponent, fileURL: stagedDir,
            totalChunks: totalChunks, fileSize: Int64(size), fileChecksum: "x", chunkSize: chunkSize
        )
    }

    @Test("makeUploadTask: earliestBeginDate=nil でも作成成功、プロパティはデフォルト")
    func noEarliestBeginDate() throws {
        let session = try makeStagedSession(id: "sess-mut1")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }

        let task = try NetworkService.shared.makeUploadTask(session: session, chunkIndex: 0, earliestBeginDate: nil)
        // earliestBeginDate をセットしていなければ optional は nil または distant past
        if let ebd = task.earliestBeginDate {
            #expect(ebd.timeIntervalSince1970 < 1 || ebd == Date.distantPast)
        }
        task.cancel()  // resume 前に cancel は OK
    }

    @Test("makeUploadTask: earliestBeginDate を指定すると task.earliestBeginDate に一致")
    func withEarliestBeginDate() throws {
        let session = try makeStagedSession(id: "sess-mut2")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }

        let target = Date().addingTimeInterval(120)
        let task = try NetworkService.shared.makeUploadTask(session: session, chunkIndex: 1, earliestBeginDate: target)
        if let ebd = task.earliestBeginDate {
            #expect(abs(ebd.timeIntervalSince(target)) < 1.0)
        } else {
            Issue.record("earliestBeginDate was nil after setting")
        }
        task.cancel()
    }

    @Test("extractSessionId: URL から sessionId を抽出")
    func extractSessionIdFromURL() {
        let url = URL(string: "http://127.0.0.1:8080/upload/session/session_abc/chunk/3")!
        #expect(NetworkService.extractSessionId(from: url) == "session_abc")
    }

    @Test("extractSessionChunkKey: URL から sessionId:chunkIndex を抽出")
    func extractKeyFromURL() {
        let url = URL(string: "http://127.0.0.1:8080/upload/session/session_xyz/chunk/7")!
        #expect(NetworkService.extractSessionChunkKey(from: url) == "session_xyz:7")
    }

    @Test("extractSessionId: 不正 URL は nil")
    func extractFromMalformedURL() {
        let url = URL(string: "http://127.0.0.1:8080/other/path")!
        #expect(NetworkService.extractSessionId(from: url) == nil)
        #expect(NetworkService.extractSessionChunkKey(from: url) == nil)
    }
}
}
