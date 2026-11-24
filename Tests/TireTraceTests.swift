import XCTest
import simd
@testable import MotoSimPhysics

final class TireTraceTests: XCTestCase {
    func testTraceDistinguishesRollingFromLockedWheelsUnderBraking() {
        var bike = Motorcycle()
        bike.collectsTireTrace = true
        for _ in 0..<180 { bike.advance(1 / 120, input: RideInput(throttle: 1)) }

        let front = bike.frontTrace
        XCTAssertGreaterThan(front.load, 0)
        XCTAssertGreaterThan(simd_dot(front.forward, front.patchTravel), 4)
        XCTAssertFalse(front.isLocked(brake: 1))

        var observedLock = false
        for _ in 0..<48 {
            bike.advance(1 / 120, input: RideInput(brake: 1))
            for trace in [bike.frontTrace, bike.rearTrace] where trace.isLocked(brake: 1) {
                observedLock = true
                XCTAssertLessThan(trace.slipRatio, -0.85)
                XCTAssertLessThan(simd_dot(trace.traction, trace.forward), 0)
            }
        }
        XCTAssertTrue(observedLock)
    }
}
