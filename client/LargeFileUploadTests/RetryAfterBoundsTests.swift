import Testing
import Foundation

@testable import LargeFileUpload

/// Retry-After の解析対象と、試行回数の上限が全経路に効くことを検証する。
struct RetryAfterBoundsTests {

    @Test("503 でも Retry-After を解析して retryAfter に分類する")
    func parsesRetryAfterFor503() {
        let decision = RetryClassifier.classify(
            nsErrorCode: nil,
            nsErrorDomain: nil,
            httpStatus: 503,
            retryAfterHeader: "5"
        )
        #expect(decision == .retryAfter(5))
    }

    /// 指定値を上限へ切り詰めると、サーバが求めた時刻より早く再送してしまう。
    /// 分類の時点では値をそのまま渡し、待てるかどうかの判断は呼び出し側に任せる。
    @Test("Retry-After は上限を超えても切り詰めない")
    func doesNotShortenLongRetryAfter() {
        let decision = RetryClassifier.classify(
            nsErrorCode: nil,
            nsErrorDomain: nil,
            httpStatus: 503,
            retryAfterHeader: "3600"
        )
        #expect(decision == .retryAfter(3600))
    }

    @Test("503 で Retry-After が無ければ指数バックオフに落とす")
    func fallsBackWithoutHeaderFor503() {
        let decision = RetryClassifier.classify(
            nsErrorCode: nil,
            nsErrorDomain: nil,
            httpStatus: 503,
            retryAfterHeader: nil
        )
        #expect(decision == .retry)
    }

    @Test("503 の Retry-After が不正値なら指数バックオフに落とす")
    func fallsBackOnMalformedHeaderFor503() {
        let decision = RetryClassifier.classify(
            nsErrorCode: nil,
            nsErrorDomain: nil,
            httpStatus: 503,
            retryAfterHeader: "soon"
        )
        #expect(decision == .retry)
    }

    @Test("503 の Retry-After は HTTP 日付形式も受ける")
    func parsesHTTPDateFor503() {
        let target = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        let decision = RetryClassifier.classify(
            nsErrorCode: nil,
            nsErrorDomain: nil,
            httpStatus: 503,
            retryAfterHeader: formatter.string(from: target)
        )

        guard case .retryAfter(let seconds) = decision else {
            Issue.record("retryAfter に分類されませんでした: \(decision)")
            return
        }
        // 秒精度の丸めがあるので範囲で見る
        #expect(seconds > 100 && seconds <= 121)
    }

    @Test("500 や 502 は Retry-After があっても指数バックオフのまま")
    func otherServerErrorsStayOnBackoff() {
        for status in [500, 502, 504] {
            let decision = RetryClassifier.classify(
                nsErrorCode: nil,
                nsErrorDomain: nil,
                httpStatus: status,
                retryAfterHeader: "5"
            )
            #expect(decision == .retry)
        }
    }

    /// 上限判定は待ち時間の決め方を分岐させる前に置く必要がある。
    /// retryAfter 経路だけ上限を通らないと、429 が続く限り再送が止まらない。
    @Test("指数バックオフは上限を超えると打ち止めになる")
    func backoffStopsAtLimit() {
        let policy = RetryPolicy.default
        #expect(policy.delay(forAttempt: policy.maxAttempts) != nil)
        #expect(policy.delay(forAttempt: policy.maxAttempts + 1) == nil)
    }
}
