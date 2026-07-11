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
        
        // NetworkServiceにcompletionHandlerを渡す
        NetworkService.shared.backgroundCompletionHandler = completionHandler
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
    
    @available(iOS 13.0, *)
    private func handleBackgroundUploadTask(task: BGProcessingTask) {
        AppLog.upload.notice("🔄 バックグラウンドアップロードタスク実行")

        var workTask: Task<Void, Never>?

        // タスクの期限切れ処理: 進行中の Task をキャンセルしてから setTaskCompleted(false) を呼ぶ
        task.expirationHandler = {
            AppLog.upload.notice("⏰ バックグラウンドタスクが期限切れになりました")
            workTask?.cancel()
            task.setTaskCompleted(success: false)
        }

        // バックグラウンドでのアップロード処理。Task ハンドルを保持し、
        // 期限切れで cancel された場合は setTaskCompleted を呼ばない
        // (BGProcessingTask.setTaskCompleted の二重呼び出しは未定義動作)。
        workTask = Task {
            await NetworkService.shared.refreshAllSessionStatus()
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
        }
    }
    
    @available(iOS 13.0, *)
    private func handleRefreshTask(task: BGAppRefreshTask) {
        AppLog.upload.notice("🔄 アプリリフレッシュタスク実行")
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task {
            await NetworkService.shared.refreshAllSessionStatus()
            task.setTaskCompleted(success: true)
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
