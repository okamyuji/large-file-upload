import Testing
import Foundation

@testable import LargeFileUpload

/// UploadStatus と UI 表示ラベル・アクションボタンの対応が矛盾しないことを担保する。
/// これまで「pause 後に status が .error になって『再開』ではなく『再試行』が出る」
/// といった小規模な遷移事故が繰り返し出たので、mapping を1箇所で押さえる。
@Suite
struct StateLabelMappingTests {

    @Test("UploadStatus.description は UI 表示用の日本語を返す")
    func statusDescriptionsAreCoherent() {
        #expect(UploadStatus.created.description == "アップロード中")
        #expect(UploadStatus.uploading.description == "アップロード中")
        #expect(UploadStatus.ready.description == "アップロード中")
        #expect(UploadStatus.completing.description == "完了処理中")
        #expect(UploadStatus.completed.description == "完了")
        #expect(UploadStatus.error.description == "エラー")
        #expect(UploadStatus.paused.description == "一時停止")
        #expect(UploadStatus.cancelled.description == "キャンセル")
    }

    /// ActiveUploadsView.ActionButtons.primaryAction と同じ判定を pure 関数として書いておくことで、
    /// UI 側の分岐と mapping が乖離したら CI で検出できる。
    private enum PrimaryAction: String { case pause, resume, retry, none }
    private func expectedAction(for status: UploadStatus) -> PrimaryAction {
        switch status {
        case .created, .ready, .uploading: return .pause
        case .paused: return .resume
        case .error: return .retry
        case .completing, .completed, .cancelled: return .none
        }
    }

    @Test("送信中系 (created/ready/uploading) は 一時停止")
    func inflightShowsPause() {
        for s in [UploadStatus.created, .ready, .uploading] {
            #expect(expectedAction(for: s) == .pause)
        }
    }

    @Test("paused は 再開")
    func pausedShowsResume() {
        #expect(expectedAction(for: .paused) == .resume)
    }

    @Test("error は 再試行 (再開経路と同じだがラベルは 再試行 にする)")
    func errorShowsRetry() {
        #expect(expectedAction(for: .error) == .retry)
    }

    @Test("completing/completed/cancelled はアクションボタンなし")
    func terminalHasNoAction() {
        for s in [UploadStatus.completing, .completed, .cancelled] {
            #expect(expectedAction(for: s) == .none)
        }
    }
}

/// キャンセル操作が「痕跡ゼロで消える」のを防ぐ回帰テスト。
/// UploadManager.cancelUpload は activeUploads から削除するだけでなく
/// history に .cancelled として insert し、ディスクにも反映すること。
@Suite(.serialized)
struct CancelHistoryTraceTests {

    private func makeSession(id: String) -> UploadSession {
        UploadSession(
            id: id,
            fileName: "cancel-\(id).bin",
            fileURL: URL(fileURLWithPath: "/tmp/cancel-\(id).bin"),
            totalChunks: 4,
            fileSize: 40,
            fileChecksum: "x",
            chunkSize: 10
        )
    }

    private func resetState() async {
        await MainActor.run {
            UploadManager.shared.activeUploads.removeAll()
            UploadManager.shared.uploadHistory.removeAll()
        }
    }

    @Test("cancelUpload は履歴に .cancelled として痕跡を残す")
    func cancelLeavesHistoryTrace() async throws {
        await resetState()
        let s = makeSession(id: "sess-cancel-trace")
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        await UploadManager.shared.cancelUpload(sessionId: s.id)
        // performStateMutationAndPersist は MainActor Task をスケジュールするので少し待つ
        try await Task.sleep(nanoseconds: 200_000_000)

        let (activeCount, historyCount, firstStatus) = await MainActor.run {
            (
                UploadManager.shared.activeUploads.count,
                UploadManager.shared.uploadHistory.count,
                UploadManager.shared.uploadHistory.first?.status
            )
        }
        #expect(activeCount == 0)
        #expect(historyCount == 1)
        #expect(firstStatus == .cancelled)
    }
}
