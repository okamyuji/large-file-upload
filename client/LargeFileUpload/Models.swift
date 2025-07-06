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

class UploadSession: ObservableObject {
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

enum UploadStatus: String, CaseIterable {
    case created = "created"
    case uploading = "uploading"
    case ready = "ready"
    case completing = "completing"
    case completed = "completed"
    case error = "error"
    case paused = "paused"

    var description: String {
        switch self {
        case .created: return "作成済み"
        case .uploading: return "アップロード中"
        case .ready: return "完了準備中"
        case .completing: return "完了処理中"
        case .completed: return "完了"
        case .error: return "エラー"
        case .paused: return "一時停止"
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
        return "http://192.168.0.16:8080"
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
