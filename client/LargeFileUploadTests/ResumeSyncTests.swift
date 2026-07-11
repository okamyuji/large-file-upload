import Testing
import Foundation

@testable import LargeFileUpload

struct ResumeSyncTests {

    private func makeSession(total: Int) -> UploadSession {
        UploadSession(
            id: "sess",
            fileName: "f.bin",
            fileURL: URL(fileURLWithPath: "/tmp/f.bin"),
            totalChunks: total,
            fileSize: 100,
            fileChecksum: "x",
            chunkSize: 10
        )
    }

    @Test("全チャンク missing なら uploadedChunks は空、progress=0")
    func allMissing() {
        let s = makeSession(total: 5)
        s.uploadedChunks = [0, 1] // 事前状態はサーバ真実で上書きされる
        NetworkService.syncUploadedChunks(session: s, missingChunks: [0,1,2,3,4], totalChunks: 5)
        #expect(s.uploadedChunks.isEmpty)
        #expect(s.progress == 0.0)
    }

    @Test("missing=[] なら全チャンク uploaded、progress=1.0")
    func nothingMissing() {
        let s = makeSession(total: 4)
        NetworkService.syncUploadedChunks(session: s, missingChunks: [], totalChunks: 4)
        #expect(s.uploadedChunks == [0, 1, 2, 3])
        #expect(s.progress == 1.0)
    }

    @Test("部分 missing で正しく差集合")
    func partialMissing() {
        let s = makeSession(total: 10)
        NetworkService.syncUploadedChunks(session: s, missingChunks: [3, 7, 9], totalChunks: 10)
        #expect(s.uploadedChunks == [0,1,2,4,5,6,8])
        #expect(s.progress == 0.7)
    }

    @Test("クライアント側の以前の状態は上書きされる (サーバが真実)")
    func serverIsSourceOfTruth() {
        let s = makeSession(total: 5)
        s.uploadedChunks = [0, 1, 2, 3, 4] // クライアントは完了と信じている
        // が、サーバでは実は 2,3 が未受信だった
        NetworkService.syncUploadedChunks(session: s, missingChunks: [2, 3], totalChunks: 5)
        #expect(s.uploadedChunks == [0, 1, 4])
        #expect(s.progress == 0.6)
    }

    @Test("missing に総チャンク範囲外の値があっても壊れない")
    func outOfRangeMissingIgnored() {
        let s = makeSession(total: 3)
        NetworkService.syncUploadedChunks(session: s, missingChunks: [1, 99], totalChunks: 3)
        // 99 は 0..<3 に含まれないので subtracting でも無視される
        #expect(s.uploadedChunks == [0, 2])
    }
}
