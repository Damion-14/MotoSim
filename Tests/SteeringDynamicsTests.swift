import XCTest
import simd
@testable import MotoSimPhysics

final class SteeringDynamicsTests: XCTestCase {
    func testLongJumpAlignsHeadingWithTravelWhileShortHopsKeepTheirYaw() {
        let field = HeightField(columns: 2, rows: 2, width: 120, length: 160,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        let track = Track(name: "Air Alignment Test", heightField: field)
        let state = BikeState(position: [0, 10, 0], velocity: [0, 0, 14], heading: 0.30)
        var bike = Motorcycle(track: track, initialState: state)
        for _ in 0..<60 {
            bike.advance(Motorcycle.stepSeconds, input: RideInput())
            XCTAssertEqual(bike.state.contacts, 0)
        }
        XCTAssertEqual(bike.state.heading, state.heading, accuracy: 0.0001)

        for _ in 0..<228 {
            bike.advance(Motorcycle.stepSeconds, input: RideInput())
            XCTAssertEqual(bike.state.contacts, 0)
        }
        XCTAssertLessThan(abs(bike.state.heading), 0.15)
        XCTAssertEqual(bike.state.velocity.x / bike.state.velocity.z, 0, accuracy: 0.0001)
    }

    func testAirborneRotationDoesNotRedirectHorizontalTravel() {
        let field = HeightField(columns: 2, rows: 2, width: 120, length: 160,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        let track = Track(name: "Airborne Heading Test", heightField: field)
        let state = BikeState(position: [0, 5, 0], velocity: [0.6, 0, 12],
                              heading: 0.24, lean: 0.15, yawRate: 0.5, wheelSpeed: [35, 36])
        var bike = Motorcycle(track: track, initialState: state)
        for _ in 0..<96 {
            XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput(throttle: 0.5)))
            XCTAssertEqual(bike.state.contacts, 0)
        }
        XCTAssertGreaterThan(abs(bike.state.heading - state.heading), 0.05)
        XCTAssertEqual(bike.state.velocity.x / bike.state.velocity.z, 0.05, accuracy: 0.0001)
    }

    func testHighSpeedNeutralSteeringSettlesWithoutContinuingToTurn() {
        let field = HeightField(columns: 2, rows: 2, width: 120, length: 240,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        let track = Track(name: "Straight Running Test", heightField: field)
        let configuration = BikeConfiguration()
        for speed: Float in [14, 22, 32] {
            var state = configuration.restingPose(on: track, at: .zero, heading: 0.4, tuning: RideTuning()).state
            state.velocity = state.orientation.act([0, 0, speed])
            state.wheelSpeed = [speed / configuration.frontRadius, speed / configuration.rearRadius]
            state.lean = 0.10
            state.steering = -0.035
            state.yawRate = 0.14
            var bike = Motorcycle(configuration: configuration, track: track, initialState: state)
            var lateYaw: Float = 0
            var lateBar: Float = 0
            var peakHeadingChange: Float = 0
            for step in 0..<480 {
                XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput()))
                peakHeadingChange = max(peakHeadingChange, abs(bike.state.heading - state.heading))
                if step >= 360 {
                    lateYaw = max(lateYaw, abs(bike.state.yawRate))
                    lateBar = max(lateBar, abs(bike.state.steering))
                }
            }
            XCTAssertLessThan(peakHeadingChange, 0.075)
            XCTAssertLessThan(lateYaw, 0.005)
            XCTAssertLessThan(lateBar, 0.005)

            let headingBeforeTurn = bike.state.heading
            for _ in 0..<120 {
                XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput(steer: 0.42)))
            }
            XCTAssertGreaterThan(bike.state.lean, 0.08)
            // The initial countersteer establishes lean before heading follows.
            for _ in 0..<180 {
                XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput(steer: 0.42)))
            }
            XCTAssertLessThan(bike.state.heading, headingBeforeTurn - 0.01)
        }
    }

    func testNeutralSteeringSettlesAfterAnOffAxisLanding() {
        let field = HeightField(columns: 2, rows: 2, width: 120, length: 160,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        let track = Track(name: "Landing Test", heightField: field)
        let state = BikeState(position: [0, 1.15, 0], velocity: [0.65, -3, 12],
                              pitch: -0.08, lean: 0.14, yawRate: 0.18,
                              wheelSpeed: [35, 36], steering: 0.08)
        var bike = Motorcycle(track: track, initialState: state)
        var landed = false
        var peakSteering: Float = 0
        var peakYawRate: Float = 0
        var lateSteering: Float = 0
        var lateYawRate: Float = 0
        for step in 0..<480 {
            bike.advance(Motorcycle.stepSeconds, input: RideInput())
            landed = landed || bike.state.contacts > 0
            if landed {
                peakSteering = max(peakSteering, abs(bike.state.steering))
                peakYawRate = max(peakYawRate, abs(bike.state.yawRate))
            }
            if step >= 360 {
                lateSteering = max(lateSteering, abs(bike.state.steering))
                lateYawRate = max(lateYawRate, abs(bike.state.yawRate))
            }
        }
        XCTAssertTrue(landed)
        XCTAssertEqual(bike.state.contacts, 2)
        XCTAssertLessThan(lateSteering, 0.25 * peakSteering)
        XCTAssertLessThan(lateYawRate, 0.25 * peakYawRate)
    }

    func testLeanedTiresUseGroundAtTheirContactOnTheBermShoulder() {
        let track = Track()
        let state = BikeState(position: [51, track.height(51, 0) + 0.70, 0], lean: 0.45)
        var bike = Motorcycle(track: track, initialState: state)
        bike.collectsTireTrace = true
        bike.advance(Motorcycle.stepSeconds, input: RideInput())

        for trace in [bike.frontTrace, bike.rearTrace] {
            XCTAssertGreaterThan(trace.load, 0)
            let patch = trace.contact
            let normal = track.normal(patch.x, patch.z)
            let penetration = (track.height(patch.x, patch.z) - patch.y) * normal.y
            XCTAssertEqual(trace.load, Suspension.tireRate * penetration, accuracy: 0.01)
            XCTAssertEqual(simd_dot(trace.forward, normal), 0, accuracy: 0.00001)
            let surface = track.tireSurface(patch.x, patch.z)
            XCTAssertEqual(trace.gripLimit, DirtTire.tractionLimit(load: trace.load, grip: surface.peakGrip),
                           accuracy: 0.01)
        }
    }

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
