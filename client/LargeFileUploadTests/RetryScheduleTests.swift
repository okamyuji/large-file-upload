import Testing
import Foundation

@testable import LargeFileUpload

/// `scheduleChunkRetry` の契約テスト。
/// 実サーバや実 URLSession に依存せず、in-memory session の state 更新のみを検証する。
/// makeUploadTask 実体テストは EarliestBeginDateTests に分離。
/// NetworkService.shared を共有するため直列実行 (.serialized)。
extension SerializedSingletonTests {
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

    /// session.fileURL はステージング済みチャンクのディレクトリを指す。
    /// scheduleChunkRetry はそこから uploadTask を組み立てるので、テストでも同じ形を用意する。
    private func makeStagedSession(id: String, chunks: Int = 5, chunkSize: Int = 20) throws -> UploadSession {
        let size = chunks * chunkSize
        let source = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("rst_\(UUID().uuidString).bin")
        Foundation.FileManager.default.createFile(atPath: source.path, contents: Data(repeating: 3, count: size))
        defer { try? Foundation.FileManager.default.removeItem(at: source) }

        let stagedDir = try LargeFileUpload.FileManager.shared.stageChunksForUpload(
            sourceURL: source, sessionId: id, chunkSize: chunkSize, totalChunks: chunks
        )
        return UploadSession(
            id: id, fileName: source.lastPathComponent, fileURL: stagedDir,
            totalChunks: chunks, fileSize: Int64(size), fileChecksum: "x", chunkSize: chunkSize
        )
    }


    @Test("scheduleChunkRetry: retry 決定で attempt がインクリメントされる (fileURL 実在で成功パス)")
    func retryIncrementsAttempt() throws {
        // 実 file を用意
        let session = try makeStagedSession(id: "sess-retry")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }
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

    @Test("scheduleChunkRetry: 上限以内の Retry-After は指定どおりの時刻に予約する")
    func retryAfterUsesServerValue() throws {
        let session = try makeStagedSession(id: "sess-cap")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }
        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 1, decision: .retryAfter(120))
        if let target = session.chunkNextRetryAt[1] {
            let delta = target.timeIntervalSinceNow
            #expect(delta <= 120.5, "delta=\(delta)")
            #expect(delta >= 119.0, "delta=\(delta)")
        } else {
            Issue.record("chunkNextRetryAt not set")
        }

        ns.activeUploadSessions.removeValue(forKey: session.id)
    }

    /// 上限を超える指定を短い時間へ切り詰めると、サーバが求めた時刻より早く再送してしまう。
    /// 早める代わりに自動リトライを打ち切り、次回起動時の突き合わせに委ねる。
    @Test("scheduleChunkRetry: 自動で待てる上限を超える Retry-After は打ち切る")
    func retryAfterBeyondLimitStopsAutoRetry() throws {
        let session = try makeStagedSession(id: "sess-toolong")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }
        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 1, decision: .retryAfter(3600))

        #expect(session.chunkNextRetryAt[1] == nil, "早い時刻での再送を予約してはいけない")
        #expect(session.status == .error)

        ns.activeUploadSessions.removeValue(forKey: session.id)
    }

    @Test("scheduleChunkRetry: 上限到達 → .error 遷移 + retry state クリア")
    func exhaustionTransitionsToError() throws {
        let session = try makeStagedSession(id: "sess-exhaust")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }
        // 既に attempt=5 まで消費した状態を preload
        session.chunkRetryCounts[3] = 5

        let ns = NetworkService.shared
        ns.activeUploadSessions[session.id] = session

        // attempt=6 で maxAttempts=5 を超える → 上限到達
        ns.scheduleChunkRetry(sessionId: session.id, chunkIndex: 3, decision: .retry)

        #expect(session.status == .error)
        // 回数を消すと次の突き合わせで 1 から数え直しになり、上限が効かなくなる
        #expect(session.chunkRetryCounts[3] == 5, "上限到達後も累積回数は残す")
        #expect(session.chunkNextRetryAt[3] == nil)
        #expect(session.autoResumeBlocked, "自動再開を止める")

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
        let session = try makeStagedSession(id: "sess-accum")
        defer { LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL) }
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
}
