import CryptoKit
import Foundation

class FileManager: ObservableObject {
    static let shared = FileManager()

    private init() {}

    // MARK: - File Information

    func getFileInfo(url: URL) throws -> (size: Int64, name: String) {
        let attributes = try Foundation.FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let size = attributes[.size] as? Int64 ?? 0
        let name = url.lastPathComponent
        return (size: size, name: name)
    }

    // MARK: - Checksum Calculation

    func calculateFileChecksum(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return calculateChecksum(data: data)
    }

    func calculateChecksum(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Chunk Operations

    /// サーバ側のチャンクサイズ制約 (models/models.go の定数と同期): 1024 bytes 〜 10 MiB。
    static let maxChunkSize: Int = 10 * 1024 * 1024
    static let minChunkSize: Int = 1024

    /// ファイルサイズ ≤ maxChunkSize なら 1 チャンク、それ以上は 128 チャンクを目標に adaptive。
    /// 1MB floor, 10MB ceiling (server 制約) の範囲で決定する。
    /// 1GB → 約 8 MB × 128 チャンク、実機の失敗確率と HTTP オーバーヘッドを抑える。
    static func adaptiveChunkSize(for fileSize: Int64) -> Int {
        if fileSize <= Int64(maxChunkSize) {
            return max(minChunkSize, Int(max(1, fileSize)))
        }
        let targetChunks = Int64(128)
        let ideal = Int((fileSize + targetChunks - 1) / targetChunks)
        let softFloor = 1024 * 1024 // 1MB
        return max(softFloor, min(maxChunkSize, ideal))
    }

    func calculateChunkInfo(fileSize: Int64, targetChunkSize: Int? = nil)
        -> (chunkSize: Int, totalChunks: Int)
    {
        let requested = targetChunkSize ?? FileManager.adaptiveChunkSize(for: fileSize)
        // ファイルサイズより大きくはしない、かつサーバ制約内にクランプ
        let clamped = max(FileManager.minChunkSize, min(FileManager.maxChunkSize, requested))
        let chunkSize = min(clamped, max(1, Int(fileSize)))
        let totalChunks = fileSize > 0
            ? Int(ceil(Double(fileSize) / Double(chunkSize)))
            : 0
        return (chunkSize: chunkSize, totalChunks: totalChunks)
    }

    func readChunk(from url: URL, chunkIndex: Int, chunkSize: Int) throws -> Data {
        // セキュリティスコープリソースのアクセス開始
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // ファイルアクセス可能性チェック
        guard Foundation.FileManager.default.isReadableFile(atPath: url.path) else {
            throw NetworkError.fileError("ファイルにアクセスできません: \(url.lastPathComponent)")
        }
        
        // FileHandleを使用してメモリ効率的にチャンクを読み込み
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw NetworkError.fileError("ファイルを開けません: \(error.localizedDescription)")
        }
        
        defer {
            fileHandle.closeFile()
        }
        
        let startOffset = UInt64(chunkIndex * chunkSize)
        let maxOffset: UInt64
        
        // ファイルサイズを取得
        do {
            let fileAttributes = try Foundation.FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? UInt64 ?? 0
            maxOffset = fileSize
        } catch {
            throw NetworkError.fileError("ファイル情報を取得できません: \(error.localizedDescription)")
        }
        
        // 範囲チェック
        guard startOffset < maxOffset else {
            throw NetworkError.fileError("チャンクインデックス\(chunkIndex)が範囲外です（ファイルサイズ: \(maxOffset) bytes）")
        }
        
        // ファイル位置をシーク
        do {
            try fileHandle.seek(toOffset: startOffset)
        } catch {
            throw NetworkError.fileError("ファイルシークに失敗: \(error.localizedDescription)")
        }
        
        // 実際の読み込みサイズを計算
        let remainingBytes = maxOffset - startOffset
        let actualChunkSize = min(UInt64(chunkSize), remainingBytes)
        
        // チャンクデータを読み込み
        let chunkData: Data
        do {
            if #available(iOS 13.4, *) {
                chunkData = try fileHandle.read(upToCount: Int(actualChunkSize)) ?? Data()
            } else {
                chunkData = fileHandle.readData(ofLength: Int(actualChunkSize))
            }
        } catch {
            throw NetworkError.fileError("チャンク読み込みに失敗: \(error.localizedDescription)")
        }
        
        // 読み込み結果の検証
        guard !chunkData.isEmpty else {
            throw NetworkError.fileError("チャンク\(chunkIndex)のデータが空です")
        }
        
        AppLog.upload.notice("📖 [FILE] チャンク\(chunkIndex)読み込み成功: \(chunkData.count) bytes")
        return chunkData
    }

    // MARK: - Temporary File Management

    func createTemporaryFile(from sourceURL: URL) throws -> URL {
        let tempDirectory = Foundation.FileManager.default.temporaryDirectory
        let fileName = sourceURL.lastPathComponent
        let tempURL = tempDirectory.appendingPathComponent(
            "upload_\(UUID().uuidString)_\(fileName)"
        )

        // ファイル保護を無効にしてコピー
        try Foundation.FileManager.default.copyItem(at: sourceURL, to: tempURL)
        try Foundation.FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: tempURL.path
        )

        return tempURL
    }

    func cleanupTemporaryFile(at url: URL) {
        try? Foundation.FileManager.default.removeItem(at: url)
    }

    // MARK: - Document Directory

    func getDocumentsDirectory() -> URL {
        Foundation.FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
    }

    func saveUploadedFile(sessionId: String, originalURL: URL) throws -> URL {
        let documentsDir = getDocumentsDirectory()
        let uploadsDir = documentsDir.appendingPathComponent("uploads")

        // uploadsディレクトリを作成
        try Foundation.FileManager.default.createDirectory(
            at: uploadsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileName = originalURL.lastPathComponent
        let finalURL = uploadsDir.appendingPathComponent(
            "\(sessionId)_\(fileName)"
        )

        try Foundation.FileManager.default.moveItem(
            at: originalURL,
            to: finalURL
        )

        return finalURL
    }

    // MARK: - File Size Formatting

    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - File Extension Validation

    func validateFileForUpload(url: URL) throws {
        let fileInfo = try getFileInfo(url: url)

        // ファイルサイズ制限（例：10GB）
        let maxFileSize: Int64 = 10 * 1024 * 1024 * 1024
        if fileInfo.size > maxFileSize {
            throw NetworkError.fileError("ファイルサイズが大きすぎます（最大10GB）")
        }

        // 空ファイルチェック
        if fileInfo.size == 0 {
            throw NetworkError.fileError("空のファイルはアップロードできません")
        }

        // ファイル名チェック
        if fileInfo.name.isEmpty {
            throw NetworkError.fileError("無効なファイル名です")
        }

        // 危険な拡張子チェック（必要に応じて）
        let dangerousExtensions = ["exe", "bat", "cmd", "scr", "pif", "com"]
        let fileExtension = url.pathExtension.lowercased()
        if dangerousExtensions.contains(fileExtension) {
            throw NetworkError.fileError("このファイル形式はアップロードできません")
        }
    }
}

// MARK: - File Access Security

extension FileManager {
    func startAccessingSecurityScopedResource(url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
