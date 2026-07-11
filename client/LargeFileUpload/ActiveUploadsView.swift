import SwiftUI

// MARK: - Active Uploads View

struct ActiveUploadsView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var showingCancelAlert = false
    @State private var sessionToCancel: String?

    var body: some View {
        NavigationView {
            Group {
                if uploadManager.activeUploads.isEmpty {
                    EmptyActiveUploadsView()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(
                                Array(uploadManager.activeUploads.values),
                                id: \.id
                            ) { session in
                                UploadSessionCard(
                                    session: session,
                                    onPause: {
                                        uploadManager.pauseUpload(
                                            sessionId: session.id
                                        )
                                    },
                                    onResume: {
                                        Task {
                                            try await uploadManager.resumeUpload(
                                                sessionId: session.id
                                            )
                                        }
                                    },
                                    onCancel: {
                                        sessionToCancel = session.id
                                        showingCancelAlert = true
                                    }
                                )
                                .contextMenu {
                                    Button(role: .destructive) {
                                        uploadManager.discardSession(
                                            sessionId: session.id,
                                            reason: "user-removed"
                                        )
                                    } label: {
                                        Label("進行中から削除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("アクティブアップロード")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("すべて一時停止") {
                            for sessionId in uploadManager.activeUploads.keys {
                                uploadManager.pauseUpload(sessionId: sessionId)
                            }
                        }
                        .disabled(uploadManager.activeUploads.isEmpty)

                        Button("失敗分を再試行") {
                            Task {
                                await uploadManager.retryFailedUploads()
                            }
                        }

                        Divider()

                        Button("すべてキャンセル", role: .destructive) {
                            sessionToCancel = "all"
                            showingCancelAlert = true
                        }
                        .disabled(uploadManager.activeUploads.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("アップロードをキャンセル", isPresented: $showingCancelAlert) {
                Button("キャンセル", role: .cancel) {
                    sessionToCancel = nil
                }
                Button("確定", role: .destructive) {
                    if let sessionId = sessionToCancel {
                        Task {
                            if sessionId == "all" {
                                await uploadManager.cancelAllUploads()
                            } else {
                                await uploadManager.cancelUpload(
                                    sessionId: sessionId
                                )
                            }
                        }
                    }
                    sessionToCancel = nil
                }
            } message: {
                if sessionToCancel == "all" {
                    Text("すべてのアクティブアップロードをキャンセルしますか？")
                } else {
                    Text("このアップロードをキャンセルしますか？")
                }
            }
        }
    }
}

// MARK: - Empty Active Uploads View

struct EmptyActiveUploadsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("アクティブなアップロードはありません")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Text("ファイルを選択してアップロードを開始してください")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Upload Session Card

struct UploadSessionCard: View {
    @ObservedObject var session: UploadSession
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ヘッダー
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.fileName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(FileManager.shared.formatFileSize(session.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                StatusBadge(status: session.status)
            }

            // 進捗バー
            ProgressSection(session: session)

            // エラー表示
            if let error = session.error {
                ErrorView(error: error)
            }

            // アクションボタン
            ActionButtons(
                session: session,
                onPause: onPause,
                onResume: onResume,
                onCancel: onCancel
            )
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: UploadStatus

    var body: some View {
        Text(status.description)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(8)
    }

    private var backgroundColor: Color {
        switch status {
        case .created: return .blue.opacity(0.2)
        case .uploading: return .orange.opacity(0.2)
        case .ready: return .yellow.opacity(0.2)
        case .completing: return .purple.opacity(0.2)
        case .completed: return .green.opacity(0.2)
        case .error: return .red.opacity(0.2)
        case .paused: return .gray.opacity(0.2)
        case .cancelled: return .gray.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .created: return .blue
        case .uploading: return .orange
        case .ready: return .yellow
        case .completing: return .purple
        case .completed: return .green
        case .error: return .red
        case .paused: return .gray
        case .cancelled: return .gray
        }
    }
}

// MARK: - Progress Section

struct ProgressSection: View {
    @ObservedObject var session: UploadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("進捗")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(
                    "\(session.uploadedChunks.count) / \(session.totalChunks) チャンク"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Text("\(Int(session.progress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            ProgressView(value: session.progress)
                .progressViewStyle(LinearProgressViewStyle(tint: progressColor))

            if !session.missingChunks.isEmpty
                && session.missingChunks.count < 10
            {
                Text(
                    "未完了チャンク: \(session.missingChunks.map(String.init).joined(separator: ", "))"
                )
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var progressColor: Color {
        switch session.status {
        case .error: return .red
        case .completed: return .green
        case .paused, .cancelled: return .gray
        default: return .blue
        }
    }
}

// MARK: - Error View

struct ErrorView: View {
    let error: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.caption)

            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Action Buttons

struct ActionButtons: View {
    @ObservedObject var session: UploadSession
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    // 状態と主アクションの対応を1箇所にまとめる。UI 側で分岐を書き散らかさないため。
    // - 送信中 (created / ready / uploading): 主アクション = 一時停止
    // - 一時停止 (paused): 主アクション = 再開
    // - エラー (error): 主アクション = 再試行 (経路は resume と同じ SoT 再取得)
    // - completing / completed: 主アクションなし (処理中 or 完了)
    private enum PrimaryAction { case pause, resume, retry, none }

    private var primaryAction: PrimaryAction {
        switch session.status {
        case .created, .ready, .uploading: return .pause
        case .paused: return .resume
        case .error: return .retry
        case .completing, .completed, .cancelled: return .none
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            switch primaryAction {
            case .pause:
                Button(action: onPause) {
                    Label("一時停止", systemImage: "pause.fill").font(.caption)
                }.buttonStyle(SecondaryButtonStyle())
            case .resume:
                Button(action: onResume) {
                    Label("再開", systemImage: "play.fill").font(.caption)
                }.buttonStyle(PrimaryButtonStyle())
            case .retry:
                Button(action: onResume) {
                    Label("再試行", systemImage: "arrow.clockwise").font(.caption)
                }.buttonStyle(PrimaryButtonStyle())
            case .none:
                EmptyView()
            }

            Spacer()

            // completed / completing はサーバ側で確定処理中なのでキャンセル不可
            if session.status != .completed && session.status != .completing {
                Button(action: onCancel) {
                    Label("キャンセル", systemImage: "xmark")
                        .font(.caption)
                }
                .buttonStyle(DestructiveButtonStyle())
            }
        }
    }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(configuration.isPressed ? 0.8 : 1.0))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(configuration.isPressed ? 0.3 : 0.2))
            .foregroundColor(.primary)
            .cornerRadius(8)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(configuration.isPressed ? 0.8 : 1.0))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

// MARK: - Detailed Session View

struct DetailedSessionView: View {
    @ObservedObject var session: UploadSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // セッション基本情報
                    SessionInfoSection(session: session)

                    // 進捗詳細
                    ProgressDetailSection(session: session)

                    // チャンク詳細
                    ChunkDetailSection(session: session)
                }
                .padding()
            }
            .navigationTitle(session.fileName)
            .navigationBarTitleDisplayMode(.large)
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

struct SessionInfoSection: View {
    @ObservedObject var session: UploadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("セッション情報")
                .font(.headline)

            InfoRow(title: "セッションID", value: session.id)
            InfoRow(
                title: "ファイルサイズ",
                value: FileManager.shared.formatFileSize(session.fileSize)
            )
            InfoRow(
                title: "チャンクサイズ",
                value: FileManager.shared.formatFileSize(
                    Int64(session.chunkSize)
                )
            )
            InfoRow(title: "総チャンク数", value: "\(session.totalChunks)")
            InfoRow(title: "ステータス", value: session.status.description)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct ProgressDetailSection: View {
    @ObservedObject var session: UploadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("進捗詳細")
                .font(.headline)

            ProgressView(value: session.progress)
                .progressViewStyle(LinearProgressViewStyle())

            HStack {
                Text("完了:")
                Spacer()
                Text("\(session.uploadedChunks.count) / \(session.totalChunks)")
            }

            HStack {
                Text("進捗率:")
                Spacer()
                Text("\(Int(session.progress * 100))%")
            }

            if !session.missingChunks.isEmpty {
                HStack {
                    Text("未完了:")
                    Spacer()
                    Text("\(session.missingChunks.count)")
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct ChunkDetailSection: View {
    @ObservedObject var session: UploadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("チャンク詳細")
                .font(.headline)

            if !session.missingChunks.isEmpty
                && session.missingChunks.count <= 50
            {
                Text("未完了チャンク:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: 5),
                    spacing: 8
                ) {
                    ForEach(session.missingChunks, id: \.self) { chunkIndex in
                        Text("\(chunkIndex)")
                            .font(.caption)
                            .padding(4)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                }
            } else if session.missingChunks.count > 50 {
                Text(
                    "未完了チャンク: \(session.missingChunks.count) 個（最初の10個: \(session.missingChunks.prefix(10).map(String.init).joined(separator: ", "))...）"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
                Text("すべてのチャンクが完了しました")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Preview

struct ActiveUploadsView_Previews: PreviewProvider {
    static var previews: some View {
        ActiveUploadsView()
    }
}
