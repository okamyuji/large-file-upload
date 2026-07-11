import Testing
import Foundation

@testable import LargeFileUpload

/// Bug B UI 対策: discardSession(sessionId:reason:) が
/// - activeUploads から即除去
/// - uploadHistory に error status で追加
/// - 永続化される
/// ことを検証する。
extension SerializedSingletonTests {
@Suite(.serialized)
struct DiscardSessionTests {

    private func makeSession(id: String) -> UploadSession {
        UploadSession(
            id: id,
            fileName: "orphan.bin",
            fileURL: URL(fileURLWithPath: "/tmp/orphan.bin"),
            totalChunks: 5,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 20
        )
    }

    private func resetState() async {
        await MainActor.run {
            UploadManager.shared.activeUploads.removeAll()
            UploadManager.shared.uploadHistory.removeAll()
        }
    }

    @Test("activeUploads から除去され、履歴に error status で残る")
    func discardMovesFromActiveToHistory() async throws {
        await resetState()
        let s = makeSession(id: "sess-discard-1")
        await MainActor.run { UploadManager.shared.activeUploads[s.id] = s }

        await MainActor.run {
            UploadManager.shared.discardSession(sessionId: s.id, reason: "test-removed")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let (activeCount, historyCount, historyFirstStatus) = await MainActor.run {
            (
                UploadManager.shared.activeUploads.count,
                UploadManager.shared.uploadHistory.count,
                UploadManager.shared.uploadHistory.first?.status
            )
        }
        #expect(activeCount == 0)
        #expect(historyCount == 1)
        #expect(historyFirstStatus == .error)
    }

    @Test("存在しないセッションを discard しても副作用なし")
    func discardNonExistentIsSafe() async throws {
        await resetState()
        await MainActor.run {
            UploadManager.shared.discardSession(sessionId: "nope", reason: "ghost")
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let (activeCount, historyCount) = await MainActor.run {
            (
                UploadManager.shared.activeUploads.count,
                UploadManager.shared.uploadHistory.count
            )
        }
        #expect(activeCount == 0)
        #expect(historyCount == 0)
    }
}
}
