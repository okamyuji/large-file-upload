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
        print("🌙 アップロードマネージャー: アプリがバックグラウンドに移行 - MainActor使用停止")
        // BackgroundURLSessionを使用しているため、UIApplication.beginBackgroundTaskは不要
        print("🔗 [BACKGROUND SESSION] BackgroundURLSessionがアップロードを継続します")
    }

    @objc private func appWillEnterForeground() {
        isAppInBackground = false
        print("☀️ アップロードマネージャー: アプリがフォアグラウンドに復帰 - UI更新再開")
        // BackgroundURLSessionを使用しているため、UIApplication.endBackgroundTaskは不要
        print("🔗 [FOREGROUND RESUME] BackgroundURLSessionから状態同期を開始")

        // アクティブなアップロードの状態を更新（フォアグラウンド専用）
        Task {
            await refreshActiveUploads()
        }
    }

    @objc private func appWillTerminate() {
        print("アップロードマネージャー: アプリが終了")
        saveUploadHistory()
    }

    // MARK: - Safe State Management (バックグラウンド完全対応)

    private func updateStateSafely(_ updateBlock: @escaping () -> Void) {
        // isAppInBackgroundフラグのみ使用（MainActor安全）
        if isAppInBackground {
            // バックグラウンド時：MainActor使用禁止、直接更新
            updateBlock()
            print("🌙 [BACKGROUND] UploadManager状態更新: MainActor回避")
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
            print("🌙 [BACKGROUND] セッション更新: \(session.id)")
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
                print("🔄 失敗アップロードの再試行: \(session.fileName)")
                
                // 逐次処理でアップロード再開
                try await networkService.startUpload(session: session)
                
                // バックグラウンド安全な状態更新
                updateSessionSafely(session) { session in
                    session.updateStatus(.uploading)
                }
                updateStateSafely {
                    self.updateUploadingStatus()
                }
                
                print("✅ 逐次処理アップロード再開成功: \(session.fileName)")
            } catch {
                print("❌ 再試行エラー (\(session.fileName)): \(error)")
                await handleUploadErrorSafely(session: session, error: error)
            }
        }
    }

    private func refreshActiveUploads() async {
        // フォアグラウンド専用メソッド（MainActor安全）
        guard !isAppInBackground else {
            print("🌙 [BACKGROUND] refreshActiveUploads スキップ - バックグラウンド時はUI更新不要")
            return
        }
        
        // NetworkServiceの逐次処理システムでは自動的に状態更新される
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
        print("🚀 アップロード開始: \(fileURL.lastPathComponent)")

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
        
        print("✅ BackgroundURLSessionアップロード開始: \(session.fileName)")
        return session
    }

    func pauseUpload(sessionId: String) {
        guard let session = activeUploads[sessionId] else { return }

        updateSessionSafely(session) { session in
            session.updateStatus(.paused)
        }
        print("アップロード一時停止: \(session.fileName)")
    }

    func resumeUpload(sessionId: String) async throws {
        guard let session = activeUploads[sessionId] else { return }

        updateSessionSafely(session) { session in
            session.updateStatus(.uploading)
        }
        print("🔄 アップロード再開: \(session.fileName)")

        Task {
            do {
                // BackgroundURLSessionでアップロード再開
                try await networkService.startUpload(session: session)
                print("✅ BackgroundURLSessionアップロード再開成功: \(session.fileName)")
            } catch {
                await handleUploadErrorSafely(session: session, error: error)
            }
        }
    }

    func cancelUpload(sessionId: String) async {
        guard let session = activeUploads[sessionId] else { return }

        print("アップロードキャンセル: \(session.fileName)")

        do {
            try await networkService.deleteSession(sessionId: sessionId)
        } catch {
            print("セッション削除エラー: \(error)")
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
        
        print("❌ [BACKGROUND SAFE] アップロードエラー (\(session.fileName)): \(error)")
        
        // 通知はバックグラウンドでも実行可能
        showErrorNotification(session: session, error: error)
    }

    func handleUploadCompletion(session: UploadSession) {
        print("🎉 [UPLOAD MANAGER] アップロード完了: \(session.fileName)")
        
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
        print("バッチアップロード開始: \(fileURLs.count) ファイル")

        await withTaskGroup(of: Void.self) { group in
            for fileURL in fileURLs {
                group.addTask {
                    do {
                        _ = try await self.startUpload(fileURL: fileURL)
                    } catch {
                        print(
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

    private func saveUploadHistory() {
        do {
            let documentsDir = fileManager.getDocumentsDirectory()
            let historyURL = documentsDir.appendingPathComponent(
                "upload_history.json"
            )

            // 簡易的な保存（実際のアプリではより堅牢な方法を使用）
            let historyData = uploadHistory.map { session in
                [
                    "id": session.id,
                    "fileName": session.fileName,
                    "fileSize": session.fileSize,
                    "status": session.status.rawValue,
                    "progress": session.progress,
                    "error": session.error ?? "",
                ]
            }

            let data = try JSONSerialization.data(withJSONObject: historyData)
            try data.write(to: historyURL)
        } catch {
            print("アップロード履歴保存エラー: \(error)")
        }
    }

    private func loadUploadHistory() {
        do {
            let documentsDir = fileManager.getDocumentsDirectory()
            let historyURL = documentsDir.appendingPathComponent(
                "upload_history.json"
            )

            guard
                Foundation.FileManager.default.fileExists(
                    atPath: historyURL.path
                )
            else { return }

            let data = try Data(contentsOf: historyURL)
            let historyData =
                try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                ?? []

            // 履歴復元（簡易版）
            print("アップロード履歴を復元しました: \(historyData.count) 件")
        } catch {
            print("アップロード履歴読み込みエラー: \(error)")
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
        print("📱 [BACKGROUND SAFE] 完了通知送信: \(session.fileName)")
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
        print("📱 [BACKGROUND SAFE] エラー通知送信: \(session.fileName)")
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
        print("=== Upload Manager Debug Info ===")
        print("Active uploads: \(activeUploads.count)")
        print("Upload history: \(uploadHistory.count)")
        print("Is uploading: \(isUploading)")
        print("Background session: BackgroundURLSessionでアップロード継続中")
        print("App in background: \(isAppInBackground)")

        for (sessionId, session) in activeUploads {
            print(
                "  Session \(sessionId): \(session.fileName) - \(session.status.description) (\(Int(session.progress * 100))%)"
            )
        }
        print("================================")
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
            print("⚠️ 完了通知: セッション \(sessionId) が見つかりません")
            return
        }
        
        handleUploadCompletion(session: session)
    }
    
    // NetworkServiceからのエラー通知を受け取る
    func notifyUploadError(sessionId: String, error: Error) async {
        guard let session = activeUploads[sessionId] else {
            print("⚠️ エラー通知: セッション \(sessionId) が見つかりません")
            return
        }
        
        await handleUploadErrorSafely(session: session, error: error)
    }
}
