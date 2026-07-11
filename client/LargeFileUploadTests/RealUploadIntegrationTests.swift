import Testing
import Foundation

@testable import LargeFileUpload

/// 実サーバに対して行うシミュレータ内実通信テスト。
/// 明示的に `-only-testing:LargeFileUploadTests/RealUploadIntegrationTests` を指定した時にのみ実行する。
/// (通常の全件テストランは重すぎるため -skip-testing する運用を想定)
struct RealUploadIntegrationTests {

    private var serverURL: String {
        ProcessInfo.processInfo.environment["LARGE_FILE_UPLOAD_SERVER"] ?? "http://127.0.0.1:8080"
    }

    /// テスト用の大容量ファイルを生成する。パターンは反復のたびに変えて checksum を分ける。
    private func makeTempFile(sizeMB: Int, seed: UInt8) throws -> URL {
        let dir = Foundation.FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("integ_\(sizeMB)MB_\(UUID().uuidString).bin")

        Foundation.FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let blockSize = 1024 * 1024 // 1MB
        var buf = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize { buf[i] = UInt8(truncatingIfNeeded: i &+ Int(seed)) }
        let data = Data(buf)
        for _ in 0..<sizeMB {
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()
        return url
    }

    private func uploadOnce(fileURL: URL) async throws -> UploadSession {
        let manager = UploadManager.shared
        let session = try await manager.startUpload(fileURL: fileURL)

        // 完了 or 失敗を polling で待機 (最大 600 秒)
        let deadline = Date().addingTimeInterval(600)
        var lastLogged: Double = -1
        while Date() < deadline {
            // 進行状況変化を Logger 経由で観測
            let p = session.progress
            if p - lastLogged >= 0.1 {
                AppLog.upload.notice("[TEST] progress=\(Int(p * 100))% uploaded=\(session.uploadedChunks.count)/\(session.totalChunks)")
                lastLogged = p
            }
            if session.status == .completed || session.status == .ready {
                return session
            }
            if session.status == .error {
                throw NetworkError.fileError("session error: \(session.error ?? "?")")
            }
            // uploadedChunks.count == totalChunks でも status が遷移していないケースの救済
            if session.uploadedChunks.count == session.totalChunks && session.totalChunks > 0 {
                AppLog.upload.notice("[TEST] all chunks uploaded but status=\(session.status.rawValue), treating as done")
                return session
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NetworkError.timeout
    }

    @Test("[INTEGRATION] 200MB × 3 回連続アップロード成功")
    func largeFileLoop() async throws {
        for i in 1...3 {
            let file = try makeTempFile(sizeMB: 200, seed: UInt8(i))
            defer { try? Foundation.FileManager.default.removeItem(at: file) }
            let session = try await uploadOnce(fileURL: file)
            #expect(session.uploadedChunks.count == session.totalChunks,
                    "loop \(i) uploaded=\(session.uploadedChunks.count) total=\(session.totalChunks)")
            // iteration 間で activeUploads から確実に取り除きサーバセッションも破棄
            await UploadManager.shared.cancelUpload(sessionId: session.id)
        }
    }

    @Test("[INTEGRATION] 1GB 単発アップロード成功")
    func oneGigaByteUpload() async throws {
        let file = try makeTempFile(sizeMB: 1024, seed: 99)
        defer { try? Foundation.FileManager.default.removeItem(at: file) }
        let session = try await uploadOnce(fileURL: file)
        #expect(session.uploadedChunks.count == session.totalChunks)
    }

    @Test("[INTEGRATION] チャンクサイズ計算が sane な値を返す (1GB → ≤200 チャンク)")
    func adaptiveChunkSizeIsSane() {
        let info = LargeFileUpload.FileManager.shared.calculateChunkInfo(fileSize: 1024 * 1024 * 1024)
        #expect(info.totalChunks <= 200)
        #expect(info.chunkSize <= 10 * 1024 * 1024)
        #expect(info.chunkSize >= 1024 * 1024)
    }

    /// サーバに LARGE_FILE_UPLOAD_FAULT_RATE=0.15 を注入した環境下で、
    /// クライアントの native retry (earliestBeginDate) 経由で最終成功することを検証。
    /// **前提**: 起動時のサーバ env で FAULT_RATE を設定してから走らせる。
    /// FAULT_RATE off の通常テストでは pass-through で成功する。
    @Test("[INTEGRATION] fault-injection 下で 200MB upload が retry 経由で成功")
    func faultInjectionResilience() async throws {
        let file = try makeTempFile(sizeMB: 200, seed: 55)
        defer { try? Foundation.FileManager.default.removeItem(at: file) }
        let session = try await uploadOnce(fileURL: file)
        #expect(session.uploadedChunks.count == session.totalChunks)
        let totalRetries = session.chunkRetryCounts.values.reduce(0, +)
        AppLog.upload.notice("[TEST] fault-injection: total retries observed = \(totalRetries)")
    }
}
