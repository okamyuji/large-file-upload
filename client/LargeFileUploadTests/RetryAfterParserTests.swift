import Testing
import Foundation

@testable import LargeFileUpload

struct RetryAfterParserTests {

    @Test("整数秒 → その値", arguments: ["5", "0", "300", "1"])
    func deltaSecondsPass(raw: String) {
        let result = RetryClassifier.parseRetryAfter(raw)
        #expect(result != nil)
        #expect(result == TimeInterval(raw))
    }

    @Test("空文字 / nil → nil")
    func emptyIsNil() {
        #expect(RetryClassifier.parseRetryAfter(nil) == nil)
        #expect(RetryClassifier.parseRetryAfter("") == nil)
        #expect(RetryClassifier.parseRetryAfter("   ") == nil)
    }

    @Test("負値 → 0.0 にクランプ")
    func negativeClampsToZero() {
        #expect(RetryClassifier.parseRetryAfter("-3") == 0.0)
        #expect(RetryClassifier.parseRetryAfter("-1000") == 0.0)
    }

    @Test("非数値 (単なる文字列) → nil")
    func malformedIsNil() {
        #expect(RetryClassifier.parseRetryAfter("abc") == nil)
        #expect(RetryClassifier.parseRetryAfter("5 seconds") == nil)
        #expect(RetryClassifier.parseRetryAfter("later") == nil)
    }

    @Test("HTTP-date (RFC 7231 形式) → 差分秒 (± 2秒許容)")
    func httpDateParsed() {
        // 未来 60 秒後の HTTP-date
        let future = Date().addingTimeInterval(60)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let raw = df.string(from: future)

        let result = RetryClassifier.parseRetryAfter(raw)
        #expect(result != nil)
        // 60 秒 ± 2 秒 (実行時間分の許容)
        #expect(abs((result ?? 0) - 60) < 2.0, "raw=\(raw) got=\(result ?? -1)")
    }

    @Test("HTTP-date が過去 → 0.0 にクランプ")
    func pastHttpDateIsZero() {
        let past = Date().addingTimeInterval(-3600) // 1時間前
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let raw = df.string(from: past)

        let result = RetryClassifier.parseRetryAfter(raw)
        #expect(result != nil)
        #expect(result == 0.0)
    }

    @Test("classify: 429 + HTTP-date → retryAfter(秒数)")
    func classifyWith429AndHttpDate() {
        let future = Date().addingTimeInterval(30)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let raw = df.string(from: future)

        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil,
                                          httpStatus: 429, retryAfterHeader: raw)
        if case .retryAfter(let sec) = d {
            #expect(abs(sec - 30) < 2.0)
        } else {
            Issue.record("expected retryAfter, got \(d)")
        }
    }

    @Test("classify: 429 + malformed → retry (policy fallback)")
    func classifyWith429AndMalformed() {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil,
                                          httpStatus: 429, retryAfterHeader: "not-a-date")
        #expect(d == .retry)
    }
}
