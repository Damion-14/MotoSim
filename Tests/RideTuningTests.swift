import XCTest
import simd
@testable import MotoSimPhysics

final class RideTuningTests: XCTestCase {
    func testMaximumLeanSettingFeedsTheSteeringCommand() {
        let tuning = RideTuning(maximumLeanDegrees: 55)
        let command = LeanSteering(input: 1, speed: 12, wheelbase: 1.48, maximumLean: tuning.maximumLeanRadians)
        XCTAssertEqual(command.targetLean * 180 / .pi, 55, accuracy: 0.001)
    }

    func testForkAndShockReboundChangeOnlyTheirExtensionDamping() {
        let bike = BikeConfiguration()
        let tuning = RideTuning(forkRebound: 1.5, shockRebound: 0.75)
        let baseline = RideTuning()
        for (suspension, scale) in [(bike.fork, Float(1.5)), (bike.shock, Float(0.75))] {
            XCTAssertEqual(suspension.damperForce(at: 0.1, speed: -1, tuning: tuning),
                           scale * suspension.damperForce(at: 0.1, speed: -1, tuning: baseline),
                           accuracy: 0.001)
            XCTAssertEqual(suspension.damperForce(at: 0.1, speed: 1, tuning: tuning),
                           suspension.damperForce(at: 0.1, speed: 1, tuning: baseline))
        }
    }

    func testGripSettingAffectsBrakingInTheSimulation() {
        var bike = Motorcycle()
        for _ in 0..<160 { bike.advance(1 / 120, input: RideInput(throttle: 1)) }
        var lowerGrip = bike
        var higherGrip = bike
        lowerGrip.tuning.tireGrip = 0.6
        higherGrip.tuning.tireGrip = 1.25
        for _ in 0..<48 {
            lowerGrip.advance(1 / 120, input: RideInput(brake: 1))
            higherGrip.advance(1 / 120, input: RideInput(brake: 1))
        }
        XCTAssertGreaterThan(simd_length(lowerGrip.state.velocity), simd_length(higherGrip.state.velocity) + 0.5)
    }
}
