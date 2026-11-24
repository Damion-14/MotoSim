import XCTest
import simd
@testable import MotoSimPhysics

final class SteeringDynamicsTests: XCTestCase {
    func testCamberThrustActsIntoTheLeanForBothWheels() {
        for lean: Float in [-0.35, 0.35] {
            let orientation = simd_quatf(angle: lean, axis: [0, 0, 1])
            let frame = TireContactFrame(wheel: orientation, normal: [0, 1, 0])
            let force = DirtTire.force(slip: 0, slipAngle: 0, camber: frame.camber,
                                       load: 850, surface: .trackDirt)
            let leanedSide = orientation.act([0, 1, 0])
            XCTAssertGreaterThan(simd_dot(frame.lateral * force.y, leanedSide), 5)
        }
    }

    func testRollingDirectionLiesInBothTheWheelAndSlopedGroundPlanes() {
        let orientation = simd_quatf(angle: 0.36, axis: [0, 0, 1])
            * simd_quatf(angle: -0.20, axis: [1, 0, 0])
        let normal = simd_normalize(SIMD3<Float>(0.15, 1, 0.3))
        let frame = TireContactFrame(wheel: orientation, normal: normal)
        XCTAssertEqual(simd_dot(frame.forward, normal), 0, accuracy: 0.0001)
        XCTAssertEqual(simd_dot(frame.forward, orientation.act([1, 0, 0])), 0, accuracy: 0.0001)
    }

    func testAtRidingSpeedTheForkCountersteersBeforeTheBikeTurns() {
        let field = HeightField(columns: 2, rows: 2, width: 120, length: 160,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        var bike = Motorcycle(track: Track(name: "Handling Test", heightField: field))
        for _ in 0..<360 { bike.advance(1 / 120, input: RideInput(throttle: 0.85)) }
        XCTAssertGreaterThan(bike.state.velocity.z, 8)

        for _ in 0..<12 { bike.advance(1 / 120, input: RideInput(steer: 0.42, throttle: 0.3)) }
        // A brief left bar angle initiates a right lean.
        XCTAssertGreaterThan(bike.state.steering, 0.01)
        XCTAssertGreaterThan(bike.state.lean, 0.01)

        for _ in 0..<120 { bike.advance(1 / 120, input: RideInput(steer: 0.42, throttle: 0.3)) }
        XCTAssertLessThan(bike.state.heading, -0.05)
        XCTAssertLessThan(bike.state.steering, 0)
        XCTAssertGreaterThan(bike.state.lean, 0.08)
    }
}
