import XCTest
import simd
@testable import MotoSimPhysics

final class TireTraceTests: XCTestCase {
    func testHardBrakingKeepsLoadedWheelsRollingAtSpeed() {
        var bike = Motorcycle()
        bike.collectsTireTrace = true
        for _ in 0..<180 { bike.advance(1 / 120, input: RideInput(throttle: 1)) }

        let front = bike.frontTrace
        XCTAssertGreaterThan(front.load, 0)
        XCTAssertGreaterThan(simd_dot(front.forward, front.patchTravel), 4)
        XCTAssertFalse(front.isLocked(brake: 1))

        var observedBraking = false
        for _ in 0..<48 {
            bike.advance(1 / 120, input: RideInput(brake: 1))
            for trace in [bike.frontTrace, bike.rearTrace] where trace.load > 0 && trace.forwardSpeed > 3 {
                XCTAssertFalse(trace.isLocked(brake: 1))
                observedBraking = observedBraking || simd_dot(trace.traction, trace.forward) < -100
            }
        }
        XCTAssertTrue(observedBraking)
    }

    func testTraceDetectsALockedWheel() {
        let locked = TireTrace(load: 850, forwardSpeed: 10, treadSpeed: 0)
        XCTAssertTrue(locked.isLocked(brake: 1))
        XCTAssertEqual(locked.slipRatio, -1)
    }

    func testFullThrottleAndBrakingOnLowGripDirt() {
        let field = HeightField(columns: 2, rows: 2, width: 120, length: 240,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        var tuning = RideTuning()
        tuning.tireGrip = 0.60
        var bike = Motorcycle(track: Track(name: "Low Grip Test", heightField: field), tuning: tuning)
        bike.collectsTireTrace = true
        var acceleratedUnderLoad = false
        for _ in 0..<480 {
            bike.advance(Motorcycle.stepSeconds, input: RideInput(throttle: 1))
            let rear = bike.rearTrace
            if rear.load > 0 && rear.forwardSpeed > 3 {
                XCTAssertLessThan(rear.slipRatio, 0.33)
                acceleratedUnderLoad = acceleratedUnderLoad || simd_dot(rear.traction, rear.forward) > 100
            }
        }
        XCTAssertTrue(acceleratedUnderLoad)
        XCTAssertGreaterThan(bike.state.velocity.z, 5)

        for _ in 0..<600 {
            bike.advance(Motorcycle.stepSeconds, input: RideInput(brake: 1))
            for trace in [bike.frontTrace, bike.rearTrace] where trace.load > 0 && trace.forwardSpeed > 3 {
                XCTAssertGreaterThan(trace.slipRatio, -0.35)
            }
        }
        XCTAssertLessThan(abs(bike.state.velocity.z), 0.15)
    }
}
