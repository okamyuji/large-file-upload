import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        print("📱 アプリケーションが起動しました")
        
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
        print("🔔 BackgroundURLSession イベント処理: \(identifier)")
        
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
        
        print("✅ バックグラウンドタスクの設定を完了しました")
    }
    
    @available(iOS 13.0, *)
    private func handleBackgroundUploadTask(task: BGProcessingTask) {
        print("🔄 バックグラウンドアップロードタスク実行")
        
        // タスクの期限切れ処理
        task.expirationHandler = {
            print("⏰ バックグラウンドタスクが期限切れになりました")
            task.setTaskCompleted(success: false)
        }
        
        // バックグラウンドでのアップロード処理
        Task {
            await NetworkService.shared.refreshAllSessionStatus()
            task.setTaskCompleted(success: true)
        }
    }
    
    @available(iOS 13.0, *)
    private func handleRefreshTask(task: BGAppRefreshTask) {
        print("🔄 アプリリフレッシュタスク実行")
        
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
        print("🌙 アプリがバックグラウンドに移行しました")
        scheduleBackgroundTasks()
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("☀️ アプリがフォアグラウンドに復帰しました")
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
                print("📅 バックグラウンドアップロードタスクをスケジュールしました")
            } catch {
                print("❌ バックグラウンドタスクのスケジュールに失敗: \(error)")
            }
            
            // リフレッシュタスクもスケジュール
            let refreshRequest = BGAppRefreshTaskRequest(identifier: "com.largefileupload.refresh")
            refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)  // 1分後
            
            do {
                try BGTaskScheduler.shared.submit(refreshRequest)
                print("📅 リフレッシュタスクをスケジュールしました")
            } catch {
                print("❌ リフレッシュタスクのスケジュールに失敗: \(error)")
            }
        }
    }
    
    private func cancelBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            print("🚫 バックグラウンドタスクをキャンセルしました")
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if granted {
                print("✅ 通知許可が得られました")
            } else if let error = error {
                print("❌ 通知許可エラー: \(error)")
            }
        }
    }
}

// MARK: - Import for iOS 13+
import BackgroundTasks
