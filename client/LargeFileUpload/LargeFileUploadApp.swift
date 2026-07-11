import SwiftUI
import UserNotifications

@main
struct LargeFileUploadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var uploadManager = UploadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(networkMonitor)
                .environmentObject(uploadManager)
                .onAppear {
                    setupApp()
                }
                .overlay(
                    // ネットワーク未接続時の警告表示
                    Group {
                        if !networkMonitor.isConnected {
                            NetworkUnavailableView()
                        }
                    }
                )
        }
    }

    private func setupApp() {
        AppLog.upload.notice("アプリ初期化開始")

        // 通知設定
        requestNotificationPermission()

        // 一時ファイルのクリーンアップ
        cleanupTemporaryFiles()

        AppLog.upload.notice("アプリ初期化完了")
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound, .badge,
        ]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    AppLog.upload.notice("通知許可が得られました")
                } else if let error = error {
                    AppLog.upload.notice("通知許可エラー: \(error)")
                } else {
                    AppLog.upload.notice("通知許可が拒否されました")
                }
            }
        }
    }

    private func cleanupTemporaryFiles() {
        Task {
            let tempDir = Foundation.FileManager.default.temporaryDirectory
            do {
                let tempFiles = try Foundation.FileManager.default
                    .contentsOfDirectory(
                        at: tempDir,
                        includingPropertiesForKeys: [.creationDateKey],
                        options: .skipsHiddenFiles
                    )

                let now = Date()
                let dayAgo = now.addingTimeInterval(-24 * 60 * 60)  // 24時間前

                for file in tempFiles {
                    // アップロード関連の一時ファイルのみを対象
                    if file.lastPathComponent.hasPrefix("upload_")
                        || file.lastPathComponent.hasPrefix("chunk_")
                    {

                        if let creationDate = try? file.resourceValues(
                            forKeys: [.creationDateKey]).creationDate,
                            creationDate < dayAgo
                        {
                            try Foundation.FileManager.default.removeItem(
                                at: file
                            )
                            AppLog.upload.notice("古い一時ファイルを削除: \(file.lastPathComponent)")
                        }
                    }
                }
            } catch {
                AppLog.upload.notice("一時ファイルクリーンアップエラー: \(error)")
            }
        }
    }
}

// MARK: - Network Unavailable View

struct NetworkUnavailableView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("ネットワーク接続なし")
                .font(.headline)
                .fontWeight(.medium)

            Text("インターネット接続を確認してください")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("再試行") {
                // ネットワーク状態の手動更新
                // NetworkMonitorは自動的に状態を監視するため、
                // ここでは特別な処理は不要
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 8)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
        .transition(.opacity)
    }
}
