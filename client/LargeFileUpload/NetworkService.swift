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

    /// happy-path 永続化のデバウンス管理。sessionId -> 最終 save 時刻。
    /// initial(uploadedChunks==1) と complete は無条件で save、それ以外は
    /// happyPathPersistInterval を超えた場合のみ save して I/O を抑制する。
    private var lastPersistAt: [String: Date] = [:]
    private let happyPathPersistInterval: TimeInterval = 2.0

    /// resumeSessionFromServer が「古い OS タスクの掃除」目的で cancel した taskIdentifier の集合。
    /// delegate 側でここに載っている taskIdentifier の cancel エラーは benign 扱いして
    /// notifyUploadError を発火させない。pause 経由の cancel (session.status == .paused) と同じ扱い。
    private var taskIdsPendingResumeCancel: Set<Int> = []

    /// 上記のすべての可変辞書 (activeTaskIds/taskStartTimes/currentUploads/uploadQueues/errorCounts/
    /// activeUploadSessions) は複数の実行コンテキスト (URLSession delegate queue / Task / Timer)
    /// から触られるため、直列化するための再入可能ロック。
    private let stateLock = NSRecursiveLock()
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Upload Queue Class
    
    private class UploadQueue {
        private var pendingChunks: [Int] = []
        private var isProcessing = false
        private let sessionId: String

        init(sessionId: String, totalChunks: Int) {
            self.sessionId = sessionId
            self.pendingChunks = Array(0..<totalChunks)
        }

        /// 明示的な chunk 集合で初期化する。resume 経路で「サーバ側 missing のみ」を積むために使う。
        init(sessionId: String, chunks: [Int]) {
            self.sessionId = sessionId
            self.pendingChunks = chunks.sorted()
        }
        
        func getNextChunk() -> Int? {
            guard !pendingChunks.isEmpty else { return nil }
            return pendingChunks.removeFirst()
        }
        
        func markChunkCompleted(_ chunkIndex: Int) {
            AppLog.upload.notice("✅ チャンク \(chunkIndex) 完了 - 残り: \(self.pendingChunks.count) 個")
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
        AppLog.upload.notice("🧹 [DEINIT] NetworkService リソースをクリーンアップ")
    }

    private func setupURLSessions() {
        let controlConfig = URLSessionConfiguration.default
        controlConfig.timeoutIntervalForRequest = 30
        controlConfig.timeoutIntervalForResource = 60
        controlSession = URLSession(configuration: controlConfig)

        let backgroundConfig = URLSessionConfiguration.background(
            withIdentifier: "com.largefileupload.background"
        )
        // 大容量転送: リソース全体タイムアウトは明示的に7日
        backgroundConfig.timeoutIntervalForResource = 60 * 60 * 24 * 7
        // リクエスト単体タイムアウト: 従量制/低速回線を考慮して5分
        backgroundConfig.timeoutIntervalForRequest = 300
        backgroundConfig.httpMaximumConnectionsPerHost = 1  // 逐次処理
        backgroundConfig.isDiscretionary = false
        backgroundConfig.sessionSendsLaunchEvents = true
        // バックグラウンドでの Extended idle mode (iOS の TCP 保持を強化)
        backgroundConfig.shouldUseExtendedBackgroundIdleMode = true

        // 📱 重要: 従量制接続（4G/5G）でのアップロードを有効化
        backgroundConfig.allowsCellularAccess = true
        backgroundConfig.allowsExpensiveNetworkAccess = true
        backgroundConfig.allowsConstrainedNetworkAccess = true

        // ネットワーク切り替え時の待機
        backgroundConfig.waitsForConnectivity = true
        
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
        
        AppLog.upload.notice("📱 [CONFIG] 従量制接続対応: allowsCellularAccess=\(backgroundConfig.allowsCellularAccess)")
        AppLog.upload.notice("📶 [CONFIG] ネットワーク切り替え対応: waitsForConnectivity=\(backgroundConfig.waitsForConnectivity)")
        AppLog.upload.notice("📡 [CONFIG] ネットワークサービスタイプ: \(backgroundConfig.networkServiceType.rawValue)")
        if #available(iOS 11.0, *) {
            AppLog.upload.notice("🔄 [CONFIG] マルチパスサービス: \(backgroundConfig.multipathServiceType.rawValue)")
        }
        AppLog.upload.notice("⏱️ [CONFIG] タイムアウト: \(Int(backgroundConfig.timeoutIntervalForRequest))秒")
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
        AppLog.upload.notice("🌙 バックグラウンド移行 - MainActor使用停止、逐次アップロード継続")
        
        // バックグラウンドでは過度な監視を停止してiOSに任せる
        stopTaskMonitoring()
        AppLog.upload.notice("🛑 [BACKGROUND] タスク監視を停止 - 30秒後はiOSが管理")
    }

    @objc private func appWillEnterForeground() {
        isAppInBackground = false
        AppLog.upload.notice("☀️ フォアグラウンド復帰 - UI更新再開")
        
        // フォアグラウンド復帰時のみMainActorでUI更新
        Task {
            await refreshAllSessionStatusSafely()
            await resumeIncompleteUploads() // 中断されたアップロードを再開
        }
    }

    // MARK: - Session Management

    func createUploadSession(fileURL: URL) async throws -> UploadSession {
        AppLog.upload.notice("📝 セッション作成開始")
        
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

        // Resume Bug 対策: Document Picker が渡すセキュリティスコープ付き URL は
        // 当該実行中しか読めない。Force Quit → 再起動後は scope が失われ Resume 時に
        // readChunk が黙って失敗して PUT が飛ばなかった (=「再開が効かない」バグの真因)。
        // そこでソースファイルをアプリ所有の Documents/uploads/ にステージングしてから
        // UploadSession に持たせる。以降 session.fileURL はいつでも読める。
        //
        // ステージング失敗時はサーバ側にだけセッションが残る「孤立セッション」を防ぐため、
        // ここで明示的に DELETE してから元のエラーを再送する。
        let stagedURL: URL
        do {
            stagedURL = try FileManager.shared.stageFileForUpload(
                sourceURL: fileURL,
                sessionId: response.sessionId
            )
        } catch {
            AppLog.upload.error("⚠️ [ROLLBACK] stageFileForUpload 失敗 → サーバ側セッション削除: \(response.sessionId)")
            _ = try? await performControlRequest(
                endpoint: .deleteSession(sessionId: response.sessionId),
                method: "DELETE",
                responseType: EmptyResponse.self
            )
            throw error
        }

        let session = UploadSession(
            id: response.sessionId,
            fileName: fileInfo.name,
            fileURL: stagedURL,
            totalChunks: chunkInfo.totalChunks,
            fileSize: fileInfo.size,
            fileChecksum: fileChecksum,
            chunkSize: chunkInfo.chunkSize
        )

        // セッション登録（完全に安全な方法）
        // FLAW 4/5 の余波修正: activeUploadSessions と uploadQueues への書き込みは
        // 単一 withState で atomic に保護する。異スレッドからの並行 mutation で SIGSEGV していた。
        withState {
            self.activeUploadSessions[session.id] = session
            self.uploadQueues[session.id] = UploadQueue(
                sessionId: session.id,
                totalChunks: session.totalChunks
            )
        }

        AppLog.upload.notice("✅ セッション作成完了: \(session.id)")
        return session
    }

    // MARK: - Safe State Management (バックグラウンド完全対応)

    private func updateSessionStateSafely(_ updateBlock: @escaping () -> Void) {
        // isAppInBackgroundフラグのみ使用（MainActor安全）
        if isAppInBackground {
            // バックグラウンド時：MainActor使用禁止、直接更新
            updateBlock()
            AppLog.upload.notice("🌙 [BACKGROUND] 状態更新: MainActor回避")
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
            AppLog.upload.notice("🌙 [BACKGROUND] セッション更新: \(session.id)")
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
        AppLog.upload.notice("🚀 逐次アップロード開始: \(session.fileName)")
        
        // 状態更新（完全に安全な方法）
        updateSessionSafely(session) { session in
            session.updateStatus(.uploading)
        }

        try await startSequentialChunkUpload(session: session)
    }

    private func startSequentialChunkUpload(session: UploadSession) async throws {
        AppLog.upload.notice("📤 逐次処理でチャンクアップロード開始")
        
        guard let queue = uploadQueues[session.id] else {
            throw NetworkError.sessionNotFound
        }

        if !queue.isCurrentlyProcessing {
            try await processNextChunk(session: session)
        }
    }

    private func processNextChunk(session: UploadSession) async throws {
        guard let queue = uploadQueues[session.id] else {
            AppLog.upload.notice("⚠️ アップロードキュー \(session.id) が見つかりません")
            return
        }
        
        guard let nextChunkIndex = queue.getNextChunk() else {
            AppLog.upload.notice("✅ 全チャンク送信完了: \(session.fileName)")
            return
        }
        
        queue.setProcessing(true)
        AppLog.upload.notice("📤 逐次処理 - チャンク \(nextChunkIndex + 1)/\(session.totalChunks) 送信開始")
        
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
        
        AppLog.upload.notice("🚀 逐次送信 - セッション \(session.id) チャンク \(chunkIndex)")

        withState {
            currentUploads[session.id] = taskId
        }

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
            withState {
                activeTaskIds[session.id] = uploadTask.taskIdentifier
                taskStartTimes[session.id] = Date()
            }
            
            uploadTask.resume()

            AppLog.upload.notice("📤 逐次送信タスク開始 - チャンク \(chunkIndex) (TaskID: \(uploadTask.taskIdentifier))")
            AppLog.upload.notice("🌐 [NETWORK CHECK] 現在のネットワーク状態: \(NetworkMonitor.shared.connectionType.displayName)")
            // 追加の DispatchQueue-based 監視は data race を招くため廃止。
            // BackgroundURLSession の delegate 通知に任せる (iOS 側で管理される)。

        } catch {
            withState {
                uploadQueues[session.id]?.setProcessing(false)
                currentUploads.removeValue(forKey: session.id)
            }
            AppLog.upload.notice("❌ チャンク \(chunkIndex) 逐次送信準備失敗: \(error)")
            
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

    /// pauseUpload から呼ぶ。指定 session の OS 側 in-flight タスクをすべて cancel する。
    /// delegate 側の cleanup (currentUploads / activeTaskIds) は didCompleteWithError で行われる。
    func pauseOSTasks(sessionId: String) async {
        let tasks = await backgroundSession.allTasks
        var canceled = 0
        for task in tasks {
            if let url = task.originalRequest?.url,
               Self.extractSessionId(from: url) == sessionId {
                task.cancel()
                canceled += 1
            }
        }
        AppLog.upload.notice("⏸ [PAUSE] session=\(sessionId) cancelled \(canceled) OS tasks")
        withState {
            uploadQueues[sessionId]?.setProcessing(false)
        }
    }

    /// サーバ側の MissingChunks 情報でクライアント側の状態を同期し、未送信チャンクの送信を再開する。
    /// アプリ再起動時、長時間バックグラウンド後のフォアグラウンド復帰時、および pause → resume 経路で呼ぶ。
    ///
    /// Resume Bug 対策:
    /// - queue を「サーバ側 missing チャンクのみ」で作り直す (既に到達済みの chunk への再送 PUT を撲滅)
    /// - 古い queue の isProcessing フラグが true のまま残る詰まりを回避するため、常に queue を作り直す
    /// - 進行中の OS 側タスクがあれば cancel してから作り直す (delegate 再入や重複送信を防ぐ)
    /// - session.status を .uploading に統一 (paused/error からの復帰でも UI 表示が整合)
    /// - missingChunks が空ならサーバ側完了なので completeUpload に進む
    func resumeSessionFromServer(_ session: UploadSession) async throws {
        AppLog.upload.notice("🔁 [RESUME] サーバ状態同期開始: \(session.id)")
        let status = try await getSessionStatus(sessionId: session.id)
        NetworkService.syncUploadedChunks(
            session: session,
            missingChunks: status.missingChunks,
            totalChunks: session.totalChunks
        )
        AppLog.upload.notice("🔁 [RESUME] 同期完了: uploaded=\(session.uploadedChunks.count)/\(session.totalChunks) missing=\(status.missingChunks.count)")

        // 進行中の OS タスクがあれば片付ける (このセッション分のみ)。
        // cancel された taskIdentifier は「resume 由来の意図した cancel」として記録し、
        // delegate 側でエラー通知に流さないようにする (session.status は .uploading のままなので
        // paused fast path には乗らない)。
        let osTasks = await backgroundSession.allTasks
        for task in osTasks {
            if let url = task.originalRequest?.url,
               Self.extractSessionId(from: url) == session.id {
                withState { taskIdsPendingResumeCancel.insert(task.taskIdentifier) }
                task.cancel()
            }
        }

        // クリーンな状態で queue を作り直し、session を再登録、status を .uploading に統一する。
        withState {
            uploadQueues[session.id] = UploadQueue(
                sessionId: session.id,
                chunks: status.missingChunks
            )
            activeUploadSessions[session.id] = session
            currentUploads.removeValue(forKey: session.id)
            activeTaskIds.removeValue(forKey: session.id)
        }
        session.updateStatus(status.missingChunks.isEmpty ? .completing : .uploading)

        // サーバ側完了なら completeUpload、まだなら次チャンク送信を開始
        if status.missingChunks.isEmpty {
            try await completeUpload(session: session)
        } else {
            try await processNextChunk(session: session)
        }
    }

    /// missingChunks からセッションの uploadedChunks を再構成する pure 関数 (テスト対象)。
    static func syncUploadedChunks(session: UploadSession, missingChunks: [Int], totalChunks: Int) {
        let missing = Set(missingChunks)
        let all = Set(0..<totalChunks)
        session.uploadedChunks = all.subtracting(missing)
        session.updateProgress()
    }

    func refreshAllSessionStatus() async {
        // フォアグラウンド専用（MainActor使用）
        await refreshAllSessionStatusSafely()
    }

    func deleteSession(sessionId: String) async throws {
        AppLog.upload.notice("🗑️ セッション削除: \(sessionId)")

        // ① セッションを先に activeUploadSessions から取り除く。
        //    これで cancel の delegate 到達時に findSessionIdForTask がヒットしても
        //    後段の `activeUploadSessions[sessionId]` guard が失敗し、
        //    ユーザ向けエラー通知は上がらない (FLAW 4 対策)。
        withState {
            activeUploadSessions.removeValue(forKey: sessionId)
        }

        // ② OS 所有の live タスクを cancel (v2 追加)
        await cancelOSTasks(sessionId: sessionId)

        // ③ サーバに DELETE
        let _ = try await performControlRequest(
            endpoint: .deleteSession(sessionId: sessionId),
            method: "DELETE",
            responseType: EmptyResponse.self
        )

        // ④ 残りのローカル状態クリーンアップ (withState)
        withState {
            uploadQueues.removeValue(forKey: sessionId)
            currentUploads.removeValue(forKey: sessionId)
            activeTaskIds.removeValue(forKey: sessionId)
            taskStartTimes.removeValue(forKey: sessionId)
        }

        // ⑤ temp file GC (v2 追加)
        cleanupSessionTempFiles(sessionId: sessionId)

        AppLog.upload.notice("✅ セッション削除完了: \(sessionId)")
    }

    /// セッション固有の temp file を全削除 (v2)
    private func cleanupSessionTempFiles(sessionId: String) {
        let tempDir = Foundation.FileManager.default.temporaryDirectory
        let files = (try? Foundation.FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let prefix = "chunk_\(sessionId)_"
        for name in files where name.hasPrefix(prefix) {
            try? Foundation.FileManager.default.removeItem(at: tempDir.appendingPathComponent(name))
        }
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
                AppLog.upload.notice("セッション \(sessionId) のステータス更新に失敗: \(error)")
            }
        }
    }

    // MARK: - Upload Completion

    func completeUpload(session: UploadSession) async throws {
        AppLog.upload.notice("🏁 アップロード完了処理開始: \(session.id)")
        
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

        withState {
            uploadQueues.removeValue(forKey: session.id)
            currentUploads.removeValue(forKey: session.id)
        }

        // ステージングした Documents/uploads/ 配下のコピーは完了後に不要なので削除
        FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL)

        // UploadManagerに完了を通知
        UploadManager.shared.notifyUploadCompletion(sessionId: session.id)
        
        AppLog.upload.notice("✅ アップロード完了: \(response.filePath)")
    }

    // MARK: - Control Request Helper

    private func performControlRequest<T: Codable, R: Codable>(
        endpoint: APIEndpoint,
        method: String,
        body: T? = nil,
        responseType: R.Type
    ) async throws -> R {
        AppLog.upload.notice("🌐 [CONTROL] \(method) \(endpoint.url.absoluteString)")
        
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
            AppLog.upload.notice("❌ [CONTROL ERROR] Status: \(httpResponse.statusCode)")
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
        AppLog.upload.notice("🔔 BackgroundURLSession - 全タスク完了")
        
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

        // lookup + cleanup を単一 withState でアトミックに (race 対策)。
        // sessionId/uploadSession/queue の読み出しと 4 dict の cleanup を同じ critical
        // section で行い、途中で deleteSession 等が割り込む可能性を排除する。
        struct DelegateContext {
            let sessionId: String
            let uploadSession: UploadSession
            let queue: UploadQueue
        }
        var ctx: DelegateContext?
        withState {
            guard let sessionId = findSessionIdForTask(task: task),
                  let uploadSession = activeUploadSessions[sessionId],
                  let queue = uploadQueues[sessionId] else {
                return
            }
            ctx = DelegateContext(sessionId: sessionId, uploadSession: uploadSession, queue: queue)
            currentUploads.removeValue(forKey: sessionId)
            queue.setProcessing(false)
            activeTaskIds.removeValue(forKey: sessionId)
            taskStartTimes.removeValue(forKey: sessionId)
        }
        guard let ctx else {
            AppLog.upload.notice("⚠️ タスク情報が見つかりません: TaskID(\(taskId)) URL(\(originalURL))")
            return
        }
        let sessionId = ctx.sessionId
        let uploadSession = ctx.uploadSession
        _ = ctx.queue // 一時的な保持は cleanup 時のみ必要

        let chunkIndex = extractChunkIndex(from: task.originalRequest?.url)
        
        AppLog.upload.notice("📋 [TASK COMPLETED] TaskID(\(taskId)) チャンク(\(chunkIndex ?? -1)) セッション(\(sessionId))")
        AppLog.upload.notice("🧹 [CLEANUP] タスク監視情報をクリーンアップ")

        // 成功パス: HTTP 200 系
        if error == nil, let httpResponse = task.response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) {
            if let chunkIndex = chunkIndex {
                AppLog.upload.notice("✅ チャンク \(chunkIndex) 逐次送信成功 (HTTP \(httpResponse.statusCode))")
                handleChunkUploadSuccessSafely(
                    sessionId: sessionId,
                    chunkIndex: chunkIndex,
                    session: uploadSession
                )
                cleanupTemporaryFile(sessionId: sessionId, chunkIndex: chunkIndex)
            }
            return
        }

        // 失敗パス: エラーまたは非2xx。RetryClassifier で判断
        let httpResp = task.response as? HTTPURLResponse
        let ns = error as NSError?
        let retryAfterHeader = httpResp?.value(forHTTPHeaderField: "Retry-After")
        let decision = RetryClassifier.classify(
            nsErrorCode: ns?.code,
            nsErrorDomain: ns?.domain,
            httpStatus: httpResp?.statusCode,
            retryAfterHeader: retryAfterHeader
        )
        let errorDesc = error?.localizedDescription
            ?? "HTTP \(httpResp?.statusCode ?? -1)"
        AppLog.upload.notice("❌ チャンク \(chunkIndex ?? -1) 失敗: \(errorDesc) → decision=\(decision)")

        // Pause / Resume-cleanup 対策: 意図した cancel は .error に落とさず静かに終わる。
        // 発火経路が 2 つあり、それぞれ判定材料が違うので両方を見る:
        //   ① pause 由来: pauseUpload が先に session.status = .paused にしてから cancel する
        //   ② resume 由来: resumeSessionFromServer が古い OS タスク掃除のために cancel する。
        //      status は .uploading のままなので、taskIdsPendingResumeCancel の membership で判定する。
        let isCancel = (ns?.domain == NSURLErrorDomain && ns?.code == NSURLErrorCancelled)
        let isPendingResumeCancel = withState { taskIdsPendingResumeCancel.remove(taskId) != nil }
        if isCancel && (uploadSession.status == .paused || isPendingResumeCancel) {
            let reason = isPendingResumeCancel ? "resume-cleanup" : "paused"
            AppLog.upload.notice("⏸ [BENIGN CANCEL/\(reason)] session=\(sessionId) chunk=\(chunkIndex ?? -1) error 通知せずに終了")
            if let chunkIndex = chunkIndex {
                cleanupTemporaryFile(sessionId: sessionId, chunkIndex: chunkIndex)
            }
            return
        }

        // fail: UploadManager へ通知して終わり
        switch decision {
        case .fail:
            if let chunkIndex = chunkIndex {
                let notifiedError: Error = error ?? NetworkError.httpError(
                    httpResp?.statusCode ?? -1,
                    "HTTP\(httpResp?.statusCode ?? -1) - チャンク\(chunkIndex)アップロード失敗"
                )
                Task {
                    await UploadManager.shared.notifyUploadError(
                        sessionId: sessionId,
                        error: notifiedError
                    )
                }
                cleanupTemporaryFile(sessionId: sessionId, chunkIndex: chunkIndex)
            }
            return

        case .retry, .retryAfter:
            // v2: earliestBeginDate ベースの OS 所有スケジューリングに委譲
            guard let ci = chunkIndex else {
                AppLog.retry.error("scheduleChunkRetry: chunkIndex 不明で retry 不可、fail 扱い")
                Task {
                    await UploadManager.shared.notifyUploadError(
                        sessionId: sessionId,
                        error: error ?? NetworkError.fileError("chunkIndex 不明")
                    )
                }
                return
            }
            scheduleChunkRetry(sessionId: sessionId, chunkIndex: ci, decision: decision)
            return
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

        AppLog.upload.notice("📊 [BACKGROUND SAFE] セッション \(sessionId): \(session.uploadedChunks.count)/\(session.totalChunks) 完了")

        uploadQueues[sessionId]?.markChunkCompleted(chunkIndex)

        // Bug A 対策: happy-path でも永続化を行う。
        // - 初回チャンク到達 (uploadedChunks.count == 1) は無条件で save
        // - 完了時 (isComplete) は無条件で save
        // - それ以外は同一セッションで happyPathPersistInterval(=2s) を超えた場合のみ save
        // これにより Force Quit や OS kill でも upload_state.json が最新に近い状態で残る。
        persistHappyPath(sessionId: sessionId, session: session)
        
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
                    AppLog.upload.notice("❌ 完了処理エラー: \(error)")
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
                    AppLog.upload.notice("❌ 次のチャンク処理エラー: \(error)")
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
        // v2: prep-path error は基本的に transient として retry させる
        // (disk hiccup, temp file 作成失敗等は再試行で回復するケースが多い)。
        // ただし意図的なキャンセルは fail 扱い。
        let ns = error as NSError
        let isCancel = (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            || (ns.domain == "NSCocoaErrorDomain" && ns.code == 4097)
        let decision: RetryDecision = isCancel ? .fail : .retry
        AppLog.upload.notice("🔄 [PREP ERROR] チャンク\(chunkIndex): \(error.localizedDescription) → decision=\(decision)")
        scheduleChunkRetry(sessionId: sessionId, chunkIndex: chunkIndex, decision: decision)
    }

    // エラー回数管理メソッド (v2 は UploadSession.chunkRetryCounts に一本化、以下は互換用)
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
        AppLog.upload.notice("🔄 [GENTLE RESUME] 不完全なアップロードの穏やかなチェックを実行")
        
        for (sessionId, session) in activeUploadSessions {
            guard let queue = uploadQueues[sessionId] else { continue }
            
            // 長時間停止しているセッションのみ、穏やかに再開を試みる
            if session.status == .uploading && !queue.isCurrentlyProcessing && queue.hasRemainingChunks {
                AppLog.upload.notice("🔄 [GENTLE RESUME] セッション \(sessionId) を穏やかに再開試行")
                
                // エラーがあっても、BackgroundURLSessionの自然復旧を信頼
                do {
                    try await processNextChunk(session: session)
                } catch {
                    AppLog.upload.notice("⚠️ [GENTLE RESUME] セッション \(sessionId) の穏やかな再開に失敗: \(error.localizedDescription)")
                    // 再開に失敗しても、BackgroundURLSessionの自然復旧を信頼
                }
            } else {
                AppLog.upload.notice("✅ [GENTLE RESUME] セッション \(sessionId) は正常動作中")
            }
        }
        
        AppLog.upload.notice("✅ [GENTLE RESUME] 穏やかなチェック完了")
    }
    
    // MARK: - Network Callbacks Setup
    
    /// ネットワーク変更時のコールバックを設定
    private func setupNetworkCallbacks() {
        let networkMonitor = NetworkMonitor.shared
        
        // ネットワーク接続タイプ変更時の処理（WiFi ⇄ Cellular切り替え）
        networkMonitor.onNetworkChange { [weak self] previousType, currentType in
            guard let self = self else { return }
            
            AppLog.upload.notice("🔄 [NETWORK CALLBACK] 接続変更を検出: \(previousType.displayName) → \(currentType.displayName)")
            
            // 非同期でアップロード再開処理を実行
            Task {
                await self.handleNetworkTransition(from: previousType, to: currentType)
            }
        }
        
        // ネットワーク接続復旧時の処理
        networkMonitor.onConnectionRecovery { [weak self] in
            guard let self = self else { return }
            
            AppLog.upload.notice("📶 [NETWORK CALLBACK] 接続復旧を検出 - アップロード再開処理を開始")
            
            // 非同期でアップロード再開処理を実行
            Task {
                await self.handleConnectionRecovery()
            }
        }
        
        AppLog.upload.notice("🔗 [NETWORK CALLBACKS] ネットワーク変更時の自動再開処理を設定完了")
    }
    
    /// ネットワーク切り替え時の処理
    private func handleNetworkTransition(from previousType: NetworkMonitor.ConnectionType, to currentType: NetworkMonitor.ConnectionType) async {
        AppLog.upload.notice("🔄 [NETWORK TRANSITION] \(previousType.displayName) → \(currentType.displayName) での積極的な監視を開始")
        
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
        AppLog.upload.notice("🔍 [IMMEDIATE CHECK] \(reason)による即座タスク状態確認を開始")
        
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
                AppLog.upload.notice("🔍 [IMMEDIATE CHECK] セッション(\(sessionId)) TaskID(\(taskId)) 状態: \(task.state.description)")
                AppLog.upload.notice("🔍 [IMMEDIATE CHECK] 送信バイト: \(task.countOfBytesSent)/\(task.countOfBytesExpectedToSend)")
                
                // タスクが停止・キャンセル状態の場合は即座復旧
                if task.state == .suspended {
                    AppLog.upload.notice("⚠️ [IMMEDIATE CHECK] TaskID(\(taskId)) が一時停止 - 再開を試行")
                    task.resume()
                } else if task.state == .canceling || task.state == .completed {
                    AppLog.upload.notice("⚠️ [IMMEDIATE CHECK] TaskID(\(taskId)) が異常状態 - 即座復旧が必要")
                    
                    await cleanupStaleTask(sessionId: sessionId)
                    
                    if let session = activeUploadSessions[sessionId] {
                        do {
                            try await processNextChunk(session: session)
                            AppLog.upload.notice("✅ [IMMEDIATE CHECK] 即座復旧が完了: \(sessionId)")
                        } catch {
                            AppLog.upload.notice("❌ [IMMEDIATE CHECK] 即座復旧に失敗: \(sessionId) - \(error)")
                        }
                    }
                }
            } else {
                AppLog.upload.notice("❌ [IMMEDIATE CHECK] セッション(\(sessionId)) TaskID(\(taskId)) が納失 - 即座復旧が必要")
                
                await cleanupStaleTask(sessionId: sessionId)
                
                if let session = activeUploadSessions[sessionId] {
                    do {
                        try await processNextChunk(session: session)
                        AppLog.upload.notice("✅ [IMMEDIATE CHECK] 納失タスクの即座復旧が完了: \(sessionId)")
                    } catch {
                        AppLog.upload.notice("❌ [IMMEDIATE CHECK] 納失タスクの復旧に失敗: \(sessionId) - \(error)")
                    }
                }
            }
        }
        
        AppLog.upload.notice("✅ [IMMEDIATE CHECK] \(reason)による即座タスク状態確認が完了")
    }
    
    /// ネットワーク切り替え後の積極的なタスク検出
    private func forceCheckStaleTasksAfterNetworkTransition() async {
        let currentTime = Date()
        let networkTransitionTimeout: TimeInterval = 10.0  // ネットワーク切り替え時は10秒で失効とみなす
        
        AppLog.upload.notice("🔍 [FORCE CHECK] ネットワーク切り替え後の積極的なタスク検出を開始")
        
        for (sessionId, startTime) in taskStartTimes {
            let elapsedTime = currentTime.timeIntervalSince(startTime)
            
            // ネットワーク切り替え時は通常より省いタイムアウトで失効検出
            if elapsedTime > networkTransitionTimeout {
                guard let session = activeUploadSessions[sessionId],
                      let _ = uploadQueues[sessionId] else {
                    continue
                }
                
                AppLog.upload.notice("⚠️ [TRANSITION STALE] ネットワーク切り替えでタスク失効: セッション \(sessionId) (\(Int(elapsedTime))秒経過, 閾値: 10秒)")
                AppLog.upload.notice("🔄 [TRANSITION RECOVERY] ネットワーク切り替え復旧を開始")
                
                // 失効したタスクをクリーンアップ
                await cleanupStaleTask(sessionId: sessionId)
                
                // 新しいタスクで再開
                do {
                    try await processNextChunk(session: session)
                    AppLog.upload.notice("✅ [TRANSITION RECOVERY] ネットワーク切り替え復旧が完了: \(sessionId)")
                } catch {
                    AppLog.upload.notice("❌ [TRANSITION RECOVERY] ネットワーク切り替え復旧に失敗: \(sessionId) - \(error)")
                }
            }
        }
        
        AppLog.upload.notice("✅ [FORCE CHECK] ネットワーク切り替え後の積極的なタスク検出が完了")
    }
    
    /// 一時的にタスク監視を強化
    private func enhanceTaskMonitoringTemporarily() {
        // Timer ベースの強化監視は data race の原因となるため無効化。
        // ネットワーク切り替え検知はネットワークコールバック側で処理する。
    }
    
    /// 接続復旧時の処理
    private func handleConnectionRecovery() async {
        AppLog.upload.notice("📶 [CONNECTION RECOVERY] 接続復旧後の軽量チェックを開始")
        
        // 少し待機してから軽量な状態確認
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒待機
        
        await checkSessionStatusQuietly()
    }
    
    // MARK: - Lightweight Network Handling
    
    /// 軽量なセッション状態確認（強制介入なし）
    private func checkSessionStatusQuietly() async {
        AppLog.upload.notice("🔍 [QUIET CHECK] アクティブセッションの軽量チェックを実行")
        
        for (sessionId, session) in activeUploadSessions {
            guard let queue = uploadQueues[sessionId] else { continue }
            
            // アップロードが長時間停止している場合のみ、優しく再開
            if session.status == .uploading && 
               !queue.isCurrentlyProcessing && 
               queue.hasRemainingChunks {
                
                AppLog.upload.notice("🔄 [GENTLE RESUME] セッション \(sessionId) を優しく再開")
                
                // 強制的ではなく、優しく再開を試みる
                do {
                    try await processNextChunk(session: session)
                } catch {
                    AppLog.upload.notice("⚠️ [GENTLE RESUME] セッション \(sessionId) の優しい再開に失敗: \(error.localizedDescription)")
                    // エラーがあっても、BackgroundURLSessionの自然復旧を信頼
                }
            } else {
                AppLog.upload.notice("✅ [QUIET CHECK] セッション \(sessionId) は正常状態")
            }
        }
        
        AppLog.upload.notice("✅ [QUIET CHECK] 軽量チェック完了")
    }
    
    // MARK: - Task Monitoring and Recovery
    
    /// タスク監視タイマーを開始
    private func startTaskMonitoringIfNeeded() {
        // Timer ベースのタスク監視は data race の原因となるため無効化。
        // BackgroundURLSession の delegate 通知に委譲する。
    }
    
    /// 停止中のタスク監視タイマーを停止
    private func stopTaskMonitoring() {
        taskMonitorTimer?.invalidate()
        taskMonitorTimer = nil
        AppLog.upload.notice("🔍 [TASK MONITOR] タスク監視タイマーを停止")
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
                
                AppLog.upload.notice("⚠️ [STALE TASK] セッション \(sessionId) のタスクが失効 (\(Int(elapsedTime))秒経過, 闾値: 60秒)")
                AppLog.upload.notice("🔄 [RECOVERY] 失効タスクを検出 - 自動復旧を開始")
                
                // 失効したタスクをクリーンアップ
                await cleanupStaleTask(sessionId: sessionId)
                
                // 新しいタスクで再開
                do {
                    try await processNextChunk(session: session)
                    AppLog.upload.notice("✅ [RECOVERY] セッション \(sessionId) の自動復旧が完了")
                } catch {
                    AppLog.upload.notice("❌ [RECOVERY] セッション \(sessionId) の自動復旧に失敗: \(error)")
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
        withState {
            activeTaskIds.removeValue(forKey: sessionId)
            taskStartTimes.removeValue(forKey: sessionId)
            currentUploads.removeValue(forKey: sessionId)
            uploadQueues[sessionId]?.setProcessing(false)
        }
        AppLog.upload.notice("🧹 [CLEANUP] セッション \(sessionId) の失効タスクをクリーンアップ完了")
    }
    
    /// タスクの進捗を確認
    private func verifyTaskProgress(taskId: Int, sessionId: String, chunkIndex: Int) async {
        AppLog.upload.notice("🔍 [TASK VERIFY] TaskID(\(taskId)) の進捗を確認中...")
        
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
            AppLog.upload.notice("🔍 [TASK VERIFY] TaskID(\(taskId)) 状態: \(task.state.description)")
            AppLog.upload.notice("🔍 [TASK VERIFY] TaskID(\(taskId)) 送信バイト: \(task.countOfBytesSent)/\(task.countOfBytesExpectedToSend)")
            
            // タスクが停止している場合の該断
            if task.state == .suspended {
                AppLog.upload.notice("⚠️ [TASK VERIFY] TaskID(\(taskId)) が一時停止状態 - 再開を試行")
                task.resume()
            } else if task.state == .canceling || task.state == .completed {
                AppLog.upload.notice("⚠️ [TASK VERIFY] TaskID(\(taskId)) が異常状態 (\(task.state.description)) - 即座復旧が必要")
                
                // 即座復旧を実行
                await cleanupStaleTask(sessionId: sessionId)
                
                if let session = activeUploadSessions[sessionId] {
                    do {
                        try await processNextChunk(session: session)
                        AppLog.upload.notice("✅ [TASK VERIFY] 即座復旧が完了: \(sessionId)")
                    } catch {
                        AppLog.upload.notice("❌ [TASK VERIFY] 即座復旧に失敗: \(sessionId) - \(error)")
                    }
                }
            } else {
                AppLog.upload.notice("✅ [TASK VERIFY] TaskID(\(taskId)) は正常状態 (\(task.state.description))")
            }
        } else {
            AppLog.upload.notice("❌ [TASK VERIFY] TaskID(\(taskId)) が見つかりません - タスクが失効した可能性")
            
            // タスクが見つからない場合は即座復旧
            await cleanupStaleTask(sessionId: sessionId)
            
            if let session = activeUploadSessions[sessionId] {
                do {
                    try await processNextChunk(session: session)
                    AppLog.upload.notice("✅ [TASK VERIFY] 納失タスクの即座復旧が完了: \(sessionId)")
                } catch {
                    AppLog.upload.notice("❌ [TASK VERIFY] 納失タスクの復旧に失敗: \(sessionId) - \(error)")
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
            AppLog.upload.notice("⚠️ [CANCEL ERROR] キャンセルエラーは再試行しない: \(nsError.localizedDescription)")
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
            AppLog.upload.notice("🔄 [NETWORK ERROR] 穏やかな再試行対象エラー: \(nsError.localizedDescription) (Code: \(nsError.code))")
        } else {
            AppLog.upload.notice("❌ [NETWORK ERROR] 再試行対象外エラー: \(nsError.localizedDescription) (Code: \(nsError.code))")
        }
        
        return shouldRetry
    }
}

// MARK: - Native Retry Scheduling (v2)

extension NetworkService {

    /// リトライスケジュールの本体。既存の Task.sleep パスから移行した OS 所有スケジューリング。
    /// - 契約: 呼び出し可能なコンテキストは URLSession delegate queue または任意の Task。
    ///        state 更新 (retry state + activeTaskIds + persist) → resume() の順序を単一の
    ///        withState ブロックで確定させることでレースを防ぐ。
    func scheduleChunkRetry(
        sessionId: String,
        chunkIndex: Int,
        decision: RetryDecision
    ) {
        // Phase A: 短いロック内で状態決定と retry 状態の記録のみ
        struct ScheduleContext {
            let session: UploadSession
            let target: Date
        }
        var ctx: ScheduleContext?
        withState {
            guard let session = activeUploadSessions[sessionId] else {
                AppLog.retry.error("scheduleChunkRetry: session \(sessionId) が見つかりません")
                return
            }
            let attempt = (session.chunkRetryCounts[chunkIndex] ?? 0) + 1
            let delay: TimeInterval?
            switch decision {
            case .retryAfter(let hint):
                delay = min(max(0, hint), RetryPolicy.maxRetryAfterCap)
            case .retry:
                delay = RetryPolicy.default.delay(forAttempt: attempt)
            case .fail:
                delay = nil
            }
            guard let d = delay else {
                onMaxRetriesExhaustedLocked(session: session, chunkIndex: chunkIndex)
                return
            }
            session.chunkRetryCounts[chunkIndex] = attempt
            let target = Date().addingTimeInterval(d)
            session.chunkNextRetryAt[chunkIndex] = target
            AppLog.retry.notice("🔄 [SCHEDULE] session=\(sessionId) chunk=\(chunkIndex) attempt=\(attempt) delay=\(String(format: "%.2f", d))s target=\(target)")
            ctx = ScheduleContext(session: session, target: target)
        }

        guard let ctx else { return }

        // Phase B: ロック外で重い I/O (chunk 読み込み + temp file 書き込み + uploadTask 作成)
        let task: URLSessionUploadTask
        do {
            task = try buildUploadTask(
                session: ctx.session,
                chunkIndex: chunkIndex,
                earliestBeginDate: ctx.target
            )
        } catch {
            AppLog.retry.error("makeUploadTask 失敗: \(error.localizedDescription)")
            withState {
                onMaxRetriesExhaustedLocked(session: ctx.session, chunkIndex: chunkIndex)
            }
            return
        }

        // Phase C: 再度ロックを取り、taskId 登録
        withState {
            activeTaskIds[ctx.session.id] = task.taskIdentifier
            taskStartTimes[ctx.session.id] = Date()
            uploadQueues[ctx.session.id]?.setProcessing(true)
        }
        // Phase C.5: 同期永続化はロック外で (disk I/O をロック内から追い出す)
        UploadManager.shared.saveActiveStateSync()

        // Phase D: ロック外で resume() — delegate の再入とロック競合を防ぐ
        task.resume()
    }

    /// withState 内から呼ばれる。上限到達時の状態遷移を単一化。
    /// 同期永続化と error 通知は呼び出し側 (withState 外) で行う。
    private func onMaxRetriesExhaustedLocked(session: UploadSession, chunkIndex: Int) {
        AppLog.retry.error("❌ [MAX RETRIES] session=\(session.id) chunk=\(chunkIndex) 上限到達 → .error 遷移")
        session.chunkRetryCounts.removeValue(forKey: chunkIndex)
        session.chunkNextRetryAt.removeValue(forKey: chunkIndex)
        session.updateStatus(.error)
        cleanupTemporaryFile(sessionId: session.id, chunkIndex: chunkIndex)
        // 永続化と通知はロック外で行う (disk I/O をロック内に閉じ込めない)。
        let sessionId = session.id
        Task {
            UploadManager.shared.saveActiveStateSync()
            await UploadManager.shared.notifyUploadError(
                sessionId: sessionId,
                error: NetworkError.fileError("チャンク\(chunkIndex)アップロード失敗: リトライ上限到達")
            )
        }
    }

    /// happy-path 永続化。initial/complete は無条件、それ以外はデバウンス。
    /// テストからも呼べるよう internal スコープ。
    func persistHappyPath(sessionId: String, session: UploadSession) {
        let count = session.uploadedChunks.count
        let isFirst = count == 1
        let isComplete = session.isComplete
        var shouldPersist = isFirst || isComplete
        if !shouldPersist {
            let last = withState { lastPersistAt[sessionId] }
            if let last {
                shouldPersist = Date().timeIntervalSince(last) >= happyPathPersistInterval
            } else {
                shouldPersist = true
            }
        }
        guard shouldPersist else { return }
        withState { lastPersistAt[sessionId] = Date() }
        UploadManager.shared.saveActiveStateSync()
    }

    /// 新規 URLSessionUploadTask を作成し、earliestBeginDate を設定する。
    /// ロック非保持で呼べる (任意のコンテキストから安全)。retry 経路以外では
    /// earliestBeginDate=nil で通常アップロード。
    func makeUploadTask(
        session: UploadSession,
        chunkIndex: Int,
        earliestBeginDate: Date? = nil
    ) throws -> URLSessionUploadTask {
        return try buildUploadTask(
            session: session,
            chunkIndex: chunkIndex,
            earliestBeginDate: earliestBeginDate
        )
    }

    /// tempURL 作成 + URLRequest + uploadTask + earliestBeginDate。
    /// **ロックを取得/要求しない**: withState 内・外どちらから呼んでも安全。
    /// 命名は「lock ownership を暗示しない」ように buildUploadTask とする。
    private func buildUploadTask(
        session: UploadSession,
        chunkIndex: Int,
        earliestBeginDate: Date?
    ) throws -> URLSessionUploadTask {
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
            url: APIEndpoint.uploadChunk(sessionId: session.id, chunkIndex: chunkIndex).url
        )
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "X-Chunk-Checksum")

        let task = backgroundSession.uploadTask(with: request, fromFile: tempURL)
        if let ebd = earliestBeginDate {
            task.earliestBeginDate = ebd
        }
        return task
    }

    /// deleteSession から呼ばれる、OS 所有の live タスクを cancel する。
    func cancelOSTasks(sessionId: String) async {
        let tasks = await backgroundSession.allTasks
        for task in tasks {
            if let url = task.originalRequest?.url,
               Self.extractSessionId(from: url) == sessionId {
                AppLog.retry.notice("🗑️ cancelOSTasks: cancel task \(task.taskIdentifier) for session \(sessionId)")
                task.cancel()
            }
        }
    }

    /// URL から sessionId を抽出。テスト可能な pure な関数。
    /// URL 形式: .../upload/session/{sessionId}/chunk/{chunkIndex}
    static func extractSessionId(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: "session"),
              idx + 1 < parts.count else { return nil }
        return parts[idx + 1]
    }

    /// URL から (sessionId, chunkIndex) を抽出。reconcile 用。
    static func extractSessionChunkKey(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let sIdx = parts.firstIndex(of: "session"),
              sIdx + 3 < parts.count,
              parts[sIdx + 2] == "chunk",
              let chunk = Int(parts[sIdx + 3]) else { return nil }
        return "\(parts[sIdx + 1]):\(chunk)"
    }

    /// app 起動時に OS 所有タスクを reconcile する。
    /// - Returns: OS 側で live なタスクの (sessionId, chunkIndex) セット
    /// 起動時に OS 所有タスクを reconcile したうえで、activeUploads の各セッションを
    /// サーバの `GET /status` と突き合わせて 3 経路に振り分ける:
    /// - 404: サーバ側に存在しない → `UploadManager.discardSession(reason:"server-404")`
    /// - missingChunks 空: サーバ側で全チャンク到達済 → `completeUpload(session:)` で history 移動
    /// - missingChunks あり + OS 側にタスク無し: `resumeSessionFromServer(session)` で再投入
    /// - missingChunks あり + OS 側にタスク有り: OS が既に送信中 → 何もしない
    func reconcileWithServer() async {
        let liveKeys = await reconcileOSOwnedTasks()
        let liveSessionIds: Set<String> = Set(liveKeys.compactMap {
            $0.split(separator: ":").first.map(String.init)
        })
        let sessions = await MainActor.run { Array(UploadManager.shared.activeUploads.values) }
        AppLog.upload.notice("🔁 [RECONCILE:SERVER] 対象セッション \(sessions.count) 件")
        for session in sessions {
            do {
                let status = try await getSessionStatus(sessionId: session.id)
                if status.missingChunks.isEmpty {
                    AppLog.upload.notice("✅ [RECONCILE] session=\(session.id) はサーバ側完了 → completeUpload")
                    NetworkService.syncUploadedChunks(
                        session: session,
                        missingChunks: [],
                        totalChunks: session.totalChunks
                    )
                    try? await completeUpload(session: session)
                } else if liveSessionIds.contains(session.id) {
                    AppLog.upload.notice("🔁 [RECONCILE] session=\(session.id) は OS 側で送信中 → 待機")
                } else {
                    AppLog.upload.notice("🔁 [RECONCILE] session=\(session.id) 残 \(status.missingChunks.count) チャンク → resume")
                    try? await resumeSessionFromServer(session)
                }
            } catch let NetworkError.httpError(code, _) where code == 404 {
                AppLog.upload.notice("🗑 [RECONCILE] session=\(session.id) はサーバ 404 → discard")
                // discard 前に OS 側の live task も片付ける。片付けを怠ると、
                // discard 後に delegate が「不明セッションの chunk 完了」を受けて誤動作する。
                await cancelOSTasks(sessionId: session.id)
                await MainActor.run {
                    UploadManager.shared.discardSession(sessionId: session.id, reason: "server-404")
                }
            } catch {
                AppLog.upload.error("⚠️ [RECONCILE] session=\(session.id) status 取得失敗 (\(error.localizedDescription)) → 次回起動時に再試行")
            }
        }
    }

    func reconcileOSOwnedTasks() async -> Set<String> {
        let tasks = await backgroundSession.allTasks
        var live: Set<String> = []
        for task in tasks {
            guard let url = task.originalRequest?.url,
                  let key = Self.extractSessionChunkKey(from: url) else { continue }
            live.insert(key)
            // クライアント側 activeTaskIds を再登録
            let parts = key.split(separator: ":")
            if let sid = parts.first.map(String.init) {
                withState {
                    activeTaskIds[sid] = task.taskIdentifier
                    uploadQueues[sid]?.setProcessing(true)
                }
            }
        }
        AppLog.retry.notice("🔁 [RECONCILE] OS 所有タスク \(live.count) 件を復元")
        return live
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
