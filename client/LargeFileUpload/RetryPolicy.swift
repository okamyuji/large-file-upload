import Foundation

/// 指数バックオフ + jitter のリトライポリシー。
/// BackgroundURLSession 上のチャンクアップロード失敗時に共通で使う。
struct RetryPolicy: Sendable, Equatable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double
    /// ±jitterRatio の範囲でランダムに揺らす (0.0-1.0)。
    let jitterRatio: Double

    static let `default` = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 1.0,
        maxDelay: 60.0,
        multiplier: 2.0,
        jitterRatio: 0.2
    )

    /// Retry-After ヘッダ値のクランプ上限 (秒)。
    /// サーバが極端に大きな値を返した場合の暴走を防ぐ。
    static let maxRetryAfterCap: TimeInterval = 300

    /// - Parameter attempt: 1-origin の試行回数
    /// - Parameter random: [0,1) の乱数生成 (テストで固定化するため注入可能)
    /// - Returns: 次リトライまでの遅延秒。attempt が範囲外なら nil (= 打ち止め)。
    func delay(forAttempt attempt: Int, random: () -> Double = { Double.random(in: 0..<1) }) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let raw = baseDelay * pow(multiplier, Double(attempt - 1))
        let capped = min(maxDelay, raw)
        let r = max(0.0, min(1.0, random()))
        let jitter = 1.0 + (r * 2 - 1) * jitterRatio
        return max(0, capped * jitter)
    }
}
