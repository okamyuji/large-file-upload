import Testing
import Foundation

@testable import LargeFileUpload

/// `scheduleChunkRetry` の契約テスト。
/// 実サーバや実 URLSession に依存せず、in-memory session の state 更新のみを検証する。
/// makeUploadTask 実体テストは EarliestBeginDateTests に分離。
/// NetworkService.shared を共有するため直列実行 (.serialized)。
@Suite(.serialized)
struct RetryScheduleTests {

    private func makeSession(id: String = "sess-1", chunks: Int = 5) -> UploadSession {
        UploadSession(
            id: id,
            fileName: "f.bin",
            fileURL: URL(fileURLWithPath: "/tmp/nonexistent.bin"),
            totalChunks: chunks,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 20
        )
    }

    /// makeUploadTask は fileURL を open するため、in-memory テストでは session を activeUploadSessions に
    /// 登録せずに scheduleChunkRetry を呼ぶと「session not found」で早期 return する。
    /// このテストでは fileURL が実在しないため makeUploadTask は失敗 → 上限到達扱いにフォールバックする。
    /// state 遷移として観測可能。

    @Test("scheduleChunkRetry: retry 決定で attempt がインクリメントされる (fileURL 実在で成功パス)")
    func retryIncrementsAttempt() throws {
        // 実 file を用意
        let tempFile = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("rst_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: tempFile.path, contents: Data(repeating: 0, count: 100))
        defer { try? Foundation.FileManager.default.removeItem(at: tempFile) }

        let session = UploadSession(
            id: "sess-retry",
            fileName: tempFile.lastPathComponent,
            fileURL: tempFile,
            totalChunks: 5,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 20
        )
        // NetworkService に登録
        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 2, decision: .retry)

        #expect(session.chunkRetryCounts[2] == 1)
        #expect(session.chunkNextRetryAt[2] != nil)
        if let target = session.chunkNextRetryAt[2] {
            // baseDelay=1.0 (±jitter 20%)、+ 少しの実行時間
            let delta = target.timeIntervalSinceNow
            #expect(delta > 0.5 && delta < 5.0, "delta=\(delta)")
        }

        // cleanup
        ns.activeUploadSessions.removeValue(forKey: session.id)
    }

    @Test("scheduleChunkRetry: retryAfter は maxRetryAfterCap=300 でクランプ")
    func retryAfterIsCapped() throws {
        let tempFile = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("rst_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: tempFile.path, contents: Data(repeating: 0, count: 100))
        defer { try? Foundation.FileManager.default.removeItem(at: tempFile) }

        let session = UploadSession(
            id: "sess-cap", fileName: tempFile.lastPathComponent, fileURL: tempFile,
            totalChunks: 5, fileSize: 100, fileChecksum: "x", chunkSize: 20
        )
        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        // 1000 秒指定 → 300 にクランプ
        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 1, decision: .retryAfter(1000))
        if let target = session.chunkNextRetryAt[1] {
            let delta = target.timeIntervalSinceNow
            #expect(delta <= 300.5, "delta=\(delta)")
            #expect(delta >= 299.0, "delta=\(delta)")
        } else {
            Issue.record("chunkNextRetryAt not set")
        }

        ns.activeUploadSessions.removeValue(forKey: session.id)
    }

    @Test("scheduleChunkRetry: 上限到達 → .error 遷移 + retry state クリア")
    func exhaustionTransitionsToError() throws {
        let tempFile = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("rst_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: tempFile.path, contents: Data(repeating: 0, count: 100))
        defer { try? Foundation.FileManager.default.removeItem(at: tempFile) }

        let session = UploadSession(
            id: "sess-exhaust", fileName: tempFile.lastPathComponent, fileURL: tempFile,
            totalChunks: 5, fileSize: 100, fileChecksum: "x", chunkSize: 20
        )
        // 既に attempt=5 まで消費した状態を preload
        session.chunkRetryCounts[3] = 5

        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        // attempt=6 で maxAttempts=5 を超える → 上限到達
        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 3, decision: .retry)

        #expect(session.status == .error)
        #expect(session.chunkRetryCounts[3] == nil, "上限到達で retryCounts はクリアされる")
        #expect(session.chunkNextRetryAt[3] == nil)

        ns.activeUploadSessions.removeValue(forKey: session.id)
    }

    @Test("scheduleChunkRetry: 未知の sessionId は no-op")
    func unknownSessionIsNoop() {
        let ns = NetworkService.shared
        // 何も起きない (crash しない)
        ns.scheduleChunkRetry(sessionId: "sess-does-not-exist", chunkIndex: 0, decision: .retry)
    }

    @Test("scheduleChunkRetry: 同一 chunk への複数回呼び出しで attempt が積算")
    func multipleCallsAccumulate() throws {
        let tempFile = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("rst_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: tempFile.path, contents: Data(repeating: 0, count: 100))
        defer { try? Foundation.FileManager.default.removeItem(at: tempFile) }

        let session = UploadSession(
            id: "sess-accum", fileName: tempFile.lastPathComponent, fileURL: tempFile,
            totalChunks: 5, fileSize: 100, fileChecksum: "x", chunkSize: 20
        )
        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 0, decision: .retry)
        #expect(session.chunkRetryCounts[0] == 1)
        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 0, decision: .retry)
        #expect(session.chunkRetryCounts[0] == 2)
        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 0, decision: .retry)
        #expect(session.chunkRetryCounts[0] == 3)

        ns.activeUploadSessions.removeValue(forKey: session.id)
    }
}
