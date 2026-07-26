import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppLog.upload.notice("📱 アプリケーションが起動しました")
        
        // バックグラウンドタスクの設定
        setupBackgroundTasks()
        
        // 通知許可の要求
        requestNotificationPermissions()
        
        return true
    }
    
    // MARK: - Background URL Session
    
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        AppLog.upload.notice("🔔 BackgroundURLSession イベント処理: \(identifier)")

        // 順序が重要。handler を先にセッション非依存のレジストリへ登録し、そのあとで
        // 同じ identifier のセッションを作り直して再関連付けする。
        // NetworkService の property へ直接代入すると、代入の評価時に singleton 初期化が走って
        // セッションが先に生成され、Apple が求める順序と逆になる。
        BackgroundSessionCompletionRegistry.shared.store(
            identifier: identifier,
            handler: completionHandler
        )
        NetworkService.shared.activateBackgroundSession()
    }
    
    // MARK: - Background Tasks
    
    private func setupBackgroundTasks() {
        // iOS 13+ のバックグラウンドタスク
        if #available(iOS 13.0, *) {
            // バックグラウンド処理用
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.largefileupload.background-upload",
                using: nil
            ) { task in
                self.handleBackgroundUploadTask(task: task as! BGProcessingTask)
            }
            
            // アプリリフレッシュ用
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.largefileupload.refresh",
                using: nil
            ) { task in
                self.handleRefreshTask(task: task as! BGAppRefreshTask)
            }
        }
        
        AppLog.upload.notice("✅ バックグラウンドタスクの設定を完了しました")
    }
    
    /// バックグラウンドで定期的に走る後始末の枠。
    ///
    /// ここでやるのは、サーバの `GET /status` とクライアントの記憶を突き合わせて
    /// 未送信チャンクを再投入し、消えたセッションを破棄し、残った一時ファイルを掃除することまで。
    /// 転送そのものは BackgroundURLSession が所有しているので、この枠の中では動かさない。
    /// 実行時間には上限があるため、超過しそうになったら expirationHandler で打ち切る。
    @available(iOS 13.0, *)
    private func handleBackgroundUploadTask(task: BGProcessingTask) {
        AppLog.upload.notice("🔄 バックグラウンド整合タスク実行")

        // 期限切れと正常終了は同時に起こり得る。`Task.isCancelled` を見てから
        // setTaskCompleted を呼ぶだけでは、その隙間に期限切れが割り込んで二重完了になる。
        // 完了通知は一度きりに保証する。
        let completion = SingleShotTaskCompletion(task: task)
        var workTask: Task<Void, Never>?

        task.expirationHandler = {
            AppLog.upload.notice("⏰ バックグラウンドタスクが期限切れになりました")
            workTask?.cancel()
            completion.complete(success: false)
        }

        workTask = Task {
            await NetworkService.shared.reconcileWithServer()
            guard !Task.isCancelled else { return }
            NetworkService.shared.cleanupOrphanedStagedSessions()
            completion.complete(success: !Task.isCancelled)
        }
    }
    
    @available(iOS 13.0, *)
    private func handleRefreshTask(task: BGAppRefreshTask) {
        AppLog.upload.notice("🔄 アプリリフレッシュタスク実行")

        let completion = SingleShotTaskCompletion(task: task)
        var workTask: Task<Void, Never>?

        task.expirationHandler = {
            AppLog.upload.notice("⏰ リフレッシュタスクが期限切れになりました")
            workTask?.cancel()
            completion.complete(success: false)
        }

        workTask = Task {
            await NetworkService.shared.refreshAllSessionStatus()
            completion.complete(success: !Task.isCancelled)
        }
    }
    
    // MARK: - App Lifecycle
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        AppLog.upload.notice("🌙 アプリがバックグラウンドに移行しました")
        scheduleBackgroundTasks()
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        AppLog.upload.notice("☀️ アプリがフォアグラウンドに復帰しました")
        cancelBackgroundTasks()
    }
    
    private func scheduleBackgroundTasks() {
        if #available(iOS 13.0, *) {
            // バックグラウンドアップロードタスクをスケジュール
            let uploadRequest = BGProcessingTaskRequest(identifier: "com.largefileupload.background-upload")
            uploadRequest.requiresNetworkConnectivity = true
            uploadRequest.requiresExternalPower = false  // バッテリーでも実行
            uploadRequest.earliestBeginDate = Date(timeIntervalSinceNow: 10)  // 10秒後
            
            do {
                try BGTaskScheduler.shared.submit(uploadRequest)
                AppLog.upload.notice("📅 バックグラウンドアップロードタスクをスケジュールしました")
            } catch {
                AppLog.upload.notice("❌ バックグラウンドタスクのスケジュールに失敗: \(error)")
            }
            
            // リフレッシュタスクもスケジュール
            let refreshRequest = BGAppRefreshTaskRequest(identifier: "com.largefileupload.refresh")
            refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)  // 1分後
            
            do {
                try BGTaskScheduler.shared.submit(refreshRequest)
                AppLog.upload.notice("📅 リフレッシュタスクをスケジュールしました")
            } catch {
                AppLog.upload.notice("❌ リフレッシュタスクのスケジュールに失敗: \(error)")
            }
        }
    }
    
    private func cancelBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            AppLog.upload.notice("🚫 バックグラウンドタスクをキャンセルしました")
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if granted {
                AppLog.upload.notice("✅ 通知許可が得られました")
            } else if let error = error {
                AppLog.upload.notice("❌ 通知許可エラー: \(error)")
            }
        }
    }
}

// MARK: - Import for iOS 13+
import BackgroundTasks

/// BGTask の完了通知を一度だけに保証する。
/// `setTaskCompleted` の二重呼び出しは未定義動作で、クラッシュログに「completed called twice」が出る。
/// 期限切れハンドラと正常終了は別のスレッドから同時に来るため、フラグの確認と通知を
/// ロックで囲んで不可分にする。
@available(iOS 13.0, *)
final class SingleShotTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var isCompleted = false

    init(task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        let alreadyCompleted = isCompleted
        isCompleted = true
        lock.unlock()

        guard !alreadyCompleted else { return }
        task.setTaskCompleted(success: success)
    }
}
