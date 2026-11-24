import XCTest
@testable import MotoSimPhysics

final class LeanSteeringTests: XCTestCase {
    func testSameLeanAtHigherSpeedRequiresAWiderTurn() {
        let slow = LeanSteering(input: 0.6, speed: 10, wheelbase: 1.48)
        let fast = LeanSteering(input: 0.6, speed: 20, wheelbase: 1.48)
        let slowRadius = 1 / LeanSteering.equilibriumCurvature(lean: slow.targetLean, speed: 10)
        let fastRadius = 1 / LeanSteering.equilibriumCurvature(lean: fast.targetLean, speed: 20)

        XCTAssertEqual(fast.targetLean, slow.targetLean, accuracy: 0.0001)
        XCTAssertEqual(fastRadius, 4 * slowRadius, accuracy: 0.001)
        XCTAssertLessThan(abs(fast.baseSteering), abs(slow.baseSteering))
    }

    func testFullStickCanRequest48DegreesAtRidingSpeed() {
        let command = LeanSteering(input: 1, speed: 10, wheelbase: 1.48)
        let oldCurvature = LeanSteering.equilibriumCurvature(lean: 0.66, speed: 10)
        let newCurvature = LeanSteering.equilibriumCurvature(lean: command.targetLean, speed: 10)

        XCTAssertEqual(command.targetLean * 180 / .pi, 48, accuracy: 0.001)
        XCTAssertGreaterThan(newCurvature, oldCurvature)
    }

    func testFullStickAtRestSteersTheBarsWithAnUprightTarget() {
        let command = LeanSteering(input: 1, speed: 0, wheelbase: 1.48)
        XCTAssertEqual(command.targetLean, 0)
        XCTAssertEqual(command.baseSteering, -0.54, accuracy: 0.0001)
        XCTAssertEqual(command.countersteerBlend, 0)
    }
}
