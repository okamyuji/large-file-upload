import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var selectedTab = 0
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationView {
            TabView(selection: $selectedTab) {
                // メインアップロードタブ
                MainUploadView(
                    showingFilePicker: $showingFilePicker,
                    showingAlert: $showingAlert,
                    alertMessage: $alertMessage
                )
                .tabItem {
                    Image(systemName: "icloud.and.arrow.up")
                    Text("アップロード")
                }
                .tag(0)

                // アクティブアップロードタブ
                ActiveUploadsView()
                    .tabItem {
                        Image(systemName: "progress.indicator")
                        Text("進行中")
                    }
                    .tag(1)

                // 履歴・設定タブ
                HistoryView()
                    .tabItem {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("履歴")
                    }
                    .tag(2)
            }
            .navigationTitle(tabTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NetworkStatusIndicator()
                }
            }
        }
        .sheet(isPresented: $showingFilePicker) {
            DocumentPicker { urls in
                handleSelectedFiles(urls)
            }
        }
        .alert("通知", isPresented: $showingAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            setupApp()
        }
    }

    private var tabTitle: String {
        switch selectedTab {
        case 0: return "ファイルアップロード"
        case 1: return "進行中のアップロード"
        case 2: return "履歴・設定"
        default: return "ファイルアップロード"
        }
    }

    private func setupApp() {
        print("ContentView初期化完了")
    }

    private func handleSelectedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else {
            DispatchQueue.main.async {
                self.alertMessage = "ファイルが選択されていません"
                self.showingAlert = true
            }
            return
        }

        for url in urls {
            startUpload(fileURL: url)
        }
    }

    private func startUpload(fileURL: URL) {
        Task {
            do {
                // ファイル情報を先に取得して検証
                let fileInfo = try FileManager.shared.getFileInfo(url: fileURL)
                print("ファイル情報: \(fileInfo.name), \(fileInfo.size) bytes")

                // UploadManager経由でBackgroundURLSessionアップロード開始
                let session = try await uploadManager.startUpload(fileURL: fileURL)

                await MainActor.run {
                    self.alertMessage = "\(session.fileName) のBackgroundURLSessionアップロードを開始しました"
                    self.showingAlert = true
                }
            } catch let error as NetworkError {
                DispatchQueue.main.async {
                    self.alertMessage = "\(error.localizedDescription)"
                    self.showingAlert = true
                }
                print("アップロードエラー: \(error)")
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage =
                        "アップロード開始エラー: \(error.localizedDescription)"
                    self.showingAlert = true
                }
                print("予期しないエラー: \(error)")
            }

            // セキュリティスコープ付きリソースへのアクセスを終了
            fileURL.stopAccessingSecurityScopedResource()
        }
    }
}

// MARK: - Main Upload View

struct MainUploadView: View {
    @Binding var showingFilePicker: Bool
    @Binding var showingAlert: Bool
    @Binding var alertMessage: String
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var uploadManager: UploadManager

    var body: some View {
        VStack(spacing: 24) {
            HeaderView()
            NetworkStatusCard()
            UploadAreaView(showingFilePicker: $showingFilePicker)

            if !uploadManager.allSessions.isEmpty {
                StatisticsView()
            }

            Spacer()
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Header View

struct HeaderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.up.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("大容量ファイルアップロード")
                .font(.title2)
                .fontWeight(.bold)

            Text("安全で高速なチャンク分割アップロード")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Network Status Card

struct NetworkStatusCard: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        HStack {
            Image(systemName: networkStatusIcon)
                .foregroundColor(networkStatusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("ネットワーク状態")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(networkStatusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()

            if networkMonitor.isOptimalForUpload {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }

    private var networkStatusIcon: String {
        switch networkMonitor.connectionType {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .ethernet: return "cable.connector"
        default: return "network.slash"
        }
    }

    private var networkStatusColor: Color {
        if networkMonitor.isConnected {
            return networkMonitor.isOptimalForUpload ? .green : .orange
        } else {
            return .red
        }
    }

    private var networkStatusText: String {
        if !networkMonitor.isConnected {
            return "未接続"
        }

        var status = networkMonitor.connectionType.displayName
        if networkMonitor.isExpensive {
            status += " (従量制)"
        }
        if networkMonitor.isConstrained {
            status += " (制限あり)"
        }
        return status
    }
}

// MARK: - Upload Area View

struct UploadAreaView: View {
    @Binding var showingFilePicker: Bool

    var body: some View {
        Button(action: { showingFilePicker = true }) {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("ファイルを選択してアップロード")
                    .font(.headline)

                Text("タップしてファイルを選択")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                Color.blue,
                                style: StrokeStyle(lineWidth: 2, dash: [5])
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Statistics View

struct StatisticsView: View {
    @EnvironmentObject private var uploadManager: UploadManager

    var body: some View {
        VStack(spacing: 12) {
            Text("統計情報")
                .font(.headline)

            HStack(spacing: 20) {
                StatCard(
                    title: "総セッション",
                    value: "\(uploadManager.allSessions.count)",
                    icon: "doc.text"
                )

                StatCard(
                    title: "進行中",
                    value: "\(uploadManager.activeUploads.count)",
                    icon: "arrow.up.circle"
                )

                StatCard(
                    title: "完了",
                    value: "\(uploadManager.completedUploads.count)",
                    icon: "checkmark.circle"
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Network Status Indicator

struct NetworkStatusIndicator: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        Button(action: {}) {
            Image(
                systemName: networkMonitor.isConnected ? "wifi" : "wifi.slash"
            )
            .foregroundColor(networkMonitor.isConnected ? .green : .red)
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentsPicked: ([URL]) -> Void

    func makeUIViewController(context: Context)
        -> UIDocumentPickerViewController
    {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .item
        ])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentsPicked: onDocumentsPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentsPicked: ([URL]) -> Void

        init(onDocumentsPicked: @escaping ([URL]) -> Void) {
            self.onDocumentsPicked = onDocumentsPicked
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            // セキュリティスコープ付きリソースへのアクセスを開始
            var accessibleURLs: [URL] = []

            for url in urls {
                if url.startAccessingSecurityScopedResource() {
                    accessibleURLs.append(url)
                    print("ファイルアクセス許可取得: \(url.lastPathComponent)")
                } else {
                    print("ファイルアクセス許可取得失敗: \(url.lastPathComponent)")
                }
            }

            onDocumentsPicked(accessibleURLs)
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            print("ドキュメントピッカーがキャンセルされました")
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(NetworkMonitor.shared)
            .environmentObject(UploadManager.shared)
    }
}
