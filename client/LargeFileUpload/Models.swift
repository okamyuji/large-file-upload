import Foundation

// MARK: - API Request/Response Models

struct CreateSessionRequest: Codable {
    let fileName: String
    let totalChunks: Int
    let fileSize: Int64
    let fileChecksum: String
    let chunkSize: Int
}

struct SessionResponse: Codable {
    let sessionId: String
    let status: String
    let message: String
}

struct ChunkUploadResponse: Codable {
    let chunkIndex: Int
    let status: String
    let message: String
}

struct StatusResponse: Codable {
    let sessionId: String
    let status: String
    let totalChunks: Int
    let uploadedChunks: Int
    let missingChunks: [Int]
    let progress: Double
}

struct CompleteResponse: Codable {
    let sessionId: String
    let status: String
    let finalFileChecksum: String
    let filePath: String
    let message: String
}

struct DeleteResponse: Codable {
    let sessionId: String
    let status: String
    let message: String
}

struct ErrorResponse: Codable {
    let error: String
    let message: String
    let details: String?
}

struct EmptyResponse: Codable {
    // 空のレスポンス用
}

// MARK: - Upload Session Model

class UploadSession: ObservableObject, Codable {
    let id: String
    let fileName: String
    let fileURL: URL
    let totalChunks: Int
    let fileSize: Int64
    let fileChecksum: String
    let chunkSize: Int

    @Published var status: UploadStatus = .created
    @Published var uploadedChunks: Set<Int> = []
    @Published var progress: Double = 0.0
    @Published var error: String?
    /// チャンクごとのリトライ回数。永続化されアプリ再起動後も引き継がれる。
    @Published var chunkRetryCounts: [Int: Int] = [:]
    /// チャンクごとの次回リトライ予定時刻。earliestBeginDate で予約した OS 所有タスクの証跡。
    @Published var chunkNextRetryAt: [Int: Date] = [:]

    var missingChunks: [Int] {
        let allChunks = Set(0..<totalChunks)
        return Array(allChunks.subtracting(uploadedChunks)).sorted()
    }

    var isComplete: Bool {
        uploadedChunks.count == totalChunks
    }

    init(
        id: String,
        fileName: String,
        fileURL: URL,
        totalChunks: Int,
        fileSize: Int64,
        fileChecksum: String,
        chunkSize: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.totalChunks = totalChunks
        self.fileSize = fileSize
        self.fileChecksum = fileChecksum
        self.chunkSize = chunkSize
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, fileName, fileURL, totalChunks, fileSize, fileChecksum, chunkSize
        case status, uploadedChunks, progress, error, chunkRetryCounts, chunkNextRetryAt
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.fileURL = try c.decode(URL.self, forKey: .fileURL)
        self.totalChunks = try c.decode(Int.self, forKey: .totalChunks)
        self.fileSize = try c.decode(Int64.self, forKey: .fileSize)
        self.fileChecksum = try c.decode(String.self, forKey: .fileChecksum)
        self.chunkSize = try c.decode(Int.self, forKey: .chunkSize)
        self.status = try c.decodeIfPresent(UploadStatus.self, forKey: .status) ?? .created
        self.uploadedChunks = try c.decodeIfPresent(Set<Int>.self, forKey: .uploadedChunks) ?? []
        self.progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0.0
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        // JSON はキーが String のみなので [String:_] 経由で復元
        if let raw = try c.decodeIfPresent([String: Int].self, forKey: .chunkRetryCounts) {
            var mapped: [Int: Int] = [:]
            for (k, v) in raw { if let idx = Int(k) { mapped[idx] = v } }
            self.chunkRetryCounts = mapped
        }
        if let raw = try c.decodeIfPresent([String: Date].self, forKey: .chunkNextRetryAt) {
            var mapped: [Int: Date] = [:]
            for (k, v) in raw { if let idx = Int(k) { mapped[idx] = v } }
            self.chunkNextRetryAt = mapped
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(fileURL, forKey: .fileURL)
        try c.encode(totalChunks, forKey: .totalChunks)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(fileChecksum, forKey: .fileChecksum)
        try c.encode(chunkSize, forKey: .chunkSize)
        try c.encode(status, forKey: .status)
        try c.encode(uploadedChunks, forKey: .uploadedChunks)
        try c.encode(progress, forKey: .progress)
        try c.encodeIfPresent(error, forKey: .error)
        let stringKeyedCounts = Dictionary(uniqueKeysWithValues: chunkRetryCounts.map { (String($0.key), $0.value) })
        try c.encode(stringKeyedCounts, forKey: .chunkRetryCounts)
        let stringKeyedDates = Dictionary(uniqueKeysWithValues: chunkNextRetryAt.map { (String($0.key), $0.value) })
        try c.encode(stringKeyedDates, forKey: .chunkNextRetryAt)
    }

    // MARK: - Mutations

    func updateProgress() {
        progress =
            totalChunks > 0
            ? Double(uploadedChunks.count) / Double(totalChunks) : 0.0
    }

    func markChunkUploaded(_ chunkIndex: Int) {
        uploadedChunks.insert(chunkIndex)
        updateProgress()

        if isComplete && status == .uploading {
            status = .ready
        }
    }

    func updateStatus(_ newStatus: UploadStatus) {
        status = newStatus
    }

    func setError(_ error: String) {
        self.error = error
        status = .error
    }
}

// MARK: - Upload Status

enum UploadStatus: String, CaseIterable, Codable {
    case created = "created"
    case uploading = "uploading"
    case ready = "ready"
    case completing = "completing"
    case completed = "completed"
    case error = "error"
    case paused = "paused"
    // ユーザーが能動的に停止したことを示す終端 status。history 内で「エラー」とは区別する。
    case cancelled = "cancelled"

    var description: String {
        switch self {
        // .created / .ready はサーバ確立直後や送信キューへの積み込み中で、
        // ユーザー体感としては送信開始と区別できないため「アップロード中」に統一する。
        case .created: return "アップロード中"
        case .uploading: return "アップロード中"
        case .ready: return "アップロード中"
        case .completing: return "完了処理中"
        case .completed: return "完了"
        case .error: return "エラー"
        case .paused: return "一時停止"
        case .cancelled: return "キャンセル"
        }
    }

    var color: String {
        switch self {
        case .created: return "blue"
        case .uploading: return "orange"
        case .ready: return "yellow"
        case .completing: return "purple"
        case .completed: return "green"
        case .error: return "red"
        case .paused: return "gray"
        case .cancelled: return "gray"
        }
    }
}

// MARK: - Upload Task Info

struct UploadTaskInfo {
    let sessionId: String
    let chunkIndex: Int
    let taskIdentifier: Int
    let createdAt: Date
}

// MARK: - API Endpoints

enum APIEndpoint {
    case createSession
    case uploadChunk(sessionId: String, chunkIndex: Int)
    case getStatus(sessionId: String)
    case completeUpload(sessionId: String)
    case deleteSession(sessionId: String)

    private var baseURL: String {
        // 環境変数 LARGE_FILE_UPLOAD_SERVER が優先。
        // 未設定時: Simulator は 127.0.0.1、実機は Info.plist の LARGE_FILE_UPLOAD_SERVER キー
        // (未設定なら 127.0.0.1 で fallback、実機接続時は環境か Info.plist で LAN IP を設定する)。
        if let env = ProcessInfo.processInfo.environment["LARGE_FILE_UPLOAD_SERVER"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "LARGE_FILE_UPLOAD_SERVER") as? String, !plist.isEmpty {
            return plist
        }
        // Default fallback (シミュレータ / 実機共通): 127.0.0.1。
        // 実機で LAN サーバに接続する場合は Info.plist に LARGE_FILE_UPLOAD_SERVER キー
        // (例: "http://<mac-lan-ip>:8080") を追加するか、Xcode Scheme の環境変数で設定する。
        // Xcode USB tunnel 経由 (WiFi 依存なし) で接続する場合は、
        // `xcrun devicectl device info details --device <UDID>` の tunnelIPAddress の
        // Mac 側 (fd00::/8 の ULA) を IPv6 URL 形式で指定できる。
        return "http://127.0.0.1:8080"
    }

    var url: URL {
        let urlString: String

        switch self {
        case .createSession:
            urlString = "\(baseURL)/upload/session"
        case .uploadChunk(let sessionId, let chunkIndex):
            urlString = "\(baseURL)/upload/session/\(sessionId)/chunk/\(chunkIndex)"
        case .getStatus(let sessionId):
            urlString = "\(baseURL)/upload/session/\(sessionId)/status"
        case .completeUpload(let sessionId):
            urlString = "\(baseURL)/upload/session/\(sessionId)/complete"
        case .deleteSession(let sessionId):
            urlString = "\(baseURL)/upload/session/\(sessionId)"
        }

        return URL(string: urlString)!
    }

    var httpMethod: String {
        switch self {
        case .createSession, .completeUpload:
            return "POST"
        case .uploadChunk:
            return "PUT"
        case .getStatus:
            return "GET"
        case .deleteSession:
            return "DELETE"
        }
    }
}

// MARK: - Network Errors

enum NetworkError: Error, LocalizedError {
    case invalidURL
    case noData
    case decodingError(Error)
    case httpError(Int, String)
    case fileError(String)
    case checksumMismatch
    case sessionNotFound
    case networkUnavailable
    case timeout
    case cancelled
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無効なURLです"
        case .noData:
            return "データが取得できませんでした"
        case .decodingError(let error):
            return "データ解析エラー: \(error.localizedDescription)"
        case .httpError(let code, let message):
            return "HTTPエラー (\(code)): \(message)"
        case .fileError(let message):
            return "ファイルエラー: \(message)"
        case .checksumMismatch:
            return "チェックサムが一致しません"
        case .sessionNotFound:
            return "セッションが見つかりません"
        case .networkUnavailable:
            return "ネットワークに接続できません"
        case .timeout:
            return "タイムアウトしました"
        case .cancelled:
            return "キャンセルされました"
        case .unknown(let error):
            return "不明なエラー: \(error.localizedDescription)"
        }
    }
}
