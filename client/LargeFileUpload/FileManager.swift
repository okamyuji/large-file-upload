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

    /// ファイル全体の SHA-256 を、固定長バッファで読みながら計算する。
    ///
    /// `Data(contentsOf:)` で一度に読むと、数GBのファイルではメモリ割り当てに失敗するか、
    /// メモリ圧迫でOSにアプリを終了させられる。この記事が想定する規模では、
    /// ファイルサイズに関係なく一定のメモリで済む形にしておく必要がある。
    func calculateFileChecksum(url: URL) throws -> String {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let block = try handle.read(upToCount: checksumBufferSize), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// チェックサム計算の読み込み単位。大きくしても速度はほぼ変わらず、メモリだけ増える。
    private var checksumBufferSize: Int { 4 * 1024 * 1024 }

    /// 送信開始に必要なローカル空き容量を確かめる。
    ///
    /// 手元に置くチャンクでファイルサイズ1つ分を使う。OS へ引き渡したタスクの控えが
    /// どれだけ確保されるかは公開仕様として約束されていないため、保守的に同じだけの
    /// 余裕を積んで 2 倍を目安にしている。仕様上の根拠がある係数ではないので、
    /// 対象端末と OS で実使用量を測って調整する前提の暫定値とする。
    /// 足りないまま投入すると途中の書き込みが失敗して原因の分かりにくい停止になるため、
    /// 始める前に判断して明示的に失敗させる。
    func ensureSufficientFreeSpace(forFileSize fileSize: Int64) throws {
        let documents = getDocumentsDirectory()
        let values = try documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }

        let required = fileSize * 2
        guard available >= required else {
            throw NetworkError.fileError(
                "空き容量が足りません。必要: 約\(required / 1024 / 1024)MB, 利用可能: \(available / 1024 / 1024)MB"
            )
        }
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

    // MARK: - Persistent Upload Staging

    /// アップロード対象のソースファイルをアプリ所有の Documents/uploads/ にコピーして返す。
    ///
    /// なぜ必要か:
    /// - Document Picker から受け取る URL はセキュリティスコープ付きで、`startAccessingSecurityScopedResource`
    ///   の有効期間はアプリの当該実行中のみ。Force Quit → 再起動後は scope が失われ、
    ///   `session.fileURL` を直接読もうとしても失敗する (Resume 経路で PUT が飛ばない根本原因)。
    /// - `temporaryDirectory` は iOS がストレージ逼迫時に purge する可能性があるので不適。
    /// - Documents/ は同一 bundleID のアプリで永続、reinstall でも通常保持される。
    ///
    /// なぜ全体コピーではなくチャンク単位で書くのか:
    /// - 「ファイル全体のコピー1つ + 送信用の一時チャンク群」を同時に持つと、アプリが
    ///   自分で置くぶんだけでファイルサイズの約2倍になる。数GBを扱う前提では
    ///   容量不足でタスクの投入が途中で止まる。
    /// - 最初からチャンクとして書き出せばアプリ側の消費はファイルサイズ1つ分で済み、
    ///   そのまま `uploadTask(with:fromFile:)` の入力として使えるので追加のコピーが要らない。
    /// - ただし OS へ引き渡したタスクの控えぶんは別途必要になり得るため、端末の空き容量は
    ///   保守的に 2 倍を目安に見込む。判断は ensureSufficientFreeSpace で送信開始前に行う。
    ///
    /// 戻り値: セッション専用のステージングディレクトリ。以降 UploadSession はこの URL を保持する。
    func stageChunksForUpload(
        sourceURL: URL,
        sessionId: String,
        chunkSize: Int,
        totalChunks: Int
    ) throws -> URL {
        let stagingDir = try stagingDirectory(for: sessionId)

        // 既に存在する場合 (再送 or Force Quit 後の再作成) は作り直す
        if Foundation.FileManager.default.fileExists(atPath: stagingDir.path) {
            try? Foundation.FileManager.default.removeItem(at: stagingDir)
        }
        try Foundation.FileManager.default.createDirectory(
            at: stagingDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        for index in 0..<totalChunks {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            guard !data.isEmpty else {
                // 途中まで書いたチャンクを残すと、実体と総チャンク数が食い違う状態になる
                try? Foundation.FileManager.default.removeItem(at: stagingDir)
                throw NetworkError.fileError("チャンク \(index) を読み込めませんでした: \(sourceURL.lastPathComponent)")
            }

            let destination = chunkFileURL(in: stagingDir, chunkIndex: index)
            // .atomic は一時ファイルへ書いてから rename する。書き込み途中で終了しても、
            // 中身が欠けたチャンクが「揃っている」ように見えることがない。
            try data.write(to: destination, options: .atomic)
            try Foundation.FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: destination.path
            )
        }

        AppLog.upload.notice("📥 [STAGE] session=\(sessionId) を \(totalChunks) チャンクに分割して保存")
        return stagingDir
    }

    /// セッション専用のステージングディレクトリ。
    /// sessionId はサーバ由来の文字列なので、パス要素として使う前に形式を検証する。
    func stagingDirectory(for sessionId: String) throws -> URL {
        guard !sessionId.isEmpty,
              sessionId.count <= 128,
              sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw NetworkError.fileError("不正なセッションID形式: \(sessionId)")
        }
        return getDocumentsDirectory()
            .appendingPathComponent("uploads", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    /// ステージング済みチャンクのファイル URL。
    func chunkFileURL(in stagingDirectory: URL, chunkIndex: Int) -> URL {
        stagingDirectory.appendingPathComponent("chunk_\(chunkIndex).dat")
    }

    /// セッションの全チャンクがステージング済みかどうか。
    ///
    /// 存在だけでなくサイズも確かめる。作成直後に強制終了されると、記録はあるが
    /// チャンクが揃っていない状態や、中身が途中までのファイルが残ることがある。
    /// これを完全とみなして送ると、各チャンクの検証は通るのに最後の全体検証だけが
    /// 失敗する、原因の見えにくい不具合になる。
    func isStagingComplete(session: UploadSession) -> Bool {
        for index in 0..<session.totalChunks {
            let url = chunkFileURL(in: session.fileURL, chunkIndex: index)
            guard let attributes = try? Foundation.FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64 else {
                return false
            }

            let offset = Int64(index) * Int64(session.chunkSize)
            let expected = min(Int64(session.chunkSize), session.fileSize - offset)
            if size != expected {
                AppLog.upload.error("⚠️ [STAGE] session=\(session.id) chunk=\(index) のサイズが不一致 (期待: \(expected), 実際: \(size))")
                return false
            }
        }
        return true
    }

    /// 送信中のどのセッションにも属さないステージングディレクトリを削除する。
    /// 強制終了や破棄で取り残されたチャンク群がローカル容量を占め続けるのを防ぐ。
    func cleanupOrphanedStagingDirectories(activeSessionIds: Set<String>) {
        let uploadsDir = getDocumentsDirectory().appendingPathComponent("uploads", isDirectory: true)
        let entries = (try? Foundation.FileManager.default.contentsOfDirectory(atPath: uploadsDir.path)) ?? []

        var removed = 0
        for name in entries where !activeSessionIds.contains(name) {
            try? Foundation.FileManager.default.removeItem(at: uploadsDir.appendingPathComponent(name))
            removed += 1
        }

        if removed > 0 {
            AppLog.upload.notice("🧹 [STAGE GC] 参照されていないステージング \(removed) 件を削除")
        }
    }

    /// stageFileForUpload で作ったコピーを削除する。complete / discard / delete 経路で呼ぶ。
    func cleanupStagedFile(sessionId: String, fileURL: URL) {
        let uploadsDir = getDocumentsDirectory().appendingPathComponent("uploads", isDirectory: true)
        // fileURL が uploads/ 配下にあれば削除。ユーザーが選んだ元ファイルは絶対に触らない。
        // path.hasPrefix(uploadsDir.path) だけだと `Documents/uploads2/…` のような
        // 兄弟ディレクトリまで巻き込むので、末尾に path separator を明示的に付けて境界判定する。
        let uploadsPrefix = uploadsDir.path.hasSuffix("/") ? uploadsDir.path : uploadsDir.path + "/"
        if fileURL.path.hasPrefix(uploadsPrefix) {
            try? Foundation.FileManager.default.removeItem(at: fileURL)
            AppLog.upload.notice("🗑 [STAGE] コピー削除: session=\(sessionId)")
        }
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
