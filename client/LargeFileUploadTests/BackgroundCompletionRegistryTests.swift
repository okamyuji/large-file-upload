import Testing
import Foundation

@testable import LargeFileUpload

/// BackgroundURLSession の completion handler が、登録とイベント完了のどちらが先でも
/// 必ず1度呼ばれることを検証する。ここを落とすとOSへ返す handler が呼ばれないまま残る。
struct BackgroundCompletionRegistryTests {

    /// テストごとに identifier を変えて、レジストリの状態を共有しない。
    private func uniqueIdentifier(_ label: String) -> String {
        "test.\(label).\(UUID().uuidString)"
    }

    private func waitForHandler(_ counter: @escaping () -> Int) async -> Int {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if counter() > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return counter()
    }

    @Test("handler を先に登録し、あとでイベント完了が来たら呼ばれる")
    func handlerStoredBeforeFinish() async {
        let identifier = uniqueIdentifier("store-first")
        let calls = Counter()

        BackgroundSessionCompletionRegistry.shared.store(identifier: identifier) {
            calls.increment()
        }
        #expect(calls.value == 0)

        BackgroundSessionCompletionRegistry.shared.finish(identifier: identifier)
        #expect(await waitForHandler({ calls.value }) == 1)
    }

    /// セッション生成直後にイベント完了が届き、handler の登録がそのあとになる順序。
    /// ここで取りこぼすと handler は永久に呼ばれない。
    @Test("イベント完了が先に来ても、handler 登録時に呼ばれる")
    func finishBeforeHandlerStored() async {
        let identifier = uniqueIdentifier("finish-first")
        let calls = Counter()

        BackgroundSessionCompletionRegistry.shared.finish(identifier: identifier)

        BackgroundSessionCompletionRegistry.shared.store(identifier: identifier) {
            calls.increment()
        }
        #expect(await waitForHandler({ calls.value }) == 1)
    }

    @Test("イベント完了が2度来ても handler は1度だけ呼ばれる")
    func handlerIsCalledOnce() async {
        let identifier = uniqueIdentifier("once")
        let calls = Counter()

        BackgroundSessionCompletionRegistry.shared.store(identifier: identifier) {
            calls.increment()
        }
        BackgroundSessionCompletionRegistry.shared.finish(identifier: identifier)
        BackgroundSessionCompletionRegistry.shared.finish(identifier: identifier)

        #expect(await waitForHandler({ calls.value }) == 1)
    }

    @Test("identifier が違う handler は互いに影響しない")
    func identifiersAreIsolated() async {
        let first = uniqueIdentifier("iso-a")
        let second = uniqueIdentifier("iso-b")
        let firstCalls = Counter()
        let secondCalls = Counter()

        BackgroundSessionCompletionRegistry.shared.store(identifier: first) {
            firstCalls.increment()
        }
        BackgroundSessionCompletionRegistry.shared.store(identifier: second) {
            secondCalls.increment()
        }

        BackgroundSessionCompletionRegistry.shared.finish(identifier: first)
        #expect(await waitForHandler({ firstCalls.value }) == 1)
        #expect(secondCalls.value == 0)
    }
}

/// テスト用のスレッドセーフなカウンタ。handler はメインスレッドで呼ばれる。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
