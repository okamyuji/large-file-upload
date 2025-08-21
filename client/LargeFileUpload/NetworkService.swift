import Foundation
import UIKit

class NetworkService: NSObject, ObservableObject {
    static let shared = NetworkService()

    // MARK: - Properties

    private var backgroundSession: URLSession!
    private var controlSession: URLSession!

    @Published var activeUploadSessions: [String: UploadSession] = [:]
    
    // バックグラウンド完了ハンドラー
    var backgroundCompletionHandler: (() -> Void)?
    
    // 逐次処理用キュー管理
    private var uploadQueues: [String: UploadQueue] = [:]
    private var currentUploads: [String: String] = [:]
    
    // タスク監視用プロパティ
    private var activeTaskIds: [String: Int] = [:]  // sessionId -> taskIdentifier
    private var taskStartTimes: [String: Date] = [:]  // sessionId -> 開始時刻
    private var taskMonitorTimer: Timer?
    
    // アプリ状態管理（重要：MainActor使用を制御）
    private var isAppInBackground = false
    
    // エラー回数管理用の簡易実装
    private var errorCounts: [String: Int] = [:]

    // MARK: - Upload Queue Class
    
    private class UploadQueue {
        private var pendingChunks: [Int] = []
        private var isProcessing = false
        private let sessionId: String
        
        init(sessionId: String, totalChunks: Int) {
            self.sessionId = sessionId
            self.pendingChunks = Array(0..<totalChunks)
        }
        
        func getNextChunk() -> Int? {
            guard !pendingChunks.isEmpty else { return nil }
            return pendingChunks.removeFirst()
        }
        
        func markChunkCompleted(_ chunkIndex: Int) {
            print("✅ チャンク \(chunkIndex) 完了 - 残り: \(pendingChunks.count) 個")
        }
        
        func setProcessing(_ processing: Bool) {
            isProcessing = processing
        }
        
        var isCurrentlyProcessing: Bool {
            return isProcessing
        }
        
        var hasRemainingChunks: Bool {
            return !pendingChunks.isEmpty
        }
        
        var remainingCount: Int {
            return pendingChunks.count
        }
    }

    // MARK: - Initialization

    override init() {
        super.init()
        setupURLSessions()
        setupBackgroundObservers()
        setupNetworkCallbacks()
    }
    
    deinit {
        // タスク監視タイマーをクリーンアップ
        stopTaskMonitoring()
        NotificationCenter.default.removeObserver(self)
        print("🧹 [DEINIT] NetworkService リソースをクリーンアップ")
    }

    private func setupURLSessions() {
        let controlConfig = URLSessionConfiguration.default
        controlConfig.timeoutIntervalForRequest = 30
        controlConfig.timeoutIntervalForResource = 60
        controlSession = URLSession(configuration: controlConfig)

        let backgroundConfig = URLSessionConfiguration.background(
            withIdentifier: "com.largefileupload.background"
        )
        backgroundConfig.timeoutIntervalForResource = 0
        backgroundConfig.timeoutIntervalForRequest = 60
        backgroundConfig.httpMaximumConnectionsPerHost = 1  // 逐次処理
        backgroundConfig.isDiscretionary = false
        backgroundConfig.sessionSendsLaunchEvents = true
        
        // 📱 重要: 従量制接続（4G/5G）でのアップロードを有効化
        backgroundConfig.allowsCellularAccess = true
        backgroundConfig.allowsExpensiveNetworkAccess = true
        backgroundConfig.allowsConstrainedNetworkAccess = true
        
        // ネットワーク切り替え時のタイムアウト設定
        backgroundConfig.timeoutIntervalForRequest = 180  // 3分に延長（従量制接続用）
        backgroundConfig.waitsForConnectivity = true  // 接続待機を有効化
        
        // 📡 ネットワークサービスタイプをバルクデータ用に設定
        backgroundConfig.networkServiceType = .responsiveData
        
        // 🔄 マルチパスサービスでネットワーク切り替えをサポート
        if #available(iOS 11.0, *) {
            backgroundConfig.multipathServiceType = .handover
        }

        backgroundSession = URLSession(
            configuration: backgroundConfig,
            delegate: self,
            delegateQueue: nil
        )
        
        print("📱 [CONFIG] 従量制接続対応: allowsCellularAccess=\(backgroundConfig.allowsCellularAccess)")
        print("📶 [CONFIG] ネットワーク切り替え対応: waitsForConnectivity=\(backgroundConfig.waitsForConnectivity)")
        print("📡 [CONFIG] ネットワークサービスタイプ: \(backgroundConfig.networkServiceType.rawValue)")
        if #available(iOS 11.0, *) {
            print("🔄 [CONFIG] マルチパスサービス: \(backgroundConfig.multipathServiceType.rawValue)")
        }
        print("⏱️ [CONFIG] タイムアウト: \(Int(backgroundConfig.timeoutIntervalForRequest))秒")
    }

    private func setupBackgroundObservers() {
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
    }

    @objc private func appDidEnterBackground() {
        isAppInBackground = true
        print("🌙 バックグラウンド移行 - MainActor使用停止、逐次アップロード継続")
        
        // バックグラウンドでは過度な監視を停止してiOSに任せる
        stopTaskMonitoring()
        print("🛑 [BACKGROUND] タスク監視を停止 - 30秒後はiOSが管理")
    }

    @objc private func appWillEnterForeground() {
        isAppInBackground = false
        print("☀️ フォアグラウンド復帰 - UI更新再開")
        
        // フォアグラウンド復帰時のみMainActorでUI更新
        Task {
            await refreshAllSessionStatusSafely()
            await resumeIncompleteUploads() // 中断されたアップロードを再開
        }
    }

    // MARK: - Session Management

    func createUploadSession(fileURL: URL) async throws -> UploadSession {
        print("📝 セッション作成開始")
        
        let fileInfo = try FileManager.shared.getFileInfo(url: fileURL)
        let fileChecksum = try FileManager.shared.calculateFileChecksum(url: fileURL)
        let chunkInfo = FileManager.shared.calculateChunkInfo(fileSize: fileInfo.size)

        let request = CreateSessionRequest(
            fileName: fileInfo.name,
            totalChunks: chunkInfo.totalChunks,
            fileSize: fileInfo.size,
            fileChecksum: fileChecksum,
            chunkSize: chunkInfo.chunkSize
        )

        let response = try await performControlRequest(
            endpoint: .createSession,
            method: "POST",
            body: request,
            responseType: SessionResponse.self
        )

        let session = UploadSession(
            id: response.sessionId,
            fileName: fileInfo.name,
            fileURL: fileURL,
            totalChunks: chunkInfo.totalChunks,
            fileSize: fileInfo.size,
            fileChecksum: fileChecksum,
            chunkSize: chunkInfo.chunkSize
        )

        // セッション登録（完全に安全な方法）
        updateSessionStateSafely {
            self.activeUploadSessions[session.id] = session
        }
        
        uploadQueues[session.id] = UploadQueue(
            sessionId: session.id, 
            totalChunks: session.totalChunks
        )

        print("✅ セッション作成完了: \(session.id)")
        return session
    }

    // MARK: - Safe State Management (バックグラウンド完全対応)

    private func updateSessionStateSafely(_ updateBlock: @escaping () -> Void) {
        // isAppInBackgroundフラグのみ使用（MainActor安全）
        if isAppInBackground {
            // バックグラウンド時：MainActor使用禁止、直接更新
            updateBlock()
            print("🌙 [BACKGROUND] 状態更新: MainActor回避")
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
        if isAppInBackground {
            // バックグラウンド時：直接更新のみ（UI更新不要）
            updateBlock(session)
            print("🌙 [BACKGROUND] セッション更新: \(session.id)")
        } else {
            // フォアグラウンド時：UI更新も含める
            updateBlock(session)
            Task {
                await MainActor.run {
                    // UI更新のための追加処理（必要に応じて）
                    objectWillChange.send()
                }
            }
        }
    }

    // MARK: - Upload Management

    func startUpload(session: UploadSession) async throws {
        print("🚀 逐次アップロード開始: \(session.fileName)")
        
        // 状態更新（完全に安全な方法）
        updateSessionSafely(session) { session in
            session.updateStatus(.uploading)
        }

        try await startSequentialChunkUpload(session: session)
    }

    private func startSequentialChunkUpload(session: UploadSession) async throws {
        print("📤 逐次処理でチャンクアップロード開始")
        
        guard let queue = uploadQueues[session.id] else {
            throw NetworkError.sessionNotFound
        }

        if !queue.isCurrentlyProcessing {
            try await processNextChunk(session: session)
        }
    }

    private func processNextChunk(session: UploadSession) async throws {
        guard let queue = uploadQueues[session.id] else {
            print("⚠️ アップロードキュー \(session.id) が見つかりません")
            return
        }
        
        guard let nextChunkIndex = queue.getNextChunk() else {
            print("✅ 全チャンク送信完了: \(session.fileName)")
            return
        }
        
        queue.setProcessing(true)
        print("📤 逐次処理 - チャンク \(nextChunkIndex + 1)/\(session.totalChunks) 送信開始")
        
        try await uploadSingleChunkSequentially(
            session: session,
            chunkIndex: nextChunkIndex
        )
    }

    private func uploadSingleChunkSequentially(
        session: UploadSession,
        chunkIndex: Int
    ) async throws {
        let taskId = "\(session.id)_\(chunkIndex)"
        
        print("🚀 逐次送信 - セッション \(session.id) チャンク \(chunkIndex)")
        
        currentUploads[session.id] = taskId

        do {
            let chunkData = try FileManager.shared.readChunk(
                from: session.fileURL,
                chunkIndex: chunkIndex,
                chunkSize: session.chunkSize
            )
            let checksum = FileManager.shared.calculateChecksum(data: chunkData)

            let tempURL = try createTemporaryChunkFile(
                data: chunkData,
                sessionId: session.id,
                chunkIndex: chunkIndex
            )

            var request = URLRequest(
                url: APIEndpoint.uploadChunk(
                    sessionId: session.id,
                    chunkIndex: chunkIndex
                ).url
            )
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(checksum, forHTTPHeaderField: "X-Chunk-Checksum")

            let uploadTask = backgroundSession.uploadTask(with: request, fromFile: tempURL)
            
            // タスク監視情報を記録
            activeTaskIds[session.id] = uploadTask.taskIdentifier
            taskStartTimes[session.id] = Date()
            
            uploadTask.resume()
            
            print("📤 逐次送信タスク開始 - チャンク \(chunkIndex) (TaskID: \(uploadTask.taskIdentifier))")
            print("🔍 [TASK STATE] TaskID(\(uploadTask.taskIdentifier)) 状態: \(uploadTask.state.description)")
            print("🌐 [NETWORK CHECK] 現在のネットワーク状態: \(NetworkMonitor.shared.connectionType.displayName)")
            
            // タスク作成直後の状態確認（Sendable問題を回避するためsessionIdを事前キャプチャ）
            let capturedSessionId = session.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                Task {
                    await self?.verifyTaskProgress(taskId: uploadTask.taskIdentifier, sessionId: capturedSessionId, chunkIndex: chunkIndex)
                }
            }
            
            // バックグラウンドではタスク監視不要 - iOSに任せる
            if !isAppInBackground {
                startTaskMonitoringIfNeeded()
            }
            
        } catch {
            uploadQueues[session.id]?.setProcessing(false)
            currentUploads.removeValue(forKey: session.id)
            print("❌ チャンク \(chunkIndex) 逐次送信準備失敗: \(error)")
            
            // エラー時の再試行処理（Sendable問題を回避するためsessionIdを事前キャプチャ）
            let capturedSessionId = session.id
            Task {
                await handleChunkUploadErrorSafely(
                    sessionId: capturedSessionId,
                    chunkIndex: chunkIndex,
                    error: error
                )
            }
            
            throw error
        }
    }

    private func createTemporaryChunkFile(
        data: Data,
        sessionId: String,
        chunkIndex: Int
    ) throws -> URL {
        let tempDir = Foundation.FileManager.default.temporaryDirectory
        let fileName = "chunk_\(sessionId)_\(chunkIndex).dat"
        let tempURL = tempDir.appendingPathComponent(fileName)
        
        try data.write(to: tempURL)
        return tempURL
    }

    // MARK: - Session Status

    func getSessionStatus(sessionId: String) async throws -> StatusResponse {
        return try await performControlRequest(
            endpoint: .getStatus(sessionId: sessionId),
            method: "GET",
            responseType: StatusResponse.self
        )
    }

    func refreshAllSessionStatus() async {
        // フォアグラウンド専用（MainActor使用）
        await refreshAllSessionStatusSafely()
    }

    func deleteSession(sessionId: String) async throws {
        print("🗑️ セッション削除: \(sessionId)")
        
        let _ = try await performControlRequest(
            endpoint: .deleteSession(sessionId: sessionId),
            method: "DELETE",
            responseType: EmptyResponse.self
        )
        
        // ローカル状態もクリーンアップ
        uploadQueues.removeValue(forKey: sessionId)
        currentUploads.removeValue(forKey: sessionId)
        
        updateSessionStateSafely {
            self.activeUploadSessions.removeValue(forKey: sessionId)
        }
        
        print("✅ セッション削除完了: \(sessionId)")
    }

    private func refreshAllSessionStatusSafely() async {
        for (sessionId, session) in activeUploadSessions {
            do {
                let status = try await getSessionStatus(sessionId: sessionId)
                
                // 完全に安全な状態更新
                updateSessionStateSafely {
                    session.uploadedChunks = Set(0..<status.totalChunks)
                        .subtracting(Set(status.missingChunks))
                    session.updateProgress()

                    if session.status != .completed && session.status != .completing {
                        if status.status == "ready" && session.status == .uploading {
                            session.updateStatus(.ready)
                        } else if status.status == "completed" {
                            session.updateStatus(.completed)
                        }
                    }
                }
            } catch {
                print("セッション \(sessionId) のステータス更新に失敗: \(error)")
            }
        }
    }

    // MARK: - Upload Completion

    func completeUpload(session: UploadSession) async throws {
        print("🏁 アップロード完了処理開始: \(session.id)")
        
        updateSessionSafely(session) { session in
            session.updateStatus(.completing)
        }

        let response = try await performControlRequest(
            endpoint: .completeUpload(sessionId: session.id),
            method: "POST",
            responseType: CompleteResponse.self
        )

        updateSessionSafely(session) { session in
            session.updateStatus(.completed)
        }
        
        uploadQueues.removeValue(forKey: session.id)
        currentUploads.removeValue(forKey: session.id)
        
        // UploadManagerに完了を通知
        UploadManager.shared.notifyUploadCompletion(sessionId: session.id)
        
        print("✅ アップロード完了: \(response.filePath)")
    }

    // MARK: - Control Request Helper

    private func performControlRequest<T: Codable, R: Codable>(
        endpoint: APIEndpoint,
        method: String,
        body: T? = nil,
        responseType: R.Type
    ) async throws -> R {
        print("🌐 [CONTROL] \(method) \(endpoint.url.absoluteString)")
        
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await controlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown(
                NSError(domain: "Invalid response", code: -1)
            )
        }

        if httpResponse.statusCode >= 400 {
            print("❌ [CONTROL ERROR] Status: \(httpResponse.statusCode)")
            if let errorResponse = try? JSONDecoder().decode(
                ErrorResponse.self,
                from: data
            ) {
                throw NetworkError.httpError(
                    httpResponse.statusCode,
                    errorResponse.message
                )
            } else {
                throw NetworkError.httpError(
                    httpResponse.statusCode,
                    "Unknown server error"
                )
            }
        }

        return try JSONDecoder().decode(responseType, from: data)
    }

    private func performControlRequest<R: Codable>(
        endpoint: APIEndpoint,
        method: String,
        responseType: R.Type
    ) async throws -> R {
        let emptyBody: String? = nil
        return try await performControlRequest(
            endpoint: endpoint,
            method: method,
            body: emptyBody,
            responseType: responseType
        )
    }
}

// MARK: - URLSessionDelegate (完全にバックグラウンド安全)

extension NetworkService: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("🔔 BackgroundURLSession - 全タスク完了")
        
        // バックグラウンド完了ハンドラーのみMainThreadで実行
        if let handler = backgroundCompletionHandler {
            DispatchQueue.main.async {
                handler()
                self.backgroundCompletionHandler = nil
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskId = task.taskIdentifier
        let originalURL = task.originalRequest?.url?.absoluteString ?? "不明"
        
        guard let sessionId = findSessionIdForTask(task: task),
              let uploadSession = activeUploadSessions[sessionId],
              let queue = uploadQueues[sessionId] else {
            print("⚠️ タスク情報が見つかりません: TaskID(\(taskId)) URL(\(originalURL))")
            return
        }

        let chunkIndex = extractChunkIndex(from: task.originalRequest?.url)
        
        currentUploads.removeValue(forKey: sessionId)
        queue.setProcessing(false)
        
        // タスク監視情報をクリーンアップ
        activeTaskIds.removeValue(forKey: sessionId)
        taskStartTimes.removeValue(forKey: sessionId)
        
        print("📋 [TASK COMPLETED] TaskID(\(taskId)) チャンク(\(chunkIndex ?? -1)) セッション(\(sessionId))")
        print("🧹 [CLEANUP] タスク監視情報をクリーンアップ")

        if let error = error {
            let nsError = error as NSError
            print("❌ チャンク \(chunkIndex ?? -1) 逐次送信失敗: \(error.localizedDescription)")
            print("🔍 [ERROR DETAILS] Domain: \(nsError.domain), Code: \(nsError.code), URL: \(originalURL)")
            
            // ネットワーク関連エラーの判定と自動再試行
            if shouldRetryForNetworkError(error) {
                print("🔄 [NETWORK ERROR] ネットワークエラーで自動再試行: \(error.localizedDescription)")
                
                // 少し待機してから再試行（Sendable問題を回避するためsessionIdを事前キャプチャ）
                let capturedSessionId = sessionId
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機
                    print("🔄 [RETRY] チャンク \(chunkIndex ?? -1) を再送信開始")
                    
                    // sessionIdからセッションを安全に取得
                    if let session = self.activeUploadSessions[capturedSessionId] {
                        try? await self.processNextChunk(session: session)
                    }
                }
                
                return  // 通常のエラー処理をスキップ
            }
            
            // ネットワークエラー以外の場合はUploadManagerにエラーを通知
            if chunkIndex != nil {
                Task {
                    await UploadManager.shared.notifyUploadError(
                        sessionId: sessionId,
                        error: error
                    )
                }
            }
        } else if let httpResponse = task.response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                if let chunkIndex = chunkIndex {
                    print("✅ チャンク \(chunkIndex) 逐次送信成功")
                    
                    // バックグラウンド完全安全な処理
                    handleChunkUploadSuccessSafely(
                        sessionId: sessionId,
                        chunkIndex: chunkIndex,
                        session: uploadSession
                    )
                }
            } else {
                print("❌ チャンク \(chunkIndex ?? -1) HTTPエラー: \(httpResponse.statusCode)")
                
                // HTTPエラーもUploadManagerに通知
                if let chunkIndex = chunkIndex {
                    let httpError = NetworkError.httpError(
                        httpResponse.statusCode,
                        "HTTP\(httpResponse.statusCode) - チャンク\(chunkIndex)アップロード失敗"
                    )
                    Task {
                        await UploadManager.shared.notifyUploadError(
                            sessionId: sessionId,
                            error: httpError
                        )
                    }
                }
            }
        }

        if let chunkIndex = chunkIndex {
            cleanupTemporaryFile(sessionId: sessionId, chunkIndex: chunkIndex)
        }
    }

    // MARK: - Safe Background Processing (MainActor完全回避)

    private func handleChunkUploadSuccessSafely(
        sessionId: String,
        chunkIndex: Int,
        session: UploadSession
    ) {
        // バックグラウンド時も完全安全：MainActor使用禁止
        session.markChunkUploaded(chunkIndex)
        
        print("📊 [BACKGROUND SAFE] セッション \(sessionId): \(session.uploadedChunks.count)/\(session.totalChunks) 完了")
        
        uploadQueues[sessionId]?.markChunkCompleted(chunkIndex)
        
        if session.isComplete {
            // 完了処理（Sendable問題を回避するためsessionIdを事前キャプチャ）
            let capturedSessionId = sessionId
            Task {
                do {
                    // sessionIdからセッションを安全に取得
                    if let session = self.activeUploadSessions[capturedSessionId] {
                        try await self.completeUpload(session: session)
                    }
                } catch {
                    print("❌ 完了処理エラー: \(error)")
                }
            }
        } else {
            // 次のチャンクを逐次処理（Sendable問題を回避するためsessionIdを事前キャプチャ）
            let capturedSessionId = sessionId
            Task {
                do {
                    // sessionIdからセッションを安全に取得
                    if let session = self.activeUploadSessions[capturedSessionId] {
                        try await self.processNextChunk(session: session)
                    }
                } catch {
                    print("❌ 次のチャンク処理エラー: \(error)")
                    await self.handleChunkUploadErrorSafely(
                        sessionId: capturedSessionId,
                        chunkIndex: chunkIndex + 1,
                        error: error
                    )
                }
            }
        }
    }

    private func findSessionIdForTask(task: URLSessionTask) -> String? {
        guard let url = task.originalRequest?.url?.absoluteString else { return nil }
        
        let pattern = "/upload/session/([^/]+)/chunk/"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: url.count)
        
        if let match = regex?.firstMatch(in: url, options: [], range: range),
           let sessionIdRange = Range(match.range(at: 1), in: url) {
            return String(url[sessionIdRange])
        }
        
        return nil
    }

    private func extractChunkIndex(from url: URL?) -> Int? {
        guard let url = url?.absoluteString else { return nil }
        
        let pattern = "/chunk/(\\d+)$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: url.count)
        
        if let match = regex?.firstMatch(in: url, options: [], range: range),
           let chunkIndexRange = Range(match.range(at: 1), in: url) {
            return Int(String(url[chunkIndexRange]))
        }
        
        return nil
    }

    private func cleanupTemporaryFile(sessionId: String, chunkIndex: Int) {
        let tempDir = Foundation.FileManager.default.temporaryDirectory
        let fileName = "chunk_\(sessionId)_\(chunkIndex).dat"
        let tempURL = tempDir.appendingPathComponent(fileName)
        
        try? Foundation.FileManager.default.removeItem(at: tempURL)
    }
    
    // MARK: - Error Handling Methods
    
    private func handleChunkUploadErrorSafely(
        sessionId: String,
        chunkIndex: Int,
        error: Error
    ) async {
        guard let session = activeUploadSessions[sessionId],
              let queue = uploadQueues[sessionId] else {
            print("⚠️ エラーハンドリング: セッション \(sessionId) が見つかりません")
            return
        }
        
        print("🔄 [ERROR HANDLING] チャンク\(chunkIndex)エラー処理開始: \(error.localizedDescription)")
        
        // エラー回数の管理
        let errorKey = "\(sessionId)_\(chunkIndex)_errors"
        let currentErrors = getErrorCount(for: errorKey)
        let maxRetries = 3
        
        if currentErrors < maxRetries {
            // 再試行
            incrementErrorCount(for: errorKey)
            print("🔄 [RETRY] チャンク\(chunkIndex)を再試行します (\(currentErrors + 1)/\(maxRetries))")
            
            // 短い遅延後に再試行
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機
            
            queue.setProcessing(false) // 再試行のため一度リセット
            
            do {
                try await self.processNextChunk(session: session)
            } catch {
                print("❌ [RETRY FAILED] チャンク\(chunkIndex)再試行失敗: \(error)")
                await handleChunkUploadErrorSafely(
                    sessionId: sessionId,
                    chunkIndex: chunkIndex,
                    error: error
                )
            }
        } else {
            // 最大再試行回数に達した場合
            print("❌ [MAX RETRIES] チャンク\(chunkIndex)最大再試行回数に達しました")
            
            // UploadManagerにエラーを通知
            await UploadManager.shared.notifyUploadError(
                sessionId: sessionId,
                error: NetworkError.fileError("チャンク\(chunkIndex)アップロード失敗: \(error.localizedDescription)")
            )
            
            // アップロード処理を停止
            queue.setProcessing(false)
            currentUploads.removeValue(forKey: sessionId)
            clearErrorCount(for: errorKey)
        }
    }
    
    // エラー回数管理メソッド
    private func getErrorCount(for key: String) -> Int {
        return errorCounts[key] ?? 0
    }
    
    private func incrementErrorCount(for key: String) {
        errorCounts[key] = getErrorCount(for: key) + 1
    }
    
    private func clearErrorCount(for key: String) {
        errorCounts.removeValue(forKey: key)
    }
    
    // MARK: - Foreground Resume
    
    func resumeIncompleteUploads() async {
        print("🔄 [GENTLE RESUME] 不完全なアップロードの穏やかなチェックを実行")
        
        for (sessionId, session) in activeUploadSessions {
            guard let queue = uploadQueues[sessionId] else { continue }
            
            // 長時間停止しているセッションのみ、穏やかに再開を試みる
            if session.status == .uploading && !queue.isCurrentlyProcessing && queue.hasRemainingChunks {
                print("🔄 [GENTLE RESUME] セッション \(sessionId) を穏やかに再開試行")
                
                // エラーがあっても、BackgroundURLSessionの自然復旧を信頼
                do {
                    try await processNextChunk(session: session)
                } catch {
                    print("⚠️ [GENTLE RESUME] セッション \(sessionId) の穏やかな再開に失敗: \(error.localizedDescription)")
                    // 再開に失敗しても、BackgroundURLSessionの自然復旧を信頼
                }
            } else {
                print("✅ [GENTLE RESUME] セッション \(sessionId) は正常動作中")
            }
        }
        
        print("✅ [GENTLE RESUME] 穏やかなチェック完了")
    }
    
    // MARK: - Network Callbacks Setup
    
    /// ネットワーク変更時のコールバックを設定
    private func setupNetworkCallbacks() {
        let networkMonitor = NetworkMonitor.shared
        
        // ネットワーク接続タイプ変更時の処理（WiFi ⇄ Cellular切り替え）
        networkMonitor.onNetworkChange { [weak self] previousType, currentType in
            guard let self = self else { return }
            
            print("🔄 [NETWORK CALLBACK] 接続変更を検出: \(previousType.displayName) → \(currentType.displayName)")
            
            // 非同期でアップロード再開処理を実行
            Task {
                await self.handleNetworkTransition(from: previousType, to: currentType)
            }
        }
        
        // ネットワーク接続復旧時の処理
        networkMonitor.onConnectionRecovery { [weak self] in
            guard let self = self else { return }
            
            print("📶 [NETWORK CALLBACK] 接続復旧を検出 - アップロード再開処理を開始")
            
            // 非同期でアップロード再開処理を実行
            Task {
                await self.handleConnectionRecovery()
            }
        }
        
        print("🔗 [NETWORK CALLBACKS] ネットワーク変更時の自動再開処理を設定完了")
    }
    
    /// ネットワーク切り替え時の処理
    private func handleNetworkTransition(from previousType: NetworkMonitor.ConnectionType, to currentType: NetworkMonitor.ConnectionType) async {
        print("🔄 [NETWORK TRANSITION] \(previousType.displayName) → \(currentType.displayName) での積極的な監視を開始")
        
        // ネットワーク切り替え時は、即座タスク状態を確認
        
        // 1. 即座タスク状態確認
        await immediateTaskStateCheck(reason: "ネットワーク切り替え")
        
        // 2. 10秒待機後に積極的なタスク失効検出と復旧
        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10秒待機
        await forceCheckStaleTasksAfterNetworkTransition()
        
        // 3. 監視タイマーを強化（一時的に間隔を短縮）
        enhanceTaskMonitoringTemporarily()
    }
    
    /// 即座タスク状態確認
    private func immediateTaskStateCheck(reason: String) async {
        print("🔍 [IMMEDIATE CHECK] \(reason)による即座タスク状態確認を開始")
        
        let tasks = await backgroundSession.allTasks
        
        for (sessionId, taskId) in activeTaskIds {
            var foundTask: URLSessionTask?
            
            for task in tasks {
                if task.taskIdentifier == taskId {
                    foundTask = task
                    break
                }
            }
            
            if let task = foundTask {
                print("🔍 [IMMEDIATE CHECK] セッション(\(sessionId)) TaskID(\(taskId)) 状態: \(task.state.description)")
                print("🔍 [IMMEDIATE CHECK] 送信バイト: \(task.countOfBytesSent)/\(task.countOfBytesExpectedToSend)")
                
                // タスクが停止・キャンセル状態の場合は即座復旧
                if task.state == .suspended {
                    print("⚠️ [IMMEDIATE CHECK] TaskID(\(taskId)) が一時停止 - 再開を試行")
                    task.resume()
                } else if task.state == .canceling || task.state == .completed {
                    print("⚠️ [IMMEDIATE CHECK] TaskID(\(taskId)) が異常状態 - 即座復旧が必要")
                    
                    await cleanupStaleTask(sessionId: sessionId)
                    
                    if let session = activeUploadSessions[sessionId] {
                        do {
                            try await processNextChunk(session: session)
                            print("✅ [IMMEDIATE CHECK] 即座復旧が完了: \(sessionId)")
                        } catch {
                            print("❌ [IMMEDIATE CHECK] 即座復旧に失敗: \(sessionId) - \(error)")
                        }
                    }
                }
            } else {
                print("❌ [IMMEDIATE CHECK] セッション(\(sessionId)) TaskID(\(taskId)) が納失 - 即座復旧が必要")
                
                await cleanupStaleTask(sessionId: sessionId)
                
                if let session = activeUploadSessions[sessionId] {
                    do {
                        try await processNextChunk(session: session)
                        print("✅ [IMMEDIATE CHECK] 納失タスクの即座復旧が完了: \(sessionId)")
                    } catch {
                        print("❌ [IMMEDIATE CHECK] 納失タスクの復旧に失敗: \(sessionId) - \(error)")
                    }
                }
            }
        }
        
        print("✅ [IMMEDIATE CHECK] \(reason)による即座タスク状態確認が完了")
    }
    
    /// ネットワーク切り替え後の積極的なタスク検出
    private func forceCheckStaleTasksAfterNetworkTransition() async {
        let currentTime = Date()
        let networkTransitionTimeout: TimeInterval = 10.0  // ネットワーク切り替え時は10秒で失効とみなす
        
        print("🔍 [FORCE CHECK] ネットワーク切り替え後の積極的なタスク検出を開始")
        
        for (sessionId, startTime) in taskStartTimes {
            let elapsedTime = currentTime.timeIntervalSince(startTime)
            
            // ネットワーク切り替え時は通常より省いタイムアウトで失効検出
            if elapsedTime > networkTransitionTimeout {
                guard let session = activeUploadSessions[sessionId],
                      let _ = uploadQueues[sessionId] else {
                    continue
                }
                
                print("⚠️ [TRANSITION STALE] ネットワーク切り替えでタスク失効: セッション \(sessionId) (\(Int(elapsedTime))秒経過, 閾値: 10秒)")
                print("🔄 [TRANSITION RECOVERY] ネットワーク切り替え復旧を開始")
                
                // 失効したタスクをクリーンアップ
                await cleanupStaleTask(sessionId: sessionId)
                
                // 新しいタスクで再開
                do {
                    try await processNextChunk(session: session)
                    print("✅ [TRANSITION RECOVERY] ネットワーク切り替え復旧が完了: \(sessionId)")
                } catch {
                    print("❌ [TRANSITION RECOVERY] ネットワーク切り替え復旧に失敗: \(sessionId) - \(error)")
                }
            }
        }
        
        print("✅ [FORCE CHECK] ネットワーク切り替え後の積極的なタスク検出が完了")
    }
    
    /// 一時的にタスク監視を強化
    private func enhanceTaskMonitoringTemporarily() {
        print("🔍 [ENHANCED MONITOR] ネットワーク切り替え時の強化監視を開始 (3秒間隔)")
        
        // 既存のタイマーを停止
        stopTaskMonitoring()
        
        // 3秒間隔で強化監視を開始
        taskMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task {
                await self?.checkForStaleTasksAndRecover()
            }
        }
        
        // 2分後に通常の監視間隔に戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            print("🔍 [ENHANCED MONITOR] 強化監視を終了 - 通常監視に戻します")
            self?.stopTaskMonitoring()
            self?.startTaskMonitoringIfNeeded()
        }
    }
    
    /// 接続復旧時の処理
    private func handleConnectionRecovery() async {
        print("📶 [CONNECTION RECOVERY] 接続復旧後の軽量チェックを開始")
        
        // 少し待機してから軽量な状態確認
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒待機
        
        await checkSessionStatusQuietly()
    }
    
    // MARK: - Lightweight Network Handling
    
    /// 軽量なセッション状態確認（強制介入なし）
    private func checkSessionStatusQuietly() async {
        print("🔍 [QUIET CHECK] アクティブセッションの軽量チェックを実行")
        
        for (sessionId, session) in activeUploadSessions {
            guard let queue = uploadQueues[sessionId] else { continue }
            
            // アップロードが長時間停止している場合のみ、優しく再開
            if session.status == .uploading && 
               !queue.isCurrentlyProcessing && 
               queue.hasRemainingChunks {
                
                print("🔄 [GENTLE RESUME] セッション \(sessionId) を優しく再開")
                
                // 強制的ではなく、優しく再開を試みる
                do {
                    try await processNextChunk(session: session)
                } catch {
                    print("⚠️ [GENTLE RESUME] セッション \(sessionId) の優しい再開に失敗: \(error.localizedDescription)")
                    // エラーがあっても、BackgroundURLSessionの自然復旧を信頼
                }
            } else {
                print("✅ [QUIET CHECK] セッション \(sessionId) は正常状態")
            }
        }
        
        print("✅ [QUIET CHECK] 軽量チェック完了")
    }
    
    // MARK: - Task Monitoring and Recovery
    
    /// タスク監視タイマーを開始
    private func startTaskMonitoringIfNeeded() {
        guard taskMonitorTimer == nil else { return }
        
        print("🔍 [TASK MONITOR] タスク監視タイマーを開始")
        
        taskMonitorTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task {
                await self?.checkForStaleTasksAndRecover()
            }
        }
    }
    
    /// 停止中のタスク監視タイマーを停止
    private func stopTaskMonitoring() {
        taskMonitorTimer?.invalidate()
        taskMonitorTimer = nil
        print("🔍 [TASK MONITOR] タスク監視タイマーを停止")
    }
    
    /// 失効したタスクを検出して自動復旧
    private func checkForStaleTasksAndRecover() async {
        let currentTime = Date()
        let timeoutInterval: TimeInterval = 60.0  // 60秒でタスク失効とみなす
        
        for (sessionId, startTime) in taskStartTimes {
            let elapsedTime = currentTime.timeIntervalSince(startTime)
            
            // 60秒以上経過したタスクを失効とみなす
            if elapsedTime > timeoutInterval {
                guard let session = activeUploadSessions[sessionId],
                      let _ = uploadQueues[sessionId] else {
                    continue
                }
                
                print("⚠️ [STALE TASK] セッション \(sessionId) のタスクが失効 (\(Int(elapsedTime))秒経過, 闾値: 60秒)")
                print("🔄 [RECOVERY] 失効タスクを検出 - 自動復旧を開始")
                
                // 失効したタスクをクリーンアップ
                await cleanupStaleTask(sessionId: sessionId)
                
                // 新しいタスクで再開
                do {
                    try await processNextChunk(session: session)
                    print("✅ [RECOVERY] セッション \(sessionId) の自動復旧が完了")
                } catch {
                    print("❌ [RECOVERY] セッション \(sessionId) の自動復旧に失敗: \(error)")
                }
            }
        }
        
        // アクティブなタスクがない場合は監視を停止
        if activeTaskIds.isEmpty {
            stopTaskMonitoring()
        }
    }
    
    /// 失効したタスクをクリーンアップ
    private func cleanupStaleTask(sessionId: String) async {
        // タスク監視情報をクリーンアップ
        activeTaskIds.removeValue(forKey: sessionId)
        taskStartTimes.removeValue(forKey: sessionId)
        currentUploads.removeValue(forKey: sessionId)
        
        // キューの処理状態をリセット
        uploadQueues[sessionId]?.setProcessing(false)
        
        print("🧹 [CLEANUP] セッション \(sessionId) の失効タスクをクリーンアップ完了")
    }
    
    /// タスクの進捗を確認
    private func verifyTaskProgress(taskId: Int, sessionId: String, chunkIndex: Int) async {
        print("🔍 [TASK VERIFY] TaskID(\(taskId)) の進捗を確認中...")
        
        // BackgroundSessionのアクティブタスクを取得
        let tasks = await backgroundSession.allTasks
        
        var foundTask: URLSessionTask?
        for task in tasks {
            if task.taskIdentifier == taskId {
                foundTask = task
                break
            }
        }
        
        if let task = foundTask {
            print("🔍 [TASK VERIFY] TaskID(\(taskId)) 状態: \(task.state.description)")
            print("🔍 [TASK VERIFY] TaskID(\(taskId)) 送信バイト: \(task.countOfBytesSent)/\(task.countOfBytesExpectedToSend)")
            
            // タスクが停止している場合の該断
            if task.state == .suspended {
                print("⚠️ [TASK VERIFY] TaskID(\(taskId)) が一時停止状態 - 再開を試行")
                task.resume()
            } else if task.state == .canceling || task.state == .completed {
                print("⚠️ [TASK VERIFY] TaskID(\(taskId)) が異常状態 (\(task.state.description)) - 即座復旧が必要")
                
                // 即座復旧を実行
                await cleanupStaleTask(sessionId: sessionId)
                
                if let session = activeUploadSessions[sessionId] {
                    do {
                        try await processNextChunk(session: session)
                        print("✅ [TASK VERIFY] 即座復旧が完了: \(sessionId)")
                    } catch {
                        print("❌ [TASK VERIFY] 即座復旧に失敗: \(sessionId) - \(error)")
                    }
                }
            } else {
                print("✅ [TASK VERIFY] TaskID(\(taskId)) は正常状態 (\(task.state.description))")
            }
        } else {
            print("❌ [TASK VERIFY] TaskID(\(taskId)) が見つかりません - タスクが失効した可能性")
            
            // タスクが見つからない場合は即座復旧
            await cleanupStaleTask(sessionId: sessionId)
            
            if let session = activeUploadSessions[sessionId] {
                do {
                    try await processNextChunk(session: session)
                    print("✅ [TASK VERIFY] 納失タスクの即座復旧が完了: \(sessionId)")
                } catch {
                    print("❌ [TASK VERIFY] 納失タスクの復旧に失敗: \(sessionId) - \(error)")
                }
            }
        }
    }
    
    // MARK: - Network Error Handling
    
    /// ネットワークエラーで再試行すべきか判定
    private func shouldRetryForNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        
        // キャンセルエラーは再試行しない（意図的なキャンセル）
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            print("⚠️ [CANCEL ERROR] キャンセルエラーは再試行しない: \(nsError.localizedDescription)")
            return false
        }
        
        // ネットワーク関連のエラーコードをチェック（穏やかな再試行のみ）
        let networkErrorCodes: [Int] = [
            NSURLErrorNetworkConnectionLost,     // ネットワーク接続が失われた
            NSURLErrorTimedOut,                   // タイムアウト
            NSURLErrorNotConnectedToInternet,     // インターネット未接続
            NSURLErrorCannotConnectToHost,        // ホストに接続できない
            NSURLErrorDNSLookupFailed,            // DNS解決失敗
        ]
        
        let shouldRetry = nsError.domain == NSURLErrorDomain && networkErrorCodes.contains(nsError.code)
        
        if shouldRetry {
            print("🔄 [NETWORK ERROR] 穏やかな再試行対象エラー: \(nsError.localizedDescription) (Code: \(nsError.code))")
        } else {
            print("❌ [NETWORK ERROR] 再試行対象外エラー: \(nsError.localizedDescription) (Code: \(nsError.code))")
        }
        
        return shouldRetry
    }
}

// MARK: - URLSessionTask State Extension

extension URLSessionTask.State {
    var description: String {
        switch self {
        case .running:
            return "実行中"
        case .suspended:
            return "一時停止"
        case .canceling:
            return "キャンセル中"
        case .completed:
            return "完了"
        @unknown default:
            return "不明"
        }
    }
}
