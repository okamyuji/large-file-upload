import Testing
import Foundation

@testable import LargeFileUpload

/// 起動時 reconcile の粒度を検証する。
/// セッション単位で「OS 側にタスクが 1 本でもあるから送信中」と判断すると、
/// 残りチャンクがどこにも積まれないまま待ち続ける。差分はチャンク単位で求める必要がある。
struct LiveChunkDiffTests {

    @Test("該当セッションの live チャンク番号だけを取り出す")
    func extractsOnlyMatchingSession() {
        let keys: Set<String> = ["sessA:0", "sessA:5", "sessB:3"]
        #expect(NetworkService.liveChunkIndices(for: "sessA", in: keys) == [0, 5])
        #expect(NetworkService.liveChunkIndices(for: "sessB", in: keys) == [3])
    }

    @Test("live タスクが無いセッションは空集合")
    func returnsEmptyForUnknownSession() {
        let keys: Set<String> = ["sessA:0"]
        #expect(NetworkService.liveChunkIndices(for: "sessC", in: keys).isEmpty)
    }

    @Test("sessionId にコロンが含まれても最後の区切りで分割する")
    func handlesColonInSessionId() {
        let keys: Set<String> = ["session:with:colon:7"]
        #expect(NetworkService.liveChunkIndices(for: "session:with:colon", in: keys) == [7])
    }

    @Test("チャンク番号が数値でないキーは無視する")
    func ignoresMalformedKeys() {
        let keys: Set<String> = ["sessA:abc", "sessA:2"]
        #expect(NetworkService.liveChunkIndices(for: "sessA", in: keys) == [2])
    }

    @Test("サーバの missing から live 分を差し引いた残りが投入対象になる")
    func pendingIsMissingMinusLive() {
        let keys: Set<String> = ["sessA:1", "sessA:4"]
        let missingChunks = [1, 2, 3, 4, 5]
        let live = NetworkService.liveChunkIndices(for: "sessA", in: keys)
        let pending = missingChunks.filter { !live.contains($0) }
        // live が 1 本でもあるからと待機してしまうと、この 3 件が永久に積まれない
        #expect(pending == [2, 3, 5])
    }

    @Test("missing がすべて live なら投入対象は無い")
    func pendingIsEmptyWhenAllLive() {
        let keys: Set<String> = ["sessA:1", "sessA:2"]
        let live = NetworkService.liveChunkIndices(for: "sessA", in: keys)
        let pending = [1, 2].filter { !live.contains($0) }
        #expect(pending.isEmpty)
    }
}
