import XCTest
@testable import Kaddo

final class AgentDesignLimiterTests: XCTestCase {
    func testCancelledQueuedDesignDoesNotConsumeSlot() async throws {
        let limiter = AgentDesignLimiter(limit: 2)
        try await limiter.acquire()
        try await limiter.acquire()
        let queued = Task { try await limiter.acquire() }
        try await Task.sleep(nanoseconds: 60_000_000)
        let active = await limiter.active
        XCTAssertEqual(active, 2)
        queued.cancel()
        do { try await queued.value; XCTFail("Queued design should cancel") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await limiter.release()
        try await limiter.acquire()
        let after = await limiter.active
        XCTAssertEqual(after, 2)
        await limiter.release(); await limiter.release()
    }
}
