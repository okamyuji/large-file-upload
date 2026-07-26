import Foundation
import UIKit
import UserNotifications

class UploadManager: ObservableObject {
    static let shared = UploadManager()

    // MARK: - Properties

    @Published var activeUploads: [String: UploadSession] = [:]
    @Published var uploadHistory: [UploadSession] = []
    @Published var isUploading = false

    // Computed properties for ContentView
    var allSessions: [UploadSession] {
        Array(activeUploads.values) + uploadHistory
    }

    var completedUploads: [UploadSession] {
        uploadHistory.filter { $0.status == .completed }
    }

    private let networkService = NetworkService.shared
    private let fileManager = FileManager.shared
    
    // アプリ状態管理（重要：MainActor使用を制御）
    private var isAppInBackground = false

    // MARK: - Initialization

    private init() {
        setupNotifications()
        loadUploadHistory()
        // v3: 起動時に OS 所有タスク reconcile + サーバ SoT 突き合わせで
        // 完了扱いの自動治癒 / 未送信チャンクの再投入 / 期限切れセッションの破棄を行う
        Task {
            await NetworkService.shared.reconcileWithServer()
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        isAppInBackground = true
        AppLog.upload.notice("🌙 アップロードマネージャー: アプリがバックグラウンドに移行 - MainActor使用停止")
        // BackgroundURLSessionを使用しているため、UIApplication.beginBackgroundTaskは不要
        AppLog.upload.notice("🔗 [BACKGROUND SESSION] BackgroundURLSessionがアップロードを継続します")
    }

    @objc private func appWillEnterForeground() {
        isAppInBackground = false
        AppLog.upload.notice("☀️ アップロードマネージャー: アプリがフォアグラウンドに復帰 - UI更新再開")
        // BackgroundURLSessionを使用しているため、UIApplication.endBackgroundTaskは不要
        AppLog.upload.notice("🔗 [FOREGROUND RESUME] BackgroundURLSessionから状態同期を開始")

        // アクティブなアップロードの状態を更新（フォアグラウンド専用）
        Task {
            await refreshActiveUploads()
        }
    }

    @objc private func appWillTerminate() {
        AppLog.upload.notice("アップロードマネージャー: アプリが終了")
        saveUploadHistory()
    }

    // MARK: - Safe State Management (バックグラウンド完全対応)

    private func updateStateSafely(_ updateBlock: @escaping () -> Void) {
        // isAppInBackgroundフラグのみ使用（MainActor安全）
        if isAppInBackground {
            // バックグラウンド時：MainActor使用禁止、直接更新
            updateBlock()
            AppLog.upload.notice("🌙 [BACKGROUND] UploadManager状態更新: MainActor回避")
        } else {
            // フォアグラウンド時：UI更新のためMainActor使用
            Task {
                await MainActor.run {
                    updateBlock()
                }
            }
        }
    }

    private func updateSessionSafely(_ session: UploadSession, _ updateBlock: @escaping (UploadSession) -> Void) {
        // isAppInBackgroundフラグのみ使用（MainActor安全）
        if isAppInBackground {
            // バックグラウンド時：直接更新のみ（UI更新不要）
            updateBlock(session)
            AppLog.upload.notice("🌙 [BACKGROUND] セッション更新: \(session.id)")
        } else {
            // フォアグラウンド時：UI更新も含める
            updateBlock(session)
            Task {
                await MainActor.run {
                    // UI更新のための追加処理
                    objectWillChange.send()
                }
            }
        }
    }

    // MARK: - Session Management

    func cancelAllUploads() async {
        let sessionIds = Array(activeUploads.keys)
        
        await withTaskGroup(of: Void.self) { group in
            for sessionId in sessionIds {
                group.addTask {
                    await self.cancelUpload(sessionId: sessionId)
                }
            }
        }
    }

    func retryFailedUploads() async {
        for sessionId in activeUploads.values.filter({ $0.status == .error }).map(\.id) {
            try? await resumeUpload(sessionId: sessionId)
        }
    }

    private func refreshActiveUploads() async {
        // フォアグラウンド専用メソッド（MainActor安全）
        guard !isAppInBackground else {
            AppLog.upload.notice("🌙 [BACKGROUND] refreshActiveUploads スキップ - バックグラウンド時はUI更新不要")
            return
        }

        // フォアグラウンド復帰でも起動時と同じチャンク単位の突き合わせを通す。
        // セッションごとに resumeSessionFromServer を呼ぶ作りだと、OS 側で送信中のタスクを
        // 毎回すべてキャンセルして積み直すことになる。さらに一時停止中のセッションまで
        // ユーザーの意思に反して再開してしまう。
        await networkService.reconcileWithServer()

        await MainActor.run {
            self.updateUploadingStatus()
        }
    }

    private func updateUploadingStatus() {
        isUploading = activeUploads.values.contains { $0.status == .uploading }
    }

    func getUploadStatistics() -> (
        active: Int, completed: Int, failed: Int, totalSize: Int64
    ) {
        let active = activeUploads.count
        let completed = completedUploads.count
        let failed = activeUploads.values.filter { $0.status == .error }.count
        let totalSize = allSessions.reduce(0) { $0 + $1.fileSize }

        return (
            active: active, completed: completed, failed: failed,
            totalSize: totalSize
        )
    }

    // MARK: - Upload Management (バックグラウンド安全)

    func startUpload(fileURL: URL) async throws -> UploadSession {
        AppLog.upload.notice("🚀 アップロード開始: \(fileURL.lastPathComponent)")

        // ファイル検証
        try fileManager.validateFileForUpload(url: fileURL)

        // セッション作成
        let session = try await networkService.createUploadSession(
            fileURL: fileURL
        )

        // セッションの登録と永続化は createUploadSession の中で、ステージングより前に
        // 同期的に済ませている (registerNewSession)。ここで改めて積むと、保存完了を
        // 待たないまま送信を始めることになるので何もしない。

        // BackgroundURLSessionでアップロード開始
        try await networkService.startUpload(session: session)
        
        AppLog.upload.notice("✅ BackgroundURLSessionアップロード開始: \(session.fileName)")
        return session
    }

    /// 新規セッションを手元に登録し、保存が終わるまで待つ。
    ///
    /// サーバにセッションを作った直後、まだ手元に記録が無い時間帯に強制終了されると、
    /// サーバにだけセッションが残って次回起動の突き合わせ対象から漏れる。
    /// 保存の完了を待ってから先へ進めることで、その空白を無くす。
    func registerNewSession(_ session: UploadSession) async throws {
        try await MainActor.run {
            self.activeUploads[session.id] = session
            self.isUploading = true
            do {
                try self.writeUploadState()
            } catch {
                // 記録できないまま送信を始めると、強制終了で行方不明のセッションになる。
                // 呼び出し元がサーバ側を片付けられるよう、登録を取り消してから投げ返す。
                self.activeUploads.removeValue(forKey: session.id)
                self.updateUploadingStatus()
                throw error
            }
        }
    }

    /// サーバへ問い合わせできないセッションを、手元に残したまま失敗として記録する。
    ///
    /// 期限切れと確認できない404は、サーバ側の一時的な不調かもしれない。
    /// 履歴へ移してしまうと次回以降の突き合わせ対象から外れ、ステージングも
    /// 孤立扱いで掃除されてしまうため、active に残したまま状態だけを失敗にする。
    func markSessionUnreachable(sessionId: String, reason: String) {
        performStateMutationAndPersist { [weak self] in
            guard let self = self, let session = self.activeUploads[sessionId] else { return }
            AppLog.upload.error("⚠️ [UNREACHABLE] session=\(sessionId) reason=\(reason) (手元のチャンクは保持)")
            session.setError("サーバに問い合わせできません (\(reason))")
            self.updateUploadingStatus()
        }
    }

    func pauseUpload(sessionId: String) {
        guard let session = activeUploads[sessionId] else { return }

        // Bug 対策: .paused を必ずディスクにも反映する。以前は updateSessionSafely だけで
        // save が呼ばれず、Force Quit 後に古い .uploading 状態が復元 → 起動時 reconcile が
        // 「まだ送信中」と判断して自動再開してしまい、ユーザーの pause が無視されていた。
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            session.updateStatus(.paused)
            self.updateUploadingStatus()
        }
        // BackgroundURLSession の OS 側 in-flight タスクも停止して、pause 後も
        // 裏で PUT が続くのを防ぐ。cancel された分は resumeSessionFromServer 時に
        // サーバ側 missingChunks を再取得して自然に再送される。
        Task {
            await networkService.pauseOSTasks(sessionId: sessionId)
        }
        AppLog.upload.notice("アップロード一時停止: \(session.fileName)")
    }

    /// 利用者が明示的に選んだ再開・再試行。自動の突き合わせとは別扱いにする。
    ///
    /// 一時停止からの再開も、上限に達した失敗からの再試行も、やることは同じ。
    /// 経路を分けると片方だけリトライ回数を戻し忘れる、片方だけ空のキューへ
    /// 投入して何も送られない、といった食い違いが出る。
    func resumeUpload(sessionId: String) async throws {
        guard let session = activeUploads[sessionId] else { return }

        // 明示操作なので、自動再開の停止と積み上がったリトライ回数を戻す。
        // 自動の突き合わせでこれをやると上限が効かなくなるため、ここだけで行う。
        session.autoResumeBlocked = false
        session.chunkRetryCounts.removeAll()
        session.chunkNextRetryAt.removeAll()

        updateSessionSafely(session) { session in
            session.updateStatus(.uploading)
        }
        saveActiveStateSync()
        AppLog.upload.notice("🔄 アップロード再開: \(session.fileName)")

        // Resume Bug 対策: startUpload は「初回・queue 生存前提」の経路であり、
        // Force Quit 後 / pause 後 / retry 上限後などで queue の有無や isProcessing 状態が
        // 期待どおりでないケースをカバーできない。resumeSessionFromServer は毎回サーバから
        // missingChunks を再取得 → queue を作り直し → 送信開始する冪等な経路なので、
        // 「再開」操作はすべてこちらに寄せる。
        Task {
            do {
                try await networkService.resumeSessionFromServer(session)
                AppLog.upload.notice("✅ アップロード再開成功: \(session.fileName)")
            } catch {
                await handleUploadErrorSafely(session: session, error: error)
            }
        }
    }

    func cancelUpload(sessionId: String) async {
        guard let session = activeUploads[sessionId] else { return }

        AppLog.upload.notice("アップロードキャンセル: \(session.fileName)")

        do {
            try await networkService.deleteSession(sessionId: sessionId)
        } catch {
            AppLog.upload.notice("セッション削除エラー: \(error)")
        }

        // cancel 時もステージングファイルを掃除する。ユーザーの元ファイルには触らない。
        FileManager.shared.cleanupStagedFile(sessionId: sessionId, fileURL: session.fileURL)

        // 「キャンセル」も痕跡を履歴に残す。ユーザーが後日「あのファイルどうしたっけ」を追える。
        // status を .cancelled に遷移 → activeUploads から削除 → history に insert → 永続化を単一トランザクションで。
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            session.updateStatus(.cancelled)
            self.activeUploads.removeValue(forKey: sessionId)
            self.uploadHistory.insert(session, at: 0)
            if self.uploadHistory.count > 50 {
                self.uploadHistory = Array(self.uploadHistory.prefix(50))
            }
            self.updateUploadingStatus()
        }
    }

    // MARK: - Error Handling (バックグラウンド安全)
    
    private func handleUploadErrorSafely(session: UploadSession, error: Error) async {
        updateSessionSafely(session) { session in
            session.setError(error.localizedDescription)
        }
        
        AppLog.upload.notice("❌ [BACKGROUND SAFE] アップロードエラー (\(session.fileName)): \(error)")
        
        // 通知はバックグラウンドでも実行可能
        showErrorNotification(session: session, error: error)
    }

    func handleUploadCompletion(session: UploadSession) {
        AppLog.upload.notice("🎉 [UPLOAD MANAGER] アップロード完了: \(session.fileName)")
        
        updateSessionSafely(session) { session in
            session.updateStatus(.completed)
        }
        
        // 履歴に移動（バックグラウンド安全）
        moveToHistorySafely(session: session)
        
        // 完了通知
        showCompletionNotification(session: session)
    }

    private func moveToHistorySafely(session: UploadSession) {
        // Bug 対策: discardSession と同じく、変更と save を同一同期ブロックで実行する。
        // 従来は updateStateSafely (foreground では async) → saveUploadHistory の順で、
        // 完了処理でも「削除前スナップショットが disk に残る」race があった。
        //
        // 再送材料を消すのは、履歴への移動が保存できたことを確かめてから。
        // 先に消すと、保存前に強制終了された場合に「送信中のまま復元されるのに
        // 送るチャンクが無い」という復旧できない状態になる。
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            self.activeUploads.removeValue(forKey: session.id)
            self.uploadHistory.insert(session, at: 0)
            if self.uploadHistory.count > 50 {
                self.uploadHistory = Array(self.uploadHistory.prefix(50))
            }
            self.updateUploadingStatus()
        } onPersisted: {
            NetworkService.shared.cleanupAfterPersistedCompletion(session: session)
        }
    }

    // MARK: - Batch Operations

    func startMultipleUploads(fileURLs: [URL]) async {
        AppLog.upload.notice("バッチアップロード開始: \(fileURLs.count) ファイル")

        await withTaskGroup(of: Void.self) { group in
            for fileURL in fileURLs {
                group.addTask {
                    do {
                        _ = try await self.startUpload(fileURL: fileURL)
                    } catch {
                        AppLog.upload.notice(
                            "ファイルアップロード失敗 (\(fileURL.lastPathComponent)): \(error)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Statistics

    func getTotalUploadProgress() -> Double {
        guard !activeUploads.isEmpty else { return 0.0 }

        let totalProgress = activeUploads.values.reduce(0.0) {
            $0 + $1.progress
        }
        return totalProgress / Double(activeUploads.count)
    }

    // MARK: - Persistence

    // MARK: - Persistence (Codable)

    private struct PersistedState: Codable {
        let history: [UploadSession]
        let active: [UploadSession]
    }

    private func stateFileURL() -> URL {
        return fileManager.getDocumentsDirectory()
            .appendingPathComponent("upload_state.json")
    }

    /// 同期永続化。NetworkService の withState 内から呼ばれるため public。
    func saveActiveStateSync() {
        saveUploadHistory()
    }

    /// 保存の成否を呼び出し元へ返す。耐久化できたことを確かめてから
    /// 次の動作へ進みたい経路 (再送予定の登録など) で使う。
    func persistActiveState() throws {
        try writeUploadState()
    }

    /// 状態ファイルへの書き込みを直列化するロック。
    /// URLSession の delegate queue と MainActor の両方から呼ばれるため、
    /// 直列化しないと encode 途中の内容が混ざったファイルが残る。
    private static let stateWriteLock = NSLock()

    private func saveUploadHistory() {
        do {
            try writeUploadState()
        } catch {
            AppLog.upload.error("状態保存エラー: \(error.localizedDescription)")
        }
    }

    /// 状態ファイルへの書き込み本体。失敗を呼び出し元へ返す。
    /// 記録が残らないまま送信を始めると、強制終了でセッションが行方不明になる。
    private func writeUploadState() throws {
        UploadManager.stateWriteLock.lock()
        defer { UploadManager.stateWriteLock.unlock() }

        let state = PersistedState(
            history: uploadHistory,
            active: Array(activeUploads.values)
        )
        let data = try JSONEncoder().encode(state)

        let url = stateFileURL()
        // 直前の内容をバックアップしてから差し替える。書き込み中に電源が落ちても
        // 「壊れた本体 + 直前の正常なバックアップ」が残り、起動時に読み戻せる。
        let backupURL = url.appendingPathExtension("bak")
        if Foundation.FileManager.default.fileExists(atPath: url.path) {
            try? Foundation.FileManager.default.removeItem(at: backupURL)
            try? Foundation.FileManager.default.copyItem(at: url, to: backupURL)
        }

        // .atomic は一時ファイルへ書いて rename する。中途半端な内容が本体に残らない。
        try data.write(to: url, options: .atomic)
    }

    private func loadUploadHistory() {
        let url = stateFileURL()
        guard let state = decodePersistedState(at: url)
            ?? decodePersistedState(at: url.appendingPathExtension("bak")) else {
            return
        }
        applyPersistedState(state)
    }

    /// 状態ファイルを読む。壊れていれば nil を返し、呼び出し側がバックアップへ切り替える。
    private func decodePersistedState(at url: URL) -> PersistedState? {
        guard Foundation.FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            AppLog.upload.error("状態読み込みエラー (\(url.lastPathComponent)): \(error.localizedDescription)")
            return nil
        }
    }

    private func applyPersistedState(_ state: PersistedState) {
        self.uploadHistory = state.history
        for s in state.active {
            self.activeUploads[s.id] = s
            // FLAW 5 対策: NetworkService 側にも同じ参照を登録して session identity を統一する。
            // これで scheduleChunkRetry が触る activeUploadSessions[id] と UploadManager.activeUploads[id]
            // が同一インスタンスを指し、永続化の内容が最新の retry state を反映する。
            NetworkService.shared.activeUploadSessions[s.id] = s
        }
        AppLog.upload.notice("状態を復元しました: history=\(state.history.count) active=\(state.active.count)")
    }

    // MARK: - Notifications (バックグラウンド対応)

    private func showCompletionNotification(session: UploadSession) {
        let content = UNMutableNotificationContent()
        content.title = "アップロード完了"
        content.body = "\(session.fileName) のアップロードが完了しました"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "upload_completed_\(session.id)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
        AppLog.upload.notice("📱 [BACKGROUND SAFE] 完了通知送信: \(session.fileName)")
    }

    private func showErrorNotification(session: UploadSession, error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "アップロードエラー"
        content.body = "\(session.fileName): \(error.localizedDescription)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "upload_error_\(session.id)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
        AppLog.upload.notice("📱 [BACKGROUND SAFE] エラー通知送信: \(session.fileName)")
    }

    // MARK: - Cleanup

    func cleanup() {
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            let completedSessions = self.activeUploads.filter {
                $0.value.status == .completed
            }
            for (sessionId, _) in completedSessions {
                self.activeUploads.removeValue(forKey: sessionId)
            }
            // 履歴の日付ベース GC は将来対応 (現状は no-op)
            self.updateUploadingStatus()
        }
    }
}

// MARK: - Upload Manager Extensions

extension UploadManager {

    // デバッグ用のメソッド
    func printDebugInfo() {
        AppLog.upload.notice("=== Upload Manager Debug Info ===")
        AppLog.upload.notice("Active uploads: \(self.activeUploads.count)")
        AppLog.upload.notice("Upload history: \(self.uploadHistory.count)")
        AppLog.upload.notice("Is uploading: \(self.isUploading)")
        AppLog.upload.notice("Background session: BackgroundURLSessionでアップロード継続中")
        AppLog.upload.notice("App in background: \(self.isAppInBackground)")

        for (sessionId, session) in activeUploads {
            AppLog.upload.notice(
                "  Session \(sessionId): \(session.fileName) - \(session.status.description) (\(Int(session.progress * 100))%)"
            )
        }
        AppLog.upload.notice("================================")
    }

    // 統計情報の文字列表現
    func getStatisticsDescription() -> String {
        let stats = getUploadStatistics()
        let totalSizeFormatted = fileManager.formatFileSize(stats.totalSize)

        return """
            アクティブ: \(stats.active)
            完了: \(stats.completed)
            失敗: \(stats.failed)
            総サイズ: \(totalSizeFormatted)
            """
    }
}

// MARK: - NetworkService Integration

extension UploadManager {
    
    // NetworkServiceからの完了通知を受け取る
    /// 履歴から1件削除して永続化する。UI からの単発削除経路はこれを通す。
    /// 従来は `uploadManager.uploadHistory.removeAll { $0.id == id }` の直接操作で
    /// save が呼ばれず、再起動時に復活していた。
    func deleteHistoryEntry(sessionId: String) {
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            let before = self.uploadHistory.count
            self.uploadHistory.removeAll { $0.id == sessionId }
            let after = self.uploadHistory.count
            AppLog.upload.notice("🗑 [DELETE HISTORY] session=\(sessionId) removed=\(before - after)")
        }
    }

    /// 履歴を全消去して永続化する。「アップロード履歴をクリア」ボタン用。
    func clearAllHistory() {
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            let count = self.uploadHistory.count
            self.uploadHistory.removeAll()
            AppLog.upload.notice("🗑 [CLEAR HISTORY] cleared=\(count) entries")
        }
    }

    /// activeUploads から強制的にセッションを取り除き、履歴に error として記録する。
    /// - 起動時 reconcile でサーバ側 404 と判明したセッション
    /// - UI からユーザーが手動で「削除」を選んだセッション
    /// の両方で使う。history に痕跡を残すのは、後で問い合わせが来たときに
    /// 「そういうセッションがあった」ことを追える最低限のログのため。
    ///
    /// Bug 対策: 以前は `updateStateSafely { ... }` (foreground では async に MainActor Task を積む)
    /// の直後に saveActiveStateSync() を呼んでいたため、**save が変更前スナップショットを書いてしまい**、
    /// Force Quit で「削除したはずのセッションが復活」する不具合があった。
    /// 状態変更と永続化を同一の同期ブロックに閉じ込めることでこの race を排除する。
    /// - Parameter keepStagedFile: ステージング済みチャンクを残すかどうか。
    ///   サーバ側で期限切れと確認できた場合だけ false にする。理由の分からない 404 で
    ///   消してしまうと、送り直す材料が手元から無くなる。
    func discardSession(sessionId: String, reason: String, keepStagedFile: Bool = false) {
        performStateMutationAndPersist { [weak self] in
            guard let self = self else { return }
            guard let session = self.activeUploads[sessionId] else {
                AppLog.upload.notice("⚠️ discardSession: セッション \(sessionId) が activeUploads にありません")
                return
            }
            AppLog.upload.notice("🗑 [DISCARD] session=\(sessionId) reason=\(reason)")
            session.updateStatus(.error)
            self.activeUploads.removeValue(forKey: sessionId)
            self.uploadHistory.insert(session, at: 0)
            if self.uploadHistory.count > 50 {
                self.uploadHistory = Array(self.uploadHistory.prefix(50))
            }
            // ステージングは破棄経路でも掃除する。ユーザーの元ファイルは触らない。
            // ただし理由の分からない 404 では残し、後続の突き合わせで判断できるようにする。
            if keepStagedFile {
                AppLog.upload.notice("📦 [DISCARD] session=\(sessionId) のステージングは保持 (reason=\(reason))")
            } else {
                FileManager.shared.cleanupStagedFile(sessionId: sessionId, fileURL: session.fileURL)
            }
            self.updateUploadingStatus()
        }
    }

    /// 「状態変更 → 永続化」を同一ブロックにまとめて実行する。
    /// foreground 時は MainActor 上で必ず順序どおりに実行し、background 時は現スレッドで実行する。
    /// いずれもブロック完了直後に saveActiveStateSync() を呼ぶため
    /// 「変更が反映される前に save が走る」race が起きない。
    ///
    /// 呼び出し規約: activeUploads / uploadHistory / isUploading / 個別 session.status を触る
    /// すべての経路はこの関数を通す。updateStateSafely + 外側 save の 2 段構えを新規に書かないこと。
    ///
    /// 実装上のポイント:
    /// - Thread.isMainThread ≠ MainActor isolated なので assumeIsolated は使わない。
    /// - foreground では常に Task { @MainActor in ... } で 1 hop するが、mutation と save が
    ///   同じ closure に閉じ込められているため、途中で reconcile 等が割り込む可能性はない。
    func performStateMutationAndPersist(
        _ mutation: @escaping () -> Void,
        onPersisted: (() -> Void)? = nil
    ) {
        if isAppInBackground {
            mutation()
            saveActiveStateSync()
            onPersisted?()
        } else {
            Task { @MainActor in
                mutation()
                self.saveActiveStateSync()
                onPersisted?()
            }
        }
    }

    func notifyUploadCompletion(sessionId: String) {
        guard let session = activeUploads[sessionId] else {
            AppLog.upload.notice("⚠️ 完了通知: セッション \(sessionId) が見つかりません")
            return
        }
        
        handleUploadCompletion(session: session)
    }
    
    // NetworkServiceからのエラー通知を受け取る
    func notifyUploadError(sessionId: String, error: Error) async {
        guard let session = activeUploads[sessionId] else {
            AppLog.upload.notice("⚠️ エラー通知: セッション \(sessionId) が見つかりません")
            return
        }
        
        await handleUploadErrorSafely(session: session, error: error)
    }
}
