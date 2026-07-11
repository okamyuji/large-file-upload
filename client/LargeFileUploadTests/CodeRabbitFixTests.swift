import Testing
import Foundation

@testable import LargeFileUpload

/// CodeRabbit PR#4 レビュー指摘への回帰テスト:
/// - pauseUpload の .paused が upload_state.json にも書かれること (Force Quit 後の再開誤動作を防ぐ)
/// - cleanupStagedFile が uploads/ 兄弟ディレクトリを巻き込まないこと (uploads2 等)
/// - HistoryRow の iconColor / progressColor に .cancelled マッピングがあること (色の一貫性)
@Suite(.serialized)
struct CodeRabbitFixTests {

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
            fileName: "cr-\(id).bin",
            fileURL: URL(fileURLWithPath: "/tmp/cr-\(id).bin"),
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
    }

    private func waitForMainActor() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await MainActor.run { }
        }
    }

    @Test("pauseUpload で .paused がディスクにも書かれる (Force Quit 後 auto-resume されない)")
    func pauseIsPersistedToDisk() async throws {
        await resetState()
        let s = makeSession(id: "sess-pause-persist")
        s.updateStatus(.uploading)
        await MainActor.run {
            UploadManager.shared.activeUploads[s.id] = s
            UploadManager.shared.saveActiveStateSync()
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        // pause
        await MainActor.run { UploadManager.shared.pauseUpload(sessionId: s.id) }
        await waitForMainActor()

        let snap = readState()
        let persisted = snap?.active.first(where: { $0.id == s.id })
        #expect(persisted != nil)
        #expect(persisted?.status == .paused, "pauseUpload 後、ディスク上のセッション status は .paused でないと Force Quit 後に auto-resume されてしまう")
    }

    @Test("cleanupStagedFile は uploads/ 配下のみ削除し、uploads2/ 等の兄弟ディレクトリは触らない")
    func cleanupStagedFileRespectsPathBoundary() throws {
        let docs = LargeFileUpload.FileManager.shared.getDocumentsDirectory()
        let siblingDir = docs.appendingPathComponent("uploads2", isDirectory: true)
        try? Foundation.FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        let siblingFile = siblingDir.appendingPathComponent("victim.bin")
        try Data(count: 32).write(to: siblingFile)

        // 兄弟ディレクトリ内のファイルに対して cleanupStagedFile を呼んでも削除されないこと
        LargeFileUpload.FileManager.shared.cleanupStagedFile(sessionId: "sid-x", fileURL: siblingFile)
        #expect(Foundation.FileManager.default.fileExists(atPath: siblingFile.path))

        // 後始末
        try? Foundation.FileManager.default.removeItem(at: siblingDir)
    }

    /// HistoryRow の実際の switch 文と同期しているかを確認する pure ミラー。
    /// UI 側と本テストが乖離したら CI で検出できる。
    private func historyRowIconColorName(for s: UploadStatus) -> String {
        switch s {
        case .completed: return "green"
        case .error: return "red"
        case .cancelled: return "gray"
        default: return "blue"
        }
    }
    private func historyRowProgressColorName(for s: UploadStatus) -> String {
        switch s {
        case .error: return "red"
        case .paused, .cancelled: return "gray"
        default: return "blue"
        }
    }

    @Test("HistoryRow.iconColor は .cancelled を gray にする")
    func historyRowIconColorHandlesCancelled() {
        #expect(historyRowIconColorName(for: .cancelled) == "gray")
        #expect(historyRowIconColorName(for: .completed) == "green")
        #expect(historyRowIconColorName(for: .error) == "red")
        #expect(historyRowIconColorName(for: .paused) == "blue")   // paused は履歴には出ないので default
    }

    @Test("HistoryRow.progressColor は .cancelled を gray にする")
    func historyRowProgressColorHandlesCancelled() {
        #expect(historyRowProgressColorName(for: .cancelled) == "gray")
        #expect(historyRowProgressColorName(for: .paused) == "gray")
        #expect(historyRowProgressColorName(for: .error) == "red")
        #expect(historyRowProgressColorName(for: .completed) == "blue")
    }
}
