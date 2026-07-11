import SwiftUI

// MARK: - History View

struct HistoryView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var searchText = ""
    @State private var selectedFilter: HistoryFilter = .all

    enum HistoryFilter: String, CaseIterable {
        case all = "すべて"
        case completed = "完了"
        case failed = "失敗"

        var systemImage: String {
            switch self {
            case .all: return "list.bullet"
            case .completed: return "checkmark.circle"
            case .failed: return "xmark.circle"
            }
        }
    }

    var filteredHistory: [UploadSession] {
        let filtered = uploadManager.uploadHistory.filter { session in
            switch selectedFilter {
            case .all:
                return true
            case .completed:
                return session.status == .completed
            case .failed:
                return session.status == .error
            }
        }

        if searchText.isEmpty {
            return filtered
        } else {
            return filtered.filter { session in
                session.fileName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                if uploadManager.uploadHistory.isEmpty {
                    EmptyHistoryView()
                } else {
                    VStack {
                        // フィルター
                        FilterSection(selectedFilter: $selectedFilter)

                        // 履歴リスト
                        List {
                            ForEach(filteredHistory, id: \.id) { session in
                                HistoryRow(session: session)
                            }
                            .onDelete(perform: deleteHistoryItems)
                        }
                        .searchable(text: $searchText, prompt: "ファイル名で検索")
                    }
                }
            }
            .navigationTitle("アップロード履歴")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("クリア") {
                        clearHistory()
                    }
                    .disabled(uploadManager.uploadHistory.isEmpty)
                }
            }
        }
    }

    private func deleteHistoryItems(offsets: IndexSet) {
        // 実際の実装では、選択されたアイテムを削除する
        for index in offsets {
            let session = filteredHistory[index]
            uploadManager.uploadHistory.removeAll { $0.id == session.id }
        }
    }

    private func clearHistory() {
        uploadManager.uploadHistory.removeAll()
    }
}

// MARK: - Empty History View

struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("アップロード履歴はありません")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Text("ファイルをアップロードすると履歴がここに表示されます")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Filter Section

struct FilterSection: View {
    @Binding var selectedFilter: HistoryView.HistoryFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(HistoryView.HistoryFilter.allCases, id: \.self) {
                    filter in
                    FilterChip(
                        title: filter.rawValue,
                        icon: filter.systemImage,
                        isSelected: selectedFilter == filter
                    ) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}

struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color.gray.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
    }
}

// MARK: - History Row

struct HistoryRow: View {
    let session: UploadSession

    var body: some View {
        HStack(spacing: 12) {
            // ファイルアイコン
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 32)

            // ファイル情報
            VStack(alignment: .leading, spacing: 4) {
                Text(session.fileName)
                    .font(.headline)
                    .lineLimit(1)

                HStack {
                    Text(FileManager.shared.formatFileSize(session.fileSize))
                    Spacer()
                    StatusBadge(status: session.status)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                // 進捗バー（完了していない場合）
                if session.status != .completed {
                    ProgressView(value: session.progress)
                        .progressViewStyle(
                            LinearProgressViewStyle(tint: progressColor)
                        )
                }

                // エラーメッセージ
                if let error = session.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // アクションメニュー
            Menu {
                if session.status == .completed {
                    Button("詳細を表示") {
                        // 詳細表示の実装
                    }
                } else if session.status == .error {
                    Button("再試行") {
                        // 再試行の実装
                    }
                }

                Button("履歴から削除", role: .destructive) {
                    // 削除の実装
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 4)
    }

    private var fileIcon: String {
        let ext = (session.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "video"
        case "mp3", "wav", "aac", "flac":
            return "music.note"
        case "pdf":
            return "doc.text"
        case "zip", "rar", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        switch session.status {
        case .completed: return .green
        case .error: return .red
        default: return .blue
        }
    }

    private var progressColor: Color {
        switch session.status {
        case .error: return .red
        case .paused: return .gray
        default: return .blue
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("chunkSize") private var chunkSize: Double = 1.0  // MB
    @AppStorage("maxConcurrentUploads") private var maxConcurrentUploads:
        Double = 4
    @AppStorage("enableNotifications") private var enableNotifications = true
    @AppStorage("enableAutoRetry") private var enableAutoRetry = true
    @AppStorage("retryAttempts") private var retryAttempts: Double = 3
    @AppStorage("serverURL") private var serverURL = "http://192.168.0.16:8080"

    @State private var showingAbout = false
    @State private var showingDebugInfo = false

    var body: some View {
        NavigationView {
            Form {
                // アップロード設定
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("チャンクサイズ: \(Int(chunkSize)) MB")
                        Slider(value: $chunkSize, in: 0.5...10, step: 0.5)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("最大並列アップロード数: \(Int(maxConcurrentUploads))")
                        Slider(value: $maxConcurrentUploads, in: 1...8, step: 1)
                    }
                } header: {
                    Text("アップロード設定")
                } footer: {
                    Text("チャンクサイズが大きいほど効率的ですが、メモリ使用量が増加します。")
                }

                // 通知設定
                Section {
                    Toggle("通知を有効にする", isOn: $enableNotifications)

                    Toggle("自動再試行を有効にする", isOn: $enableAutoRetry)

                    if enableAutoRetry {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("再試行回数: \(Int(retryAttempts))")
                            Slider(value: $retryAttempts, in: 1...10, step: 1)
                        }
                    }
                } header: {
                    Text("通知と再試行")
                }

                // サーバー設定
                Section {
                    HStack {
                        Text("サーバーURL")
                        TextField("http://192.168.0.16:8000", text: $serverURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                } header: {
                    Text("サーバー設定")
                } footer: {
                    Text("アップロード先のサーバーURLを指定してください。")
                }

                // ストレージと履歴
                Section {
                    Button("アップロード履歴をクリア") {
                        UploadManager.shared.uploadHistory.removeAll()
                    }

                    Button("キャッシュをクリア") {
                        clearCache()
                    }

                    Button("一時ファイルをクリーンアップ") {
                        cleanupTemporaryFiles()
                    }
                } header: {
                    Text("ストレージ")
                }

                // デバッグ情報
                Section {
                    Button("デバッグ情報を表示") {
                        showingDebugInfo = true
                    }

                    Button("アプリについて") {
                        showingAbout = true
                    }
                } header: {
                    Text("情報")
                }

                // 統計情報
                Section {
                    StatisticsSection()
                } header: {
                    Text("統計")
                }
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .sheet(isPresented: $showingDebugInfo) {
                DebugInfoView()
            }
        }
    }

    private func clearCache() {
        // キャッシュクリアの実装
        AppLog.upload.notice("キャッシュをクリアしました")
    }

    private func cleanupTemporaryFiles() {
        // 一時ファイルクリーンアップの実装
        let tempDir = Foundation.FileManager.default.temporaryDirectory
        do {
            let tempFiles = try Foundation.FileManager.default
                .contentsOfDirectory(
                    at: tempDir,
                    includingPropertiesForKeys: nil
                )
            for file in tempFiles {
                if file.lastPathComponent.hasPrefix("upload_")
                    || file.lastPathComponent.hasPrefix("chunk_")
                {
                    try Foundation.FileManager.default.removeItem(at: file)
                }
            }
            AppLog.upload.notice("一時ファイルをクリーンアップしました")
        } catch {
            AppLog.upload.notice("一時ファイルクリーンアップエラー: \(error)")
        }
    }
}

// MARK: - Statistics Section

struct StatisticsSection: View {
    @StateObject private var uploadManager = UploadManager.shared

    var body: some View {
        let stats = uploadManager.getUploadStatistics()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("アクティブアップロード")
                Spacer()
                Text("\(stats.active)")
                    .fontWeight(.medium)
            }

            HStack {
                Text("完了したアップロード")
                Spacer()
                Text("\(stats.completed)")
                    .fontWeight(.medium)
                    .foregroundColor(.green)
            }

            HStack {
                Text("失敗したアップロード")
                Spacer()
                Text("\(stats.failed)")
                    .fontWeight(.medium)
                    .foregroundColor(.red)
            }

            HStack {
                Text("総アップロードサイズ")
                Spacer()
                Text(FileManager.shared.formatFileSize(stats.totalSize))
                    .fontWeight(.medium)
            }
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // アプリアイコン
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)

                    VStack(spacing: 8) {
                        Text("大容量ファイルアップロード")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("バージョン 1.0.0")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("機能")
                            .font(.headline)

                        FeatureRow(
                            icon: "icloud.and.arrow.up",
                            title: "チャンク分割アップロード",
                            description: "大容量ファイルを小さなチャンクに分割して確実にアップロード"
                        )

                        FeatureRow(
                            icon: "arrow.clockwise",
                            title: "自動再試行",
                            description: "ネットワークエラー時の自動再試行機能"
                        )

                        FeatureRow(
                            icon: "moon.fill",
                            title: "バックグラウンドアップロード",
                            description: "アプリがバックグラウンドにあってもアップロードを継続"
                        )

                        FeatureRow(
                            icon: "checkmark.shield",
                            title: "整合性チェック",
                            description: "SHA256チェックサムによるファイル整合性検証"
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("開発者")
                            .font(.headline)

                        Text("このアプリは大容量ファイルの安全で効率的なアップロードを実現するために開発されました。")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("アプリについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Debug Info View

struct DebugInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var uploadManager = UploadManager.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DebugSection(title: "Upload Manager") {
                        Text(uploadManager.getStatisticsDescription())
                            .font(.caption)
                            .monospaced()
                    }

                    DebugSection(title: "Active Sessions") {
                        VStack(alignment: .leading, spacing: 4) {
                            let sessionKeys = Array(uploadManager.activeUploads.keys)
                            ForEach(sessionKeys, id: \.self) { sessionId in
                                Text("Session: \(sessionId)")
                                    .font(.caption2)
                                    .monospaced()
                            }

                            if uploadManager.activeUploads.isEmpty {
                                Text("No active sessions")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    DebugSection(title: "Network Status") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Background sessions: Active")
                                .font(.caption2)
                                .monospaced()
                            
                            Text("Upload queues: \(uploadManager.activeUploads.count)")
                                .font(.caption2)
                                .monospaced()
                        }
                    }

                    DebugSection(title: "System Info") {
                        let systemInfo = getSystemInfo()
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(systemInfo, id: \.key) { info in
                                Text("\(info.key): \(info.value)")
                                    .font(.caption)
                                    .monospaced()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("デバッグ情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func getSystemInfo() -> [(key: String, value: String)] {
        return [
            ("iOS Version", UIDevice.current.systemVersion),
            ("Device Model", UIDevice.current.model),
            ("App State", UIApplication.shared.applicationState.description)
        ]
    }
}

struct DebugSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            content
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
        }
    }
}

// MARK: - Extensions

extension UIApplication.State {
    var description: String {
        switch self {
        case .active:
            return "Active"
        case .inactive:
            return "Inactive"
        case .background:
            return "Background"
        @unknown default:
            return "Unknown"
        }
    }
}

// MARK: - Preview

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryView()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
