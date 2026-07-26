import Foundation
import UIKit

class NetworkService: NSObject, ObservableObject {
    static let shared = NetworkService()

    // MARK: - Properties

    private var backgroundSession: URLSession!
    private var controlSession: URLSession!

    @Published var activeUploadSessions: [String: UploadSession] = [:]
    
    /// BackgroundURLSession の identifier。completion handler の対応付けにも使う。
    static let backgroundSessionIdentifier = "com.largefileupload.background"


    // 逐次処理用キュー管理
    private var uploadQueues: [String: UploadQueue] = [:]
    private var currentUploads: [String: String] = [:]
    
    // タスク監視用プロパティ
    private var activeTaskIds: [String: Int] = [:]  // sessionId -> taskIdentifier
    private var taskStartTimes: [String: Date] = [:]  // sessionId -> 開始時刻

    // アプリ状態管理（重要：MainActor使用を制御）
    private var isAppInBackground = false

    /// happy-path 永続化のデバウンス管理。sessionId -> 最終 save 時刻。
    /// initial(uploadedChunks==1) と complete は無条件で save、それ以外は
    /// happyPathPersistInterval を超えた場合のみ save して I/O を抑制する。
    private var lastPersistAt: [String: Date] = [:]
    private let happyPathPersistInterval: TimeInterval = 2.0

    /// resumeSessionFromServer が「古い OS タスクの掃除」目的で cancel した taskIdentifier の集合。
    /// delegate 側でここに載っている taskIdentifier の cancel エラーは benign 扱いして
    /// notifyUploadError を発火させない。pause 経由の cancel (session.status == .paused) と同じ扱い。
    private var taskIdsPendingResumeCancel: Set<Int> = []

    /// 上記のすべての可変辞書 (activeTaskIds/taskStartTimes/currentUploads/uploadQueues/
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
        NotificationCenter.default.removeObserver(self)
        AppLog.upload.notice("🧹 [DEINIT] NetworkService リソースをクリーンアップ")
    }

    private func setupURLSessions() {
        let controlConfig = URLSessionConfiguration.default
        controlConfig.timeoutIntervalForRequest = 30
        controlConfig.timeoutIntervalForResource = 60
        controlSession = URLSession(configuration: controlConfig)

        let backgroundConfig = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        // 大容量転送: リソース全体タイムアウトは明示的に7日
        backgroundConfig.timeoutIntervalForResource = 60 * 60 * 24 * 7
        // リクエスト単体タイムアウト: 従量制/低速回線を考慮して5分
        backgroundConfig.timeoutIntervalForRequest = 300
        // ホストあたりの同時接続数の上限。同時に開く TCP 接続を抑えて回線を占有しないためのもので、
        // タスクの実行順序や同時実行数を保証する設定ではない。HTTP/2 では 1 本の接続上で
        // 複数のリクエストが多重化されるため、厳密な逐次送信の根拠にはできない。
        // チャンクは互いに独立で冪等なので、順序が前後しても結果は変わらない設計にしている。
        backgroundConfig.httpMaximumConnectionsPerHost = 1
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
        AppLog.upload.notice("🌙 バックグラウンド移行 - MainActor使用停止、OS 所有タスクが転送を継続")
    }

    @objc private func appWillEnterForeground() {
        isAppInBackground = false
        // 復帰時のサーバ突き合わせは UploadManager 側の reconcileWithServer に一本化する。
        // ここでも独自に再開処理を走らせると、同じセッションに対して二重に投入が走る。
        AppLog.upload.notice("☀️ フォアグラウンド復帰 - UI更新再開")
    }

    /// BackgroundURLSession を確実に生成して delegate を再関連付けする。
    /// `handleEventsForBackgroundURLSession` から completion handler の登録後に呼ぶ。
    /// init で既に生成しているので、ここでは singleton の生存を確かめるだけでよい。
    func activateBackgroundSession() {
        AppLog.upload.notice("🔗 [BG SESSION] identifier=\(Self.backgroundSessionIdentifier) を再関連付け")
    }

    // MARK: - Session Management

    func createUploadSession(fileURL: URL) async throws -> UploadSession {
        AppLog.upload.notice("📝 セッション作成開始")
        
        let fileInfo = try FileManager.shared.getFileInfo(url: fileURL)
        // 送信を始める前に容量を判断する。投入の途中で書き込みに失敗すると、
        // サーバ側にセッションだけ残った中途半端な状態になる。
        try FileManager.shared.ensureSufficientFreeSpace(forFileSize: fileInfo.size)
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
        // 読み込みが黙って失敗して PUT が飛ばなかった (=「再開が効かない」バグの真因)。
        // そこでソースをアプリ所有の Documents/uploads/<sessionId>/ にチャンク単位で
        // 書き出してから UploadSession に持たせる。以降そのチャンクはいつでも読める。
        // 全体コピーを別に持たないので、ローカル消費はファイルサイズ1つ分に収まる。
        //
        // ステージング失敗時はサーバ側にだけセッションが残る「孤立セッション」を防ぐため、
        // ここで明示的に DELETE してから元のエラーを再送する。
        //
        // 順序に注意する。ステージングは数GBだと時間がかかるので、その最中に
        // 強制終了されるとサーバにセッションだけが残る。そこでステージング先の
        // パスはセッションIDから決まることを利用して、先にセッションを組み立てて
        // 手元に同期的に記録し、そのあとで書き出す。こうしておけば、途中で終了しても
        // 次回起動時の突き合わせがそのセッションを見つけられる。
        let stagedURL = try FileManager.shared.stagingDirectory(for: response.sessionId)

        let session = UploadSession(
            id: response.sessionId,
            fileName: fileInfo.name,
            fileURL: stagedURL,
            totalChunks: chunkInfo.totalChunks,
            fileSize: fileInfo.size,
            fileChecksum: fileChecksum,
            chunkSize: chunkInfo.chunkSize
        )
        do {
            try await UploadManager.shared.registerNewSession(session)
        } catch {
            AppLog.upload.error("⚠️ [ROLLBACK] セッションの記録に失敗 → サーバ側セッション削除: \(response.sessionId)")
            _ = try? await performControlRequest(
                endpoint: .deleteSession(sessionId: response.sessionId),
                method: "DELETE",
                responseType: EmptyResponse.self
            )
            throw error
        }

        do {
            _ = try FileManager.shared.stageChunksForUpload(
                sourceURL: fileURL,
                sessionId: response.sessionId,
                chunkSize: chunkInfo.chunkSize,
                totalChunks: chunkInfo.totalChunks
            )
        } catch {
            AppLog.upload.error("⚠️ [ROLLBACK] stageChunksForUpload 失敗 → サーバ側セッション削除: \(response.sessionId)")
            _ = try? await performControlRequest(
                endpoint: .deleteSession(sessionId: response.sessionId),
                method: "DELETE",
                responseType: EmptyResponse.self
            )
            await MainActor.run {
                UploadManager.shared.discardSession(sessionId: response.sessionId, reason: "staging-failed")
            }
            throw error
        }

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
        AppLog.upload.notice("📤 チャンクアップロード開始 (全タスク一括投入)")

        guard let queue = uploadQueues[session.id] else {
            throw NetworkError.sessionNotFound
        }

        // check-and-set を単一 withState で原子化する。ロック外の read だと
        // 並行呼び出し (resume + didComplete 安全網など) が両方 false を見て
        // 二重に投入ループへ入る TOCTOU になる。
        let shouldEnqueue = withState {
            guard !queue.isCurrentlyProcessing else { return false }
            queue.setProcessing(true)
            return true
        }
        if shouldEnqueue {
            try enqueueAllPendingChunks(session: session)
        }
    }

    /// バックグラウンド継続の要: pending チャンクの uploadTask を全件一括で
    /// BackgroundURLSession に投入する。
    ///
    /// 従来の「didCompleteWithError で次の 1 個を積む」逐次投入は、アプリが
    /// サスペンドされると次タスクを積む主体がいなくなり、投入済みの 1 タスクを
    /// 送り切った時点で送信が止まる (nsurlsessiond は投入済みタスクしか送らない。
    /// delegate 起床は OS が遅延させるため、事実上フォアグラウンド復帰まで停止)。
    /// 実機observed: バックグラウンド中のチャンク到達 0 件 → 復帰の status GET と
    /// 同時に再開 (2026-07-12 サーバログ)。
    ///
    /// 全タスクを先に投入しておけば、nsurlsessiond がサスペンド中も送信を続ける。
    /// httpMaximumConnectionsPerHost=1 は同時接続数を抑えるだけで送信順序は保証しないが、
    /// チャンクは互いに独立で冪等なので順序が前後しても結果は変わらない。
    /// ladder: temp chunk file が全 pending 分同時に存在する (ピークでファイル
    /// サイズ相当の追加ディスク)。問題になったら投入ウィンドウ制に格上げする。
    private func enqueueAllPendingChunks(session: UploadSession) throws {
        guard let queue = uploadQueues[session.id] else {
            throw NetworkError.sessionNotFound
        }
        var enqueued = 0
        var prepError: Error?
        while let chunkIndex = withState({ queue.getNextChunk() }) {
            do {
                // 永続化した再送予定が未来なら、その時刻を引き継ぐ。ここを nil で積むと、
                // Retry-After の待機中に強制終了された場合、再起動直後に指定を破って再送する。
                let scheduled = session.chunkNextRetryAt[chunkIndex]
                let earliestBeginDate = (scheduled.map { $0 > Date() } ?? false) ? scheduled : nil
                let task = try buildUploadTask(
                    session: session,
                    chunkIndex: chunkIndex,
                    earliestBeginDate: earliestBeginDate
                )
                // 追跡辞書 (activeTaskIds/taskStartTimes/currentUploads) はセッション
                // ごとに 1 エントリなので、一括投入では「最後に投入したタスク」だけを
                // 保持する。投入後のタスクは OS 所有なので、クライアント側の追跡は
                // ベストエフォートでよい。取りこぼしは起動時とネットワーク復旧時の
                // サーバ同期で回収する設計とする。
                withState {
                    activeTaskIds[session.id] = task.taskIdentifier
                    taskStartTimes[session.id] = Date()
                    currentUploads[session.id] = "\(session.id)_\(chunkIndex)"
                    queue.setProcessing(true)
                }
                task.resume()
                enqueued += 1
            } catch {
                // 準備失敗 (disk hiccup 等) は retry を 1 件だけスケジュールして
                // 投入を打ち切る。全チャンク分のカスケードを一斉発火させると
                // notifyUploadError / 永続化が N 並列で走る thundering herd になる。
                // 残りは queue に残り、retry 成功後の didComplete 安全網が続きを投入する。
                AppLog.upload.error("❌ チャンク \(chunkIndex) 一括投入準備失敗、投入打ち切り: \(error.localizedDescription)")
                prepError = error
                scheduleChunkRetry(sessionId: session.id, chunkIndex: chunkIndex, decision: .retry)
                break
            }
        }
        AppLog.upload.notice("📤 [ENQUEUE ALL] session=\(session.id) \(enqueued) チャンクを一括投入 (バックグラウンド継続対応)")
        if enqueued == 0 {
            // 1 件も投入できなかった場合は processing フラグを必ず戻す。
            // 呼び出し元 (startSequentialChunkUpload) が check-and-set で true に
            // している経路や、初回チャンクの prep 失敗経路で true のまま残ると、
            // in-flight タスクが無いのに以後の投入が isCurrentlyProcessing ガードで
            // 恒久的にブロックされる。
            withState { queue.setProcessing(false) }
            if let prepError {
                throw prepError
            }
        }
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
                withState { _ = taskIdsPendingResumeCancel.insert(task.taskIdentifier) }
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

        // サーバ側完了なら completeUpload、まだなら missing 全チャンクを一括投入
        if status.missingChunks.isEmpty {
            try await completeUpload(session: session)
        } else {
            try enqueueAllPendingChunks(session: session)
        }
    }

    /// サーバが返す RFC3339 形式の時刻を Date にする。小数秒の有無どちらも受ける。
    static func parseServerDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
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
            _ = activeUploadSessions.removeValue(forKey: sessionId)
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

        AppLog.upload.notice("✅ セッション削除完了: \(sessionId)")
    }

    /// 送信中のどのセッションにも属さないステージングを削除する。
    /// 強制終了や破棄で取り残されたチャンク群がローカル容量を占め続けるのを防ぐ。
    /// BGProcessingTask から定期的に呼ぶ後始末。
    func cleanupOrphanedStagedSessions() {
        let liveSessionIds = withState { Set(activeUploadSessions.keys) }
        FileManager.shared.cleanupOrphanedStagingDirectories(activeSessionIds: liveSessionIds)
    }

    private func refreshAllSessionStatusSafely() async {
        for (sessionId, session) in activeUploadSessions {
            do {
                let status = try await getSessionStatus(sessionId: sessionId)
                session.serverExpiresAt = NetworkService.parseServerDate(status.expiresAt)

                // サーバが完了と言っているならそれを真として取り込む。
                // 結合はサーバ側で自動的に走るため、アプリが POST /complete を
                // 呼べないままバックグラウンドで眠っていた場合の回収経路がここになる。
                if status.status == UploadStatus.completed.rawValue {
                    NetworkService.syncUploadedChunks(
                        session: session,
                        missingChunks: status.missingChunks,
                        totalChunks: status.totalChunks
                    )
                    adoptServerCompletion(session: session)
                    continue
                }

                // サーバの error でも、やり直しで回復し得る失敗と恒久的な失敗は分けて扱う。
                // 一時的な I/O 失敗まで終端にすると、再確認すれば済む状況から戻れなくなる。
                if status.status == UploadStatus.error.rawValue {
                    if status.finalizeFatal == true {
                        adoptServerFailure(
                            session: session,
                            message: status.finalizeError ?? "サーバ側でアップロードが失敗しました"
                        )
                    } else {
                        AppLog.upload.notice("🔁 session=\(sessionId) はサーバ側で一時的に失敗 → 完了確認を再試行")
                        try? await completeUpload(session: session)
                    }
                    continue
                }

                // 完全に安全な状態更新
                updateSessionStateSafely {
                    session.uploadedChunks = Set(0..<status.totalChunks)
                        .subtracting(Set(status.missingChunks))
                    session.updateProgress()

                    if session.status != .completed && session.status != .completing {
                        // combining はサーバが結合を実行している最中。送信は終わっているので
                        // ユーザーには「完了処理中」として見せる。
                        if status.status == "combining" {
                            session.updateStatus(.completing)
                        } else if status.status == "ready" && session.status == .uploading {
                            session.updateStatus(.ready)
                        }
                    }
                }
            } catch {
                AppLog.upload.notice("セッション \(sessionId) のステータス更新に失敗: \(error)")
            }
        }
    }

    // MARK: - Upload Completion

    /// 結合結果を確認する冪等な問い合わせ。
    ///
    /// 結合そのものは最終チャンクが届いた時点でサーバ側が自動的に始めている。
    /// この POST は「終わったか」を尋ねるだけなので、アプリがバックグラウンドで
    /// サスペンドされていて呼べなくても、ファイルはサーバ側で確定する。
    /// まだ結合中なら status は "combining" のまま返るため、その場合は .completing で待つ。
    /// 完了の取り込みは refreshAllSessionStatus / reconcileWithServer 側が拾う。
    func completeUpload(session: UploadSession) async throws {
        AppLog.upload.notice("🏁 アップロード完了確認開始: \(session.id)")

        updateSessionSafely(session) { session in
            session.updateStatus(.completing)
        }

        let response: CompleteResponse
        do {
            response = try await performControlRequest(
                endpoint: .completeUpload(sessionId: session.id),
                method: "POST",
                responseType: CompleteResponse.self
            )
        } catch let NetworkError.httpError(code, message) where (400..<500).contains(code) {
            // 整合性チェック失敗 (422) などの恒久的な失敗。ここで終端に落とさないと
            // .completing のまま完了も失敗もせず、確認を繰り返すだけの状態で止まる。
            AppLog.upload.error("❌ 完了確認が恒久的に失敗 (HTTP \(code)): \(message)")
            adoptServerFailure(session: session, message: message)
            throw NetworkError.httpError(code, message)
        }

        guard response.status == UploadStatus.completed.rawValue else {
            AppLog.upload.notice("⏳ サーバ側は結合中 (status=\(response.status)): \(session.id)")
            // ここで戻るだけだと .completing のまま次の偶発的な突き合わせを待つことになる。
            // 結合が終わるまでの確認を自分で予約しておく。
            scheduleCombiningFollowUp(session: session)
            return
        }

        adoptServerCompletion(session: session)
        AppLog.upload.notice("✅ アップロード完了: \(response.filePath)")
    }

    /// 結合中のセッションについて、終端に達するまで状態を確認し続ける。
    /// フォアグラウンドで動いている間の取りこぼしを防ぐための上限付きポーリング。
    /// アプリが眠ってこれが止まっても、起動時と BGProcessingTask の突き合わせが拾い直す。
    private func scheduleCombiningFollowUp(session: UploadSession) {
        let sessionId = session.id
        Task {
            let deadline = Date().addingTimeInterval(combiningFollowUpTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let status = try? await getSessionStatus(sessionId: sessionId) else { continue }

                if status.status == UploadStatus.completed.rawValue {
                    NetworkService.syncUploadedChunks(
                        session: session,
                        missingChunks: status.missingChunks,
                        totalChunks: status.totalChunks
                    )
                    adoptServerCompletion(session: session)
                    return
                }
                if status.status == UploadStatus.error.rawValue && status.finalizeFatal == true {
                    adoptServerFailure(
                        session: session,
                        message: status.finalizeError ?? "サーバ側でアップロードが失敗しました"
                    )
                    return
                }
            }
            AppLog.upload.notice("⏳ [FOLLOW UP] session=\(sessionId) の結合確認を打ち切り。次の突き合わせに委ねる")
        }
    }

    /// 結合完了を追いかける上限。これを超えたら起動時や BGProcessingTask の突き合わせに任せる。
    private var combiningFollowUpTimeout: TimeInterval { 300 }

    /// サーバが恒久的な失敗と言っている状態を取り込む。
    /// 送信済みチャンクは手元に残したまま終端の .error に落とし、利用者に見せる。
    func adoptServerFailure(session: UploadSession, message: String) {
        guard session.status != .error && session.status != .completed else { return }

        updateSessionSafely(session) { session in
            session.autoResumeBlocked = true
            session.setError(message)
        }
        withState {
            uploadQueues.removeValue(forKey: session.id)
            currentUploads.removeValue(forKey: session.id)
            activeTaskIds.removeValue(forKey: session.id)
            taskStartTimes.removeValue(forKey: session.id)
        }
        let sessionId = session.id
        Task {
            await UploadManager.shared.notifyUploadError(
                sessionId: sessionId,
                error: NetworkError.fileError(message)
            )
        }
    }

    /// サーバが完了と言っている状態をクライアントに取り込む。
    /// POST /complete の応答からでも GET /status のポーリングからでも同じ経路を通す。
    /// 二度呼ばれても害が無いように、完了済みなら何もしない。
    func adoptServerCompletion(session: UploadSession) {
        guard session.status != .completed else { return }

        updateSessionSafely(session) { session in
            session.updateStatus(.completed)
        }

        withState {
            uploadQueues.removeValue(forKey: session.id)
            currentUploads.removeValue(forKey: session.id)
            activeTaskIds.removeValue(forKey: session.id)
            taskStartTimes.removeValue(forKey: session.id)
        }

        // 順序が重要。完了を履歴として保存し終えてから再送材料を消す。
        // 先に消すと、保存前に強制終了された場合に「送信中のまま復元されるのに
        // 送るチャンクが無い」状態になり、そのセッションは復旧できない。
        UploadManager.shared.notifyUploadCompletion(sessionId: session.id)
    }

    /// 完了が履歴として保存された後に呼ばれ、再送材料を片付ける。
    func cleanupAfterPersistedCompletion(session: UploadSession) {
        FileManager.shared.cleanupStagedFile(sessionId: session.id, fileURL: session.fileURL)
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
        let identifier = session.configuration.identifier ?? Self.backgroundSessionIdentifier
        AppLog.upload.notice("🔔 BackgroundURLSession - 全タスク完了: \(identifier)")

        // 登録済みなら即座に、未登録なら登録された時点でレジストリが呼び戻す。
        // ここで nil を見て黙って捨てると、OS へ返す completion handler が呼ばれないまま残る。
        BackgroundSessionCompletionRegistry.shared.finish(identifier: identifier)
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
                // 401 や 413 のような恒久的な拒否は、投げ直しても同じ結果になる。
                // 自動再開を止めないと、起動やフォアグラウンド復帰のたびに同じ PUT を繰り返す。
                if let statusCode = httpResp?.statusCode, (400..<500).contains(statusCode) {
                    withState { uploadSession.autoResumeBlocked = true }
                    UploadManager.shared.saveActiveStateSync()
                }
                Task {
                    await UploadManager.shared.notifyUploadError(
                        sessionId: sessionId,
                        error: notifiedError
                    )
                }
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
        // 送れたチャンクの再送予定は不要。残しておくと次回起動時に余計な待機が入る。
        withState {
            session.chunkRetryCounts.removeValue(forKey: chunkIndex)
            session.chunkNextRetryAt.removeValue(forKey: chunkIndex)
        }

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
            // 全チャンクは startUpload/resume 時点で一括投入済み。ここは
            // 「一括投入が途中で失敗して queue に残った」場合のみ動く安全網
            // (queue が空なら enqueueAllPendingChunks は no-op)。
            let capturedSessionId = sessionId
            Task {
                do {
                    // sessionIdからセッションを安全に取得
                    if let session = self.activeUploadSessions[capturedSessionId] {
                        try self.enqueueAllPendingChunks(session: session)
                    }
                } catch {
                    AppLog.upload.notice("❌ 残チャンク投入エラー: \(error)")
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
    
    /// ネットワーク切り替え時の処理。
    ///
    /// やるのは「OS 側のタスク一覧と手元の状態を突き合わせ、止まっていたら積み直す」だけです。
    /// 待ってから確認する作りにはしません。Task.sleep による待機はアプリがサスペンドされた
    /// 瞬間に消えるため、切り替え直後にバックグラウンドへ回ると確認そのものが起きなくなります。
    private func handleNetworkTransition(
        from previousType: NetworkMonitor.ConnectionType,
        to currentType: NetworkMonitor.ConnectionType
    ) async {
        AppLog.upload.notice("🔄 [NETWORK TRANSITION] \(previousType.displayName) → \(currentType.displayName)")
        await recoverStalledSessions(reason: "ネットワーク切り替え")
    }

    /// 接続復旧時の処理
    private func handleConnectionRecovery() async {
        AppLog.upload.notice("📶 [CONNECTION RECOVERY] 接続復旧を検出")
        await recoverStalledSessions(reason: "接続復旧")
    }

    /// OS 側に生きているタスクが1本も無い送信中セッションを見つけて、残チャンクを積み直す。
    ///
    /// 復旧は必ず「残チャンクの全件一括投入」で行う。1 個ずつ積み直す方式に戻すと、
    /// 復旧直後にアプリがサスペンドされた時点でその 1 個を送り切って転送が止まる。
    /// 送信中のタスクはキャンセルしない。OS が既に送っているものを止める理由が無い。
    /// 何が未送信かは手元の記録ではなくサーバに聞く。手元だけで判断すると、既に届いている
    /// チャンクを送り直すことになる。
    private func recoverStalledSessions(reason: String) async {
        let liveKeys = await liveTaskKeys()
        let sessions = withState { activeUploadSessions }

        for (sessionId, session) in sessions {
            guard session.status == .uploading else { continue }

            let liveChunks = NetworkService.liveChunkIndices(for: sessionId, in: liveKeys)
            if !liveChunks.isEmpty {
                AppLog.upload.notice("✅ [RECOVER/\(reason)] session=\(sessionId) は OS 側で \(liveChunks.count) 件送信中 → 介入しない")
                continue
            }

            do {
                let status = try await getSessionStatus(sessionId: sessionId)
                if status.missingChunks.isEmpty {
                    AppLog.upload.notice("✅ [RECOVER/\(reason)] session=\(sessionId) は全チャンク到達済み → 結合結果を確認")
                    NetworkService.syncUploadedChunks(
                        session: session,
                        missingChunks: [],
                        totalChunks: session.totalChunks
                    )
                    try await completeUpload(session: session)
                    continue
                }

                AppLog.upload.notice("🔄 [RECOVER/\(reason)] session=\(sessionId) 残 \(status.missingChunks.count) チャンクを一括投入")
                registerForDelegateCallbacks(
                    session: session,
                    status: status,
                    pendingChunks: status.missingChunks
                )
                try enqueueAllPendingChunks(session: session)
            } catch {
                // 投入や問い合わせに失敗しても、リトライ予定は OS 側に預けてあるので諦めてよい。
                // 次のフォアグラウンド復帰か BGProcessingTask の reconcile が拾い直す。
                AppLog.upload.notice("⚠️ [RECOVER/\(reason)] session=\(sessionId) の復旧に失敗: \(error.localizedDescription)")
            }
        }
    }

    /// OS 所有タスクの (sessionId:chunkIndex) キー集合を取る。
    private func liveTaskKeys() async -> Set<String> {
        let tasks = await backgroundSession.allTasks
        var keys: Set<String> = []
        for task in tasks {
            guard let url = task.originalRequest?.url,
                  let key = Self.extractSessionChunkKey(from: url) else { continue }
            keys.insert(key)
        }
        return keys
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
            // 試行回数の上限判定は decision の種類より先に置く。retryAfter だけ上限を見ない作りだと、
            // サーバが 429 と Retry-After を返し続ける限り再送が止まらず、通信量と電池を消費し続ける。
            let isWithinAttemptLimit = attempt <= RetryPolicy.default.maxAttempts
            let delay: TimeInterval?
            switch decision {
            case .retryAfter(let hint) where isWithinAttemptLimit && hint <= RetryPolicy.maxRetryAfterCap:
                // 指定された秒数をそのまま使う。短くすると Retry-After を尊重したことにならない。
                delay = max(0, hint)
            case .retry:
                delay = RetryPolicy.default.delay(forAttempt: attempt)
            case .retryAfter(let hint):
                // 自動で待てる範囲を超える指定。早く再送するのではなく自動リトライを止める。
                AppLog.retry.notice("⏹ [SCHEDULE] session=\(sessionId) chunk=\(chunkIndex) Retry-After=\(hint)s は自動リトライ上限を超過 → 打ち切り")
                delay = nil
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
        // Phase C.5: 再送予定を耐久化してから開始する。保存できないまま送り出すと、
        // 強制終了で回数と予定時刻が巻き戻り、上限を超えた再送や Retry-After より
        // 早い再送が起きる。保存できない場合は作ったタスクを取り消して手を止める。
        do {
            try UploadManager.shared.persistActiveState()
        } catch {
            AppLog.retry.error("❌ [SCHEDULE] 再送予定の保存に失敗 → タスクを取り消して停止: \(error.localizedDescription)")
            task.cancel()
            withState {
                ctx.session.autoResumeBlocked = true
                ctx.session.updateStatus(.error)
                uploadQueues[ctx.session.id]?.setProcessing(false)
            }
            let sessionId = ctx.session.id
            Task {
                await UploadManager.shared.notifyUploadError(
                    sessionId: sessionId,
                    error: NetworkError.fileError("再送予定を保存できませんでした")
                )
            }
            return
        }

        // Phase D: ロック外で resume() — delegate の再入とロック競合を防ぐ
        task.resume()
    }

    /// withState 内から呼ばれる。上限到達時の状態遷移を単一化。
    /// 同期永続化と error 通知は呼び出し側 (withState 外) で行う。
    private func onMaxRetriesExhaustedLocked(session: UploadSession, chunkIndex: Int) {
        AppLog.retry.error("❌ [MAX RETRIES] session=\(session.id) chunk=\(chunkIndex) 上限到達 → .error 遷移")
        // 回数は消さずに残す。消すと次の突き合わせで 1 から数え直しになり、上限が効かなくなる。
        session.chunkNextRetryAt.removeValue(forKey: chunkIndex)
        session.autoResumeBlocked = true
        session.updateStatus(.error)
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

    /// ステージング済みチャンクから URLRequest + uploadTask + earliestBeginDate を組み立てる。
    /// **ロックを取得/要求しない**: withState 内・外どちらから呼んでも安全。
    /// 命名は「lock ownership を暗示しない」ように buildUploadTask とする。
    private func buildUploadTask(
        session: UploadSession,
        chunkIndex: Int,
        earliestBeginDate: Date?
    ) throws -> URLSessionUploadTask {
        // ステージング済みチャンクをそのまま送る。送信用の一時コピーを別に作ると、
        // 未送信チャンク全件分が同時に存在してローカル容量を二重に消費する。
        let chunkURL = FileManager.shared.chunkFileURL(in: session.fileURL, chunkIndex: chunkIndex)
        guard Foundation.FileManager.default.fileExists(atPath: chunkURL.path) else {
            throw NetworkError.fileError("ステージング済みチャンクが見つかりません: \(chunkIndex)")
        }
        let checksum = FileManager.shared.calculateChecksum(data: try Data(contentsOf: chunkURL))

        var request = URLRequest(
            url: APIEndpoint.uploadChunk(sessionId: session.id, chunkIndex: chunkIndex).url
        )
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "X-Chunk-Checksum")

        let task = backgroundSession.uploadTask(with: request, fromFile: chunkURL)
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
        let sessions = await MainActor.run { Array(UploadManager.shared.activeUploads.values) }

        // OS タスクを調べる前に、復元済みセッションの受け皿を先に作る。
        // 順序を逆にすると、状態を問い合わせている最中に届いた完了通知が
        // 「知らないセッション」として捨てられ、進捗も次の投入も止まる。
        withState {
            for session in sessions where activeUploadSessions[session.id] == nil {
                activeUploadSessions[session.id] = session
                uploadQueues[session.id] = UploadQueue(sessionId: session.id, chunks: [])
            }
        }

        let liveKeys = await reconcileOSOwnedTasks()
        AppLog.upload.notice("🔁 [RECONCILE:SERVER] 対象セッション \(sessions.count) 件")
        for session in sessions {
            // ステージングが途中で終わっているセッションは送るデータが揃っていない。
            // サーバ側のセッションごと片付けないと、双方に半端な記録が残り続ける。
            if !FileManager.shared.isStagingComplete(session: session) {
                AppLog.upload.error("🗑 [RECONCILE] session=\(session.id) はステージング未完了 → 破棄")
                await cancelOSTasks(sessionId: session.id)
                _ = try? await performControlRequest(
                    endpoint: .deleteSession(sessionId: session.id),
                    method: "DELETE",
                    responseType: EmptyResponse.self
                )
                await MainActor.run {
                    UploadManager.shared.discardSession(sessionId: session.id, reason: "staging-incomplete")
                }
                continue
            }

            // ユーザーが自分で止めたセッションは自動で動かさない。
            // 突き合わせの対象にすると、フォアグラウンド復帰のたびに勝手に再開する。
            guard session.status != .paused && session.status != .cancelled else {
                AppLog.upload.notice("⏸ [RECONCILE] session=\(session.id) は \(session.status.rawValue) のため対象外")
                continue
            }

            // リトライ上限に達した、あるいはサーバがやり直しても変わらないと言っている
            // セッションも自動では動かさない。ここを通すと復帰のたびに新しい5回が始まり、
            // 上限が実質的に無くなる。再開は利用者の明示的な操作に限る。
            guard !session.autoResumeBlocked else {
                AppLog.upload.notice("⛔ [RECONCILE] session=\(session.id) は自動再開の対象外 (利用者の再試行待ち)")
                continue
            }

            do {
                let status = try await getSessionStatus(sessionId: session.id)
                session.serverExpiresAt = NetworkService.parseServerDate(status.expiresAt)
                if status.missingChunks.isEmpty {
                    NetworkService.syncUploadedChunks(
                        session: session,
                        missingChunks: [],
                        totalChunks: session.totalChunks
                    )
                    if status.status == UploadStatus.completed.rawValue {
                        AppLog.upload.notice("✅ [RECONCILE] session=\(session.id) はサーバ側で結合済み → 完了として取り込み")
                        adoptServerCompletion(session: session)
                    } else if status.status == UploadStatus.error.rawValue && status.finalizeFatal == true {
                        AppLog.upload.error("❌ [RECONCILE] session=\(session.id) はサーバ側で恒久的に失敗 → error として取り込み")
                        adoptServerFailure(
                            session: session,
                            message: status.finalizeError ?? "サーバ側でアップロードが失敗しました"
                        )
                    } else {
                        AppLog.upload.notice("✅ [RECONCILE] session=\(session.id) は全チャンク到達済み → 結合結果を確認")
                        try? await completeUpload(session: session)
                    }
                    continue
                }

                // OS 側で生きているタスクをチャンク単位で数え上げる。セッション単位で
                // 「1 本でも生きていれば待機」としてしまうと、残り 50 チャンクが
                // どこにも積まれていないのに待ち続け、次のフォアグラウンド復帰まで送信が止まる。
                let liveChunks = NetworkService.liveChunkIndices(for: session.id, in: liveKeys)
                let pending = status.missingChunks.filter { !liveChunks.contains($0) }

                if pending.isEmpty {
                    AppLog.upload.notice("🔁 [RECONCILE] session=\(session.id) 残 \(status.missingChunks.count) チャンクはすべて OS 側で送信中 → 待機")
                    registerForDelegateCallbacks(session: session, status: status, pendingChunks: [])
                } else {
                    AppLog.upload.notice("🔁 [RECONCILE] session=\(session.id) 残 \(status.missingChunks.count) チャンクのうち \(pending.count) 件を投入 (OS 側で送信中: \(liveChunks.count) 件)")
                    registerForDelegateCallbacks(session: session, status: status, pendingChunks: pending)
                    try? enqueueAllPendingChunks(session: session)
                }
            } catch let NetworkError.httpError(code, _) where code == 404 {
                // discard 前に OS 側の live task も片付ける。片付けを怠ると、
                // discard 後に delegate が「不明セッションの chunk 完了」を受けて誤動作する。
                await cancelOSTasks(sessionId: session.id)

                // 期限を過ぎたと確認できた 404 だけが「サーバ側で正当に消えた」状態。
                // それ以外の 404 は一時的な不調かもしれないので、手元のチャンクも
                // 突き合わせ対象としての登録も残したまま、状態だけを失敗にする。
                let isExpired = session.serverExpiresAt.map { $0 <= Date() } ?? false
                if isExpired {
                    AppLog.upload.notice("🗑 [RECONCILE] session=\(session.id) は期限切れ → 破棄")
                    await MainActor.run {
                        UploadManager.shared.discardSession(sessionId: session.id, reason: "server-expired")
                    }
                } else {
                    AppLog.upload.error("⚠️ [RECONCILE] session=\(session.id) は 404 だが期限内 → 手元に残して失敗として記録")
                    await MainActor.run {
                        UploadManager.shared.markSessionUnreachable(sessionId: session.id, reason: "server-404")
                    }
                }
            } catch {
                AppLog.upload.error("⚠️ [RECONCILE] session=\(session.id) status 取得失敗 (\(error.localizedDescription)) → 次回起動時に再試行")
            }
        }
    }

    /// reconcile 用の live キー集合 ("sessionId:chunkIndex") から、指定セッションのチャンク番号を取り出す。
    /// sessionId 自身に ":" が含まれても壊れないよう、最後の ":" で区切る。
    static func liveChunkIndices(for sessionId: String, in liveKeys: Set<String>) -> Set<Int> {
        var indices: Set<Int> = []
        for key in liveKeys {
            guard let separator = key.lastIndex(of: ":") else { continue }
            guard String(key[key.startIndex..<separator]) == sessionId else { continue }
            if let index = Int(key[key.index(after: separator)...]) {
                indices.insert(index)
            }
        }
        return indices
    }

    /// 起動直後の復元でセッションを delegate が見つけられる状態にする。
    ///
    /// アプリ再起動時は `activeUploadSessions` と `uploadQueues` が空なので、OS 側で
    /// 生き残っていたタスクの完了通知が届いても `didCompleteWithError` の guard で捨てられ、
    /// 進捗更新も次チャンクの投入も起きない。ここで両方を登録しておくことでその取りこぼしを防ぐ。
    /// 生きているタスクはキャンセルしない。OS が既に送っているものを止める理由が無い。
    private func registerForDelegateCallbacks(
        session: UploadSession,
        status: StatusResponse,
        pendingChunks: [Int]
    ) {
        NetworkService.syncUploadedChunks(
            session: session,
            missingChunks: status.missingChunks,
            totalChunks: session.totalChunks
        )
        withState {
            activeUploadSessions[session.id] = session
            uploadQueues[session.id] = UploadQueue(sessionId: session.id, chunks: pendingChunks)
        }
        session.updateStatus(.uploading)
    }

    func reconcileOSOwnedTasks() async -> Set<String> {
        let tasks = await backgroundSession.allTasks
        var live: Set<String> = []
        for task in tasks {
            guard let url = task.originalRequest?.url,
                  let key = Self.extractSessionChunkKey(from: url) else { continue }
            live.insert(key)
            // クライアント側 activeTaskIds を再登録する。queue はこの時点では存在しないので
            // 触らない。呼び出し側の registerForDelegateCallbacks がサーバ状態を見て作り直す。
            if let separator = key.lastIndex(of: ":") {
                let sid = String(key[key.startIndex..<separator])
                withState { activeTaskIds[sid] = task.taskIdentifier }
            }
        }
        AppLog.retry.notice("🔁 [RECONCILE] OS 所有タスク \(live.count) 件を復元")
        return live
    }
}


