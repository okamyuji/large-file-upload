import Testing
import Foundation

@testable import LargeFileUpload

struct RetryClassifierTests {

    // MARK: - HTTP status

    @Test("5xx は retry", arguments: [500, 502, 503, 504])
    func fiveXxRetries(status: Int) {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil, httpStatus: status)
        #expect(d == .retry)
    }

    @Test("429 (Retry-After なし) は retry")
    func fourTwentyNineNoHeader() {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil, httpStatus: 429)
        #expect(d == .retry)
    }

    @Test("429 (Retry-After: 5) は retryAfter(5)")
    func fourTwentyNineWithHeader() {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil, httpStatus: 429, retryAfterHeader: "5")
        #expect(d == .retryAfter(5.0))
    }

    @Test("4xx (429除く) は fail", arguments: [400, 401, 403, 404, 413])
    func fourXxFails(status: Int) {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil, httpStatus: status)
        #expect(d == .fail)
    }

    @Test("2xx は fail (成功パスを通す前提)")
    func twoXxIsFail() {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil, httpStatus: 200)
        #expect(d == .fail)
    }

    // MARK: - NSURLError

    @Test("Cancelled は fail")
    func cancelledFails() {
        let d = RetryClassifier.classify(
            nsErrorCode: NSURLErrorCancelled,
            nsErrorDomain: NSURLErrorDomain,
            httpStatus: nil
        )
        #expect(d == .fail)
    }

    @Test("再送対象コードは retry", arguments: [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff
    ])
    func retryableCodesRetry(code: Int) {
        let d = RetryClassifier.classify(
            nsErrorCode: code,
            nsErrorDomain: NSURLErrorDomain,
            httpStatus: nil
        )
        #expect(d == .retry)
    }

    @Test("NSURLErrorDomain 以外は fail")
    func otherDomainFails() {
        let d = RetryClassifier.classify(
            nsErrorCode: 42,
            nsErrorDomain: NSCocoaErrorDomain,
            httpStatus: nil
        )
        #expect(d == .fail)
    }

    @Test("エラーもレスポンスもなければ fail")
    func nothingFails() {
        let d = RetryClassifier.classify(nsErrorCode: nil, nsErrorDomain: nil, httpStatus: nil)
        #expect(d == .fail)
    }
}
