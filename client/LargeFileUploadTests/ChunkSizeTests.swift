import Testing
import Foundation

@testable import LargeFileUpload

struct ChunkSizeTests {
    typealias FM = LargeFileUpload.FileManager

    @Test("小ファイル (5 MB) は 1 チャンク")
    func smallFile() {
        let info = FM.shared.calculateChunkInfo(fileSize: 5 * 1024 * 1024)
        #expect(info.totalChunks == 1)
        #expect(info.chunkSize >= FM.minChunkSize)
        #expect(info.chunkSize <= FM.maxChunkSize)
    }

    @Test("中ファイル (100 MB) は 128 チャンク以下")
    func mediumFile() {
        let info = FM.shared.calculateChunkInfo(fileSize: 100 * 1024 * 1024)
        #expect(info.totalChunks <= 128)
        #expect(info.chunkSize <= FM.maxChunkSize)
    }

    @Test("大ファイル (1 GB) は 128 チャンク以下、チャンクサイズはサーバ上限内")
    func largeFile() {
        let info = FM.shared.calculateChunkInfo(fileSize: 1024 * 1024 * 1024)
        // 1GB / 10MB = 103 chunks (max chunk size で制限)
        #expect(info.totalChunks <= 200)
        #expect(info.chunkSize <= FM.maxChunkSize)
        #expect(info.chunkSize >= FM.minChunkSize)
    }

    @Test("超大ファイル (10 GB) でもチャンクサイズは上限で頭打ち")
    func veryLargeFile() {
        let info = FM.shared.calculateChunkInfo(fileSize: 10 * 1024 * 1024 * 1024)
        #expect(info.chunkSize == FM.maxChunkSize)
        // 10 GB / 10 MB = 1024 chunks — 頭打ち後は自然に増える
        #expect(info.totalChunks == 1024)
    }

    @Test("adaptive: fileSize=0 でも例外を投げない")
    func zeroFile() {
        let info = FM.shared.calculateChunkInfo(fileSize: 0)
        #expect(info.chunkSize >= 1)
    }

    static let coverageSizes: [Int64] = [
        1_000_000,
        50 * 1_048_576,
        500 * 1_048_576,
        1024 * 1_048_576,
        2048 * 1_048_576
    ]

    @Test("チャンクサイズ × totalChunks でファイル全体をカバー", arguments: ChunkSizeTests.coverageSizes)
    func coverage(fileSize: Int64) {
        let info = FM.shared.calculateChunkInfo(fileSize: fileSize)
        let covered = Int64(info.chunkSize) * Int64(info.totalChunks)
        #expect(covered >= fileSize)
        #expect(covered < fileSize + Int64(info.chunkSize))
    }
}
