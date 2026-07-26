import Foundation

/// エラー分類の結果。BackgroundURLSession のチャンク完了 delegate から使う。
enum RetryDecision: Equatable, CustomStringConvertible {
    case retry
    case retryAfter(TimeInterval)
    case fail

    var description: String {
        switch self {
        case .retry: return "retry"
        case .retryAfter(let s): return "retryAfter(\(s))"
        case .fail: return "fail"
        }
    }
}

/// URLSessionTask 完了時のエラー/レスポンスから再送判断する pure な関数。
/// テスト容易性のため NSError の (domain, code) と HTTP status のみを引数に取る。
enum RetryClassifier {

    /// Retry-After ヘッダのパース。
    /// - delta-seconds 形式 ("5", "300"): その値を返す (負値は 0 にクランプ)
    /// - RFC 7231 HTTP-date 形式 ("Wed, 21 Oct 2026 07:28:00 GMT"): 今からの差分秒を返す
    /// - 空文字 / malformed: nil (呼び出し側は RetryPolicy にフォールバック)
    static func parseRetryAfter(_ raw: String?) -> TimeInterval? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        // ① delta-seconds
        if let sec = Double(trimmed) {
            return max(0, sec)
        }
        // ② HTTP-date (RFC 7231 GMT)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ] {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) {
                return max(0, d.timeIntervalSinceNow)
            }
        }
        return nil
    }

    static func classify(nsErrorCode: Int?, nsErrorDomain: String?, httpStatus: Int?, retryAfterHeader: String? = nil) -> RetryDecision {
        // HTTP レスポンスがあれば HTTP ステータスで判断
        if let status = httpStatus {
            switch status {
            case 200...299:
                return .fail // 成功ケース。呼び出し側は事前に分岐している想定。
            // 429 と 503 はどちらもサーバが Retry-After で待ってほしい秒数を伝えてくる。
            // 503 でヘッダを読み落とすと、サーバが指定した期間より早く再送してしまう。
            case 429, 503:
                // サーバが指定した秒数はそのまま渡す。上限で切り詰めると指定より早く
                // 再送することになり、Retry-After を尊重したことにならない。
                // 長すぎる指定をどう扱うかは呼び出し側の方針として scheduleChunkRetry で決める。
                if let sec = parseRetryAfter(retryAfterHeader) {
                    return .retryAfter(sec)
                }
                return .retry
            case 500...599:
                return .retry
            default: // 4xx (429除く) は永続エラー
                return .fail
            }
        }

        // NSError 判定
        guard let code = nsErrorCode, let domain = nsErrorDomain else {
            return .fail
        }
        guard domain == NSURLErrorDomain else {
            return .fail
        }
        // 意図的キャンセル
        if code == NSURLErrorCancelled {
            return .fail
        }
        let retryCodes: Set<Int> = [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorCannotFindHost,
            NSURLErrorSecureConnectionFailed
        ]
        return retryCodes.contains(code) ? .retry : .fail
    }
}
