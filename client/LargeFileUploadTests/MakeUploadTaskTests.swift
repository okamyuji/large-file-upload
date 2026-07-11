import Testing
import Foundation

@testable import LargeFileUpload

struct MakeUploadTaskTests {

    private func makeTempFile(size: Int = 100) throws -> URL {
        let url = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("mut_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: size))
        return url
    }

    @Test("makeUploadTask: earliestBeginDate=nil でも作成成功、プロパティはデフォルト")
    func noEarliestBeginDate() throws {
        let file = try makeTempFile(size: 100)
        defer { try? Foundation.FileManager.default.removeItem(at: file) }

        let session = UploadSession(
            id: "sess-mut1", fileName: file.lastPathComponent, fileURL: file,
            totalChunks: 5, fileSize: 100, fileChecksum: "x", chunkSize: 20
        )
        let task = try NetworkService.shared.makeUploadTask(session: session, chunkIndex: 0, earliestBeginDate: nil)
        // earliestBeginDate をセットしていなければ optional は nil または distant past
        if let ebd = task.earliestBeginDate {
            #expect(ebd.timeIntervalSince1970 < 1 || ebd == Date.distantPast)
        }
        task.cancel()  // resume 前に cancel は OK
    }

    @Test("makeUploadTask: earliestBeginDate を指定すると task.earliestBeginDate に一致")
    func withEarliestBeginDate() throws {
        let file = try makeTempFile(size: 100)
        defer { try? Foundation.FileManager.default.removeItem(at: file) }

        let session = UploadSession(
            id: "sess-mut2", fileName: file.lastPathComponent, fileURL: file,
            totalChunks: 5, fileSize: 100, fileChecksum: "x", chunkSize: 20
        )
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
