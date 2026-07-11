import Testing
import Foundation

@testable import LargeFileUpload

/// 「メモリ上の状態変更」と「ディスクへの永続化」が正しい順序で反映されるかを検証する。
///
/// このスイートは Bug の連鎖を止めるためのもの:
/// - discardSession / moveToHistorySafely / deleteHistoryEntry / clearAllHistory /
///   cleanup / cancelUpload の直後に upload_state.json を読み戻すと変更が反映されている
/// - Force Quit をシミュレート (プロセス再起動なしに新しい UploadManager を作るのは
///   singleton 都合で不可能なため、ファイルの内容そのものを assert する)
@Suite(.serialized)
struct StatePersistenceRaceTests {

    private func stateFileURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("upload_state.json")
    }

    private struct PersistedSnapshot: Codable {
        let history: [UploadSession]
        let active: [UploadSession]
    }

    private func readState() -> PersistedSnapshot? {
        guard let data = try? Data(contentsOf: stateFileURL()) else { return nil }
        return try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
    }

    private func makeSession(id: String) -> UploadSession {
        UploadSession(
            id: id,
            fileName: "race-\(id).bin",
            fileURL: URL(fileURLWithPath: "/tmp/race-\(id).bin"),
            totalChunks: 8,
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
        try? FileManager.default.removeItem(at: stateFileURL())
    }

    /// Force Quit をシミュレートするには、performStateMutationAndPersist の
    /// MainActor Task が完了するまで await する必要がある。yield を挟む。
    private func waitForMainActor() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await MainActor.run { }
        }
    }

    @Test("discardSession の直後にディスクにも反映されている (Force Quit しても復活しない)")
    func discardSessionPersistsSynchronously() async throws {
        await resetState()
        let s = makeSession(id: "sess-discard-race")
        await MainActor.run {
            UploadManager.shared.activeUploads[s.id] = s
        }
        // 初回状態を書く
        await MainActor.run { UploadManager.shared.saveActiveStateSync() }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(readState()?.active.contains(where: { $0.id == s.id }) == true)

        // discard
        await MainActor.run {
            UploadManager.shared.discardSession(sessionId: s.id, reason: "test")
        }
        await waitForMainActor()

        let snap = readState()
        #expect(snap?.active.contains(where: { $0.id == s.id }) == false)
        #expect(snap?.history.contains(where: { $0.id == s.id }) == true)
    }

    @Test("deleteHistoryEntry で履歴から消え、ディスクにも反映されている")
    func deleteHistoryEntryPersists() async throws {
        await resetState()
        let s = makeSession(id: "sess-history-del")
        await MainActor.run {
            UploadManager.shared.uploadHistory.append(s)
            UploadManager.shared.saveActiveStateSync()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(readState()?.history.contains(where: { $0.id == s.id }) == true)

        await MainActor.run {
            UploadManager.shared.deleteHistoryEntry(sessionId: s.id)
        }
        await waitForMainActor()

        let snap = readState()
        #expect(snap?.history.contains(where: { $0.id == s.id }) == false)
    }

    @Test("clearAllHistory で全消去、ディスクにも反映")
    func clearAllHistoryPersists() async throws {
        await resetState()
        let a = makeSession(id: "sess-clear-a")
        let b = makeSession(id: "sess-clear-b")
        await MainActor.run {
            UploadManager.shared.uploadHistory.append(contentsOf: [a, b])
            UploadManager.shared.saveActiveStateSync()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(readState()?.history.count == 2)

        await MainActor.run {
            UploadManager.shared.clearAllHistory()
        }
        await waitForMainActor()

        #expect(readState()?.history.isEmpty == true)
    }

    @Test("複数 discard を連続で行っても全部ディスクに反映される (Bug: 最後の1件だけ残る現象)")
    func multipleDiscardsAllPersist() async throws {
        await resetState()
        let sessions = (0..<3).map { makeSession(id: "sess-multi-\($0)") }
        await MainActor.run {
            for s in sessions {
                UploadManager.shared.activeUploads[s.id] = s
            }
            UploadManager.shared.saveActiveStateSync()
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        await MainActor.run {
            for s in sessions {
                UploadManager.shared.discardSession(sessionId: s.id, reason: "batch")
            }
        }
        await waitForMainActor()
        await waitForMainActor()

        let snap = readState()
        for s in sessions {
            #expect(snap?.active.contains(where: { $0.id == s.id }) == false, "session \(s.id) はディスクの active から消えているはず")
            #expect(snap?.history.contains(where: { $0.id == s.id }) == true, "session \(s.id) はディスクの history に残っているはず")
        }
    }

    @Test("activeUploads に session を追加した直後にも disk へ書ける (Bug: 起動時に復元されない現象)")
    func addingSessionPersistsSynchronously() async throws {
        await resetState()
        let s = makeSession(id: "sess-add")

        await MainActor.run {
            UploadManager.shared.performStateMutationAndPersist {
                UploadManager.shared.activeUploads[s.id] = s
                UploadManager.shared.isUploading = true
            }
        }
        await waitForMainActor()

        let snap = readState()
        #expect(snap?.active.contains(where: { $0.id == s.id }) == true)
    }
}
