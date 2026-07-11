import Testing
import Foundation

@testable import LargeFileUpload

struct UploadSessionCodableTests {

    private func makeSession() -> UploadSession {
        let s = UploadSession(
            id: "sess-1",
            fileName: "big.bin",
            fileURL: URL(fileURLWithPath: "/tmp/big.bin"),
            totalChunks: 10,
            fileSize: 1_073_741_824,
            fileChecksum: "abc123",
            chunkSize: 107_374_182
        )
        s.status = .uploading
        s.uploadedChunks = [0, 1, 2, 5]
        s.progress = 0.4
        s.error = nil
        s.chunkRetryCounts = [3: 2, 4: 1]
        s.chunkNextRetryAt = [3: Date(timeIntervalSince1970: 1_800_000_000),
                              4: Date(timeIntervalSince1970: 1_800_000_030)]
        return s
    }

    @Test("旧 JSON (chunkNextRetryAt なし) を decode してもデフォルト空辞書")
    func legacyJsonDecodesWithEmptyRetryAt() throws {
        // Phase 5 で書かれた旧形式 (chunkNextRetryAt キーなし)
        let legacyJson = """
        {
          "id":"sess-legacy",
          "fileName":"legacy.bin",
          "fileURL":"file:///tmp/legacy.bin",
          "totalChunks":5,
          "fileSize":100,
          "fileChecksum":"x",
          "chunkSize":20,
          "status":"uploading",
          "uploadedChunks":[0,1],
          "progress":0.4,
          "chunkRetryCounts":{"2":1}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UploadSession.self, from: legacyJson)
        #expect(decoded.id == "sess-legacy")
        #expect(decoded.chunkRetryCounts[2] == 1)
        #expect(decoded.chunkNextRetryAt.isEmpty)
    }

    @Test("Codable round-trip: 基本フィールド保持")
    func roundTripBasics() throws {
        let s = makeSession()
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UploadSession.self, from: data)

        #expect(decoded.id == "sess-1")
        #expect(decoded.fileName == "big.bin")
        #expect(decoded.totalChunks == 10)
        #expect(decoded.fileSize == 1_073_741_824)
        #expect(decoded.fileChecksum == "abc123")
        #expect(decoded.chunkSize == 107_374_182)
    }

    @Test("Codable round-trip: 進行状態と retryCounts と chunkNextRetryAt")
    func roundTripState() throws {
        let s = makeSession()
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UploadSession.self, from: data)

        #expect(decoded.status == .uploading)
        #expect(decoded.uploadedChunks == [0, 1, 2, 5])
        #expect(decoded.progress == 0.4)
        #expect(decoded.chunkRetryCounts[3] == 2)
        #expect(decoded.chunkRetryCounts[4] == 1)
        #expect(decoded.chunkRetryCounts.count == 2)
        #expect(decoded.chunkNextRetryAt[3] == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(decoded.chunkNextRetryAt[4] == Date(timeIntervalSince1970: 1_800_000_030))
    }

    @Test("missingChunks は再構成後も正しく計算される")
    func missingChunksAfterRoundTrip() throws {
        let s = makeSession()
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UploadSession.self, from: data)

        // totalChunks=10, uploaded={0,1,2,5} → missing={3,4,6,7,8,9}
        #expect(decoded.missingChunks == [3, 4, 6, 7, 8, 9])
    }

    @Test("空のデフォルト値もエンコード/デコードできる")
    func defaultsRoundTrip() throws {
        let s = UploadSession(
            id: "sess-empty",
            fileName: "e.bin",
            fileURL: URL(fileURLWithPath: "/tmp/e.bin"),
            totalChunks: 3,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 50
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(UploadSession.self, from: data)
        #expect(decoded.status == .created)
        #expect(decoded.uploadedChunks.isEmpty)
        #expect(decoded.chunkRetryCounts.isEmpty)
        #expect(decoded.error == nil)
    }
}
