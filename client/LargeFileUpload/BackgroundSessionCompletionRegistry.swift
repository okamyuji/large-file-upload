import Foundation

/// BackgroundURLSession の completion handler を identifier ごとに保持する。
///
/// なぜ NetworkService の中に置かないのか。Apple は
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` の中で
/// 「handler を先に保存し、そのあとで同じ identifier のセッションを作り直す」順序を求めている。
/// handler の保存先を NetworkService の property にすると、代入式を評価する時点で
/// singleton の初期化が走ってセッションが先に生成される。順序が逆になるため、
/// セッション生成直後に届いた `urlSessionDidFinishEvents` が nil の handler を見て
/// UIKit へ呼び戻せなくなる余地が残る。
///
/// そこでセッション生成を伴わない独立した置き場を用意し、両方向の取りこぼしを防ぐ。
/// - handler が先に登録された場合: `finish` がその場で呼び出す
/// - イベント完了が先に届いた場合: identifier を覚えておき、`store` の時点で呼び出す
final class BackgroundSessionCompletionRegistry {
    static let shared = BackgroundSessionCompletionRegistry()

    private let lock = NSLock()
    private var handlers: [String: () -> Void] = [:]
    private var finishedIdentifiers: Set<String> = []

    private init() {}

    /// AppDelegate から、セッションを作り直す前に呼ぶ。
    func store(identifier: String, handler: @escaping () -> Void) {
        lock.lock()
        let alreadyFinished = finishedIdentifiers.remove(identifier) != nil
        if !alreadyFinished {
            handlers[identifier] = handler
        }
        lock.unlock()

        if alreadyFinished {
            AppLog.upload.notice("🔔 [BG HANDLER] identifier=\(identifier) は既にイベント完了済み → 即座に呼び戻し")
            callOnMain(handler)
        }
    }

    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` から呼ぶ。
    func finish(identifier: String) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        if handler == nil {
            finishedIdentifiers.insert(identifier)
        }
        lock.unlock()

        guard let handler else {
            AppLog.upload.notice("🔔 [BG HANDLER] identifier=\(identifier) の handler 未登録 → 登録時に呼び戻す")
            return
        }
        callOnMain(handler)
    }

    /// UIKit へ返す completion handler はメインスレッドで呼ぶ。
    private func callOnMain(_ handler: @escaping () -> Void) {
        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async(execute: handler)
        }
    }
}
