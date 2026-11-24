import XCTest
@testable import MotoSimPhysics

final class RevLimiterTests: XCTestCase {
    func testCutsAtRedlineAndWaitsForBothMinimumCutAndLowerRPM() {
        let step: Float = 1 / 240
        var limiter = RevLimiter()

        limiter.update(rpm: 13_400, throttle: 1, dt: step)
        XCTAssertFalse(limiter.cutsIgnition)
        limiter.update(rpm: 13_500, throttle: 1, dt: step)
        XCTAssertTrue(limiter.cutsIgnition)
        limiter.update(rpm: 13_000, throttle: 1, dt: step)
        XCTAssertTrue(limiter.cutsIgnition)
        for _ in 0..<8 { limiter.update(rpm: 13_300, throttle: 1, dt: step) }
        XCTAssertTrue(limiter.cutsIgnition)
        limiter.update(rpm: 13_100, throttle: 1, dt: step)
        XCTAssertFalse(limiter.cutsIgnition)
    }

    func testClosedThrottleDoesNotStartAnIgnitionCut() {
        var limiter = RevLimiter()
        limiter.update(rpm: 13_700, throttle: 0, dt: 1 / 240)
        XCTAssertFalse(limiter.cutsIgnition)
    }
}
