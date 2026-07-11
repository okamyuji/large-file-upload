import Testing
import Foundation

@testable import LargeFileUpload

/// pause / resume の状態遷移と、Force Quit 後に queue を作り直せることを検証する。
///
/// この suite は「進行中に出てくるが再開が効かない」バグへの回帰テスト。
/// 実サーバに依存する部分 (resumeSessionFromServer の HTTP 呼び出し) は
/// PauseResumeIntegrationTests.swift で扱い、ここではローカル状態のみを対象にする。
extension SerializedSingletonTests {
@Suite(.serialized)
struct PauseResumeTests {

    private func makeSession(id: String, total: Int = 8) -> UploadSession {
        UploadSession(
            id: id,
            fileName: "pr-\(id).bin",
            fileURL: URL(fileURLWithPath: "/tmp/pr-\(id).bin"),
            totalChunks: total,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 12
        )
    }

    private func resetState() async {
        await MainActor.run {
            UploadManager.shared.activeUploads.removeAll()
            UploadManager.shared.uploadHistory.removeAll()
        }
    }

    @Test("pauseUpload で session.status が .paused になる")
    func pauseTransitionsStatus() async throws {
        await resetState()
        let s = makeSession(id: "sess-pause")
        s.updateStatus(.uploading)
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        await MainActor.run {
            UploadManager.shared.pauseUpload(sessionId: s.id)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(s.status == .paused)
    }

    @Test("存在しないセッションを pause しても副作用なし")
    func pauseNonExistentIsSafe() async throws {
        await resetState()
        // 例外なく完了することが期待動作
        await MainActor.run {
            UploadManager.shared.pauseUpload(sessionId: "ghost")
        }
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    @Test("pause 後に resume を呼ぶと status が .paused から離れる (再開経路に載る)")
    func resumeAfterPauseFlipsStatus() async throws {
        await resetState()
        let s = makeSession(id: "sess-resume-flip")
        s.updateStatus(.uploading)
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        await MainActor.run { UploadManager.shared.pauseUpload(sessionId: s.id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(s.status == .paused)

        // resumeUpload は内部で Task を立てて resumeSessionFromServer を呼ぶ。
        // Simulator にはサーバが居ないため HTTP は失敗して handleUploadErrorSafely 経由で
        // status が .error に落ちる可能性があるが、少なくとも .paused から遷移していることを確認する。
        try? await UploadManager.shared.resumeUpload(sessionId: s.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(s.status != .paused, "resume 経路に載ったら .paused から離れる")
    }

    @Test("Force Quit をシミュレート: session 復元後に resumeUpload しても crash しない")
    func resumeAfterRestoreDoesNotCrash() async throws {
        await resetState()
        // ディスクから復元されたセッションを模す (uploadQueue はメモリ辞書なので存在しない)
        let s = makeSession(id: "sess-restored", total: 10)
        s.updateStatus(.error)
        s.uploadedChunks = Set([0, 1, 2, 3]) // 途中まで送信済み
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        // resumeUpload は networkService.resumeSessionFromServer を呼ぶ。
        // ここでは HTTP 呼び出しが失敗しても crash しないこと、
        // 呼び出し自体が例外を投げないことを確認する (エラー処理は handleUploadErrorSafely 側)。
        try? await UploadManager.shared.resumeUpload(sessionId: s.id)
        try await Task.sleep(nanoseconds: 200_000_000)

        // 状態は .uploading 遷移するか、または handleUploadErrorSafely で .error に戻る。
        // 少なくとも UI がハングする状態 (.completing 等) には陥っていないこと。
        #expect([.uploading, .error].contains(s.status))
    }

    @Test("UploadQueue の chunks 初期化子は missing チャンクのみを積む")
    func uploadQueueChunksInitializerRestrictsList() async throws {
        // UploadQueue は private class だが NetworkService の resumeSessionFromServer から
        // 間接的に使われる。ここでは仕様の意図を明文化するプロパティテストとして書く:
        // 「missingChunks = [3, 7, 9] のセッションを resume したら、
        //   queue には 3 チャンク分しか積まれない (0..<total ではない)」
        //
        // 直接 UploadQueue をテストするには internal 化が必要なので、
        // 代わりに session.uploadedChunks が missing の補集合になるかで代替検証する。
        let s = makeSession(id: "sess-queue", total: 10)
        NetworkService.syncUploadedChunks(session: s, missingChunks: [3, 7, 9], totalChunks: 10)
        #expect(s.uploadedChunks == Set([0, 1, 2, 4, 5, 6, 8]))
        #expect(s.progress == 0.7)
    }
}
}
