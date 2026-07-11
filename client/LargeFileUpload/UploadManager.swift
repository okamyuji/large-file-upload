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
        // v2: 起動時に OS 所有タスクを reconcile
        Task {
            _ = await NetworkService.shared.reconcileOSOwnedTasks()
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
        let failedSessions = activeUploads.values.filter { $0.status == .error }

        for session in failedSessions {
            do {
                AppLog.upload.notice("🔄 失敗アップロードの再試行: \(session.fileName)")
                
                // 逐次処理でアップロード再開
                try await networkService.startUpload(session: session)
                
                // バックグラウンド安全な状態更新
                updateSessionSafely(session) { session in
                    session.updateStatus(.uploading)
                }
                updateStateSafely {
                    self.updateUploadingStatus()
                }
                
                AppLog.upload.notice("✅ 逐次処理アップロード再開成功: \(session.fileName)")
            } catch {
                AppLog.upload.notice("❌ 再試行エラー (\(session.fileName)): \(error)")
                await handleUploadErrorSafely(session: session, error: error)
            }
        }
    }

    private func refreshActiveUploads() async {
        // フォアグラウンド専用メソッド（MainActor安全）
        guard !isAppInBackground else {
            AppLog.upload.notice("🌙 [BACKGROUND] refreshActiveUploads スキップ - バックグラウンド時はUI更新不要")
            return
        }

        // 復元された active session をサーバ状態と同期して未送信チャンクの送信を再開
        for (_, session) in activeUploads where session.status != .completed && session.status != .error {
            do {
                try await networkService.resumeSessionFromServer(session)
            } catch {
                AppLog.upload.error("resume 失敗 (\(session.fileName)): \(error.localizedDescription)")
            }
        }

        await networkService.refreshAllSessionStatus()

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

        // バックグラウンド安全な状態更新
        updateStateSafely {
            self.activeUploads[session.id] = session
            self.isUploading = true
        }

        // BackgroundURLSessionでアップロード開始
        try await networkService.startUpload(session: session)
        
        AppLog.upload.notice("✅ BackgroundURLSessionアップロード開始: \(session.fileName)")
        return session
    }

    func pauseUpload(sessionId: String) {
        guard let session = activeUploads[sessionId] else { return }

        updateSessionSafely(session) { session in
            session.updateStatus(.paused)
        }
        AppLog.upload.notice("アップロード一時停止: \(session.fileName)")
    }

    func resumeUpload(sessionId: String) async throws {
        guard let session = activeUploads[sessionId] else { return }

        updateSessionSafely(session) { session in
            session.updateStatus(.uploading)
        }
        AppLog.upload.notice("🔄 アップロード再開: \(session.fileName)")

        Task {
            do {
                // BackgroundURLSessionでアップロード再開
                try await networkService.startUpload(session: session)
                AppLog.upload.notice("✅ BackgroundURLSessionアップロード再開成功: \(session.fileName)")
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

        updateStateSafely {
            self.activeUploads.removeValue(forKey: sessionId)
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
        updateStateSafely {
            self.activeUploads.removeValue(forKey: session.id)
            self.uploadHistory.insert(session, at: 0)

            // 履歴は最大50件まで保持
            if self.uploadHistory.count > 50 {
                self.uploadHistory = Array(self.uploadHistory.prefix(50))
            }

            self.updateUploadingStatus()
        }
        
        saveUploadHistory()
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

    private func saveUploadHistory() {
        do {
            let state = PersistedState(
                history: uploadHistory,
                active: Array(activeUploads.values)
            )
            let encoder = JSONEncoder()
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL())
        } catch {
            AppLog.upload.error("状態保存エラー: \(error.localizedDescription)")
        }
    }

    private func loadUploadHistory() {
        let url = stateFileURL()
        guard Foundation.FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            self.uploadHistory = state.history
            for s in state.active {
                self.activeUploads[s.id] = s
                // FLAW 5 対策: NetworkService 側にも同じ参照を登録して session identity を統一する。
                // これで scheduleChunkRetry が触る activeUploadSessions[id] と UploadManager.activeUploads[id]
                // が同一インスタンスを指し、永続化の内容が最新の retry state を反映する。
                NetworkService.shared.activeUploadSessions[s.id] = s
            }
            AppLog.upload.notice("状態を復元しました: history=\(state.history.count) active=\(state.active.count)")
        } catch {
            AppLog.upload.error("状態読み込みエラー: \(error.localizedDescription)")
        }
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
        // 完了済みセッションのクリーンアップ
        let completedSessions = activeUploads.filter {
            $0.value.status == .completed
        }
        for (sessionId, _) in completedSessions {
            activeUploads.removeValue(forKey: sessionId)
        }

        // 古い履歴の削除（30日以上前）
        // TODO: 実際の実装では各セッションに作成日時を追加する必要があります
        uploadHistory.removeAll { session in
            // 実際の実装では各セッションに作成日時を追加する必要があります
            false
        }

        self.updateUploadingStatus()
        saveUploadHistory()
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
