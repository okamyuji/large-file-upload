import Testing
import Foundation

@testable import LargeFileUpload

/// Bug A 対策: happy-path のチャンク完了時にも永続化が走ることを担保する。
/// persistHappyPath の判定ロジック (initial=無条件 / complete=無条件 / それ以外は 2s デバウンス) を検証する。
extension SerializedSingletonTests {
@Suite(.serialized)
struct HappyPathPersistenceTests {

    private func makeSession(id: String = "sess-happy", total: Int) -> UploadSession {
        UploadSession(
            id: id,
            fileName: "big.bin",
            fileURL: URL(fileURLWithPath: "/tmp/big.bin"),
            totalChunks: total,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 10
        )
    }

    /// upload_state.json が最後に書かれた時刻(mtime)。ファイルが無ければ nil。
    private func stateMtime() -> Date? {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("upload_state.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// 各テストで前回セッションが残っていないよう、activeUploads/lastPersistAt を初期化する。
    private func resetState() async {
        await MainActor.run {
            UploadManager.shared.activeUploads.removeAll()
            UploadManager.shared.uploadHistory.removeAll()
        }
    }

    @Test("初回チャンク到達 (uploadedChunks.count == 1) は無条件で save が発火する")
    func initialChunkPersistsUnconditionally() async throws {
        await resetState()
        let s = makeSession(id: "sess-initial", total: 10)
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        s.markChunkUploaded(0)
        let before = stateMtime()
        try await Task.sleep(nanoseconds: 20_000_000)
        NetworkService.shared.persistHappyPath(sessionId: s.id, session: s)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = stateMtime()

        #expect(after != nil)
        if let before, let after {
            #expect(after > before)
        }
    }

    @Test("完了 (isComplete) は無条件で save が発火する")
    func completionPersistsUnconditionally() async throws {
        await resetState()
        let s = makeSession(id: "sess-complete", total: 3)
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        // 3チャンクすべてマークして isComplete を true に
        for i in 0..<3 { s.markChunkUploaded(i) }
        #expect(s.isComplete == true)

        let before = stateMtime()
        try await Task.sleep(nanoseconds: 20_000_000)
        NetworkService.shared.persistHappyPath(sessionId: s.id, session: s)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = stateMtime()

        #expect(after != nil)
        if let before, let after {
            #expect(after > before)
        }
    }

    @Test("中間チャンク (initial でも complete でもない) は2秒未満の連続呼び出しでは 1 回しか save されない")
    func middleChunkDebounces() async throws {
        await resetState()
        let s = makeSession(id: "sess-debounce", total: 100)
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        // 初回: 1 chunk (無条件 save)
        s.markChunkUploaded(0)
        NetworkService.shared.persistHappyPath(sessionId: s.id, session: s)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after1 = stateMtime()

        // 2 chunk: 初回でも complete でもない、かつデバウンス閾値内 → save スキップ
        s.markChunkUploaded(1)
        NetworkService.shared.persistHappyPath(sessionId: s.id, session: s)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after2 = stateMtime()

        // 3 chunk も同様
        s.markChunkUploaded(2)
        NetworkService.shared.persistHappyPath(sessionId: s.id, session: s)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after3 = stateMtime()

        // after1/after2/after3 が同じ = デバウンスが効いている
        #expect(after1 == after2)
        #expect(after2 == after3)
    }
}
}
