import Testing
import Foundation

@testable import LargeFileUpload

struct RetryPolicyTests {

    // deterministic 用 jitter=0 の policy
    private let noJitter = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 1.0,
        maxDelay: 60.0,
        multiplier: 2.0,
        jitterRatio: 0.0
    )

    @Test("attempt 1 は baseDelay と一致 (jitter=0)")
    func attemptOneReturnsBaseDelay() {
        #expect(noJitter.delay(forAttempt: 1) == 1.0)
    }

    @Test("attempt 2/3/4 は幾何級数 (multiplier=2, jitter=0)")
    func exponentialGrowth() {
        #expect(noJitter.delay(forAttempt: 2) == 2.0)
        #expect(noJitter.delay(forAttempt: 3) == 4.0)
        #expect(noJitter.delay(forAttempt: 4) == 8.0)
    }

    @Test("maxDelay で頭打ち (base=1, multiplier=2, maxDelay=60)")
    func cappedAtMaxDelay() {
        // attempt 7 だと 1*2^6=64 → 60 で頭打ち
        let capPolicy = RetryPolicy(
            maxAttempts: 10, baseDelay: 1.0, maxDelay: 60.0,
            multiplier: 2.0, jitterRatio: 0.0
        )
        #expect(capPolicy.delay(forAttempt: 7) == 60.0)
        #expect(capPolicy.delay(forAttempt: 10) == 60.0)
    }

    @Test("attempt > maxAttempts で nil")
    func exhaustedReturnsNil() {
        #expect(noJitter.delay(forAttempt: 6) == nil)
        #expect(noJitter.delay(forAttempt: 100) == nil)
    }

    @Test("attempt < 1 は nil")
    func nonPositiveAttemptIsNil() {
        #expect(noJitter.delay(forAttempt: 0) == nil)
        #expect(noJitter.delay(forAttempt: -1) == nil)
    }

    @Test("jitter=0.2 では baseDelay±20% の範囲に収まる (attempt=1)")
    func jitterRangeAttemptOne() {
        let policy = RetryPolicy(
            maxAttempts: 5, baseDelay: 10.0, maxDelay: 60.0,
            multiplier: 2.0, jitterRatio: 0.2
        )
        // random=0 → 1.0 + (0*2-1)*0.2 = 0.8 → 10*0.8=8.0
        // random=1 → 1.0 + (1*2-1)*0.2 = 1.2 → 10*1.2=12.0
        for i in 0..<20 {
            let r = Double(i) / 20.0
            let d = policy.delay(forAttempt: 1, random: { r })!
            #expect(d >= 7.99 && d <= 12.01, "d=\(d) out of range for r=\(r)")
        }
    }

    @Test("delay は常に非負")
    func delayIsNonNegative() {
        let policy = RetryPolicy(
            maxAttempts: 5, baseDelay: 1.0, maxDelay: 60.0,
            multiplier: 2.0, jitterRatio: 0.5
        )
        for a in 1...5 {
            for r in [0.0, 0.25, 0.5, 0.75, 0.99] {
                let d = policy.delay(forAttempt: a, random: { r })!
                #expect(d >= 0, "attempt=\(a) r=\(r) delay=\(d)")
            }
        }
    }

    @Test("default policy は 5 attempts")
    func defaultPolicyAttempts() {
        #expect(RetryPolicy.default.maxAttempts == 5)
        #expect(RetryPolicy.default.delay(forAttempt: 5) != nil)
        #expect(RetryPolicy.default.delay(forAttempt: 6) == nil)
    }

    @Test("attempt=1 は必ず正の遅延 (baseDelay>0, jitterRatio<1)", arguments: [1, 2, 3, 4, 5])
    func parameterizedPositiveDelay(attempt: Int) {
        let policy = RetryPolicy.default
        for i in 0..<10 {
            let r = Double(i) / 10.0
            let d = policy.delay(forAttempt: attempt, random: { r })!
            #expect(d > 0, "attempt=\(attempt) r=\(r) delay=\(d)")
        }
    }
}
