import Testing
@testable import StreamEngine

@Suite("BackoffPolicy")
struct BackoffPolicyTests {
    @Test func defaultPolicyYieldsDoublingSequenceThenNil() {
        let policy = BackoffPolicy()
        #expect((1...5).map { policy.delay(forAttempt: $0) } == [1, 2, 4, 8, 16])
        #expect(policy.delay(forAttempt: 6) == nil)
    }

    @Test func attemptsBelowOneAreRejected() {
        let policy = BackoffPolicy()
        #expect(policy.delay(forAttempt: 0) == nil)
        #expect(policy.delay(forAttempt: -3) == nil)
    }

    @Test func delayIsClampedToMaxDelay() {
        let policy = BackoffPolicy(maxAttempts: 5, baseDelay: 8, multiplier: 4, maxDelay: 20)
        #expect(policy.delay(forAttempt: 1) == 8)
        #expect(policy.delay(forAttempt: 2) == 20)
        #expect(policy.delay(forAttempt: 5) == 20)
    }

    @Test func maxAttemptsBoundIsInclusive() {
        let policy = BackoffPolicy(maxAttempts: 3, baseDelay: 1, multiplier: 2, maxDelay: 30)
        #expect(policy.delay(forAttempt: 3) == 4)
        #expect(policy.delay(forAttempt: 4) == nil)
    }
}
