import simd
import XCTest
@testable import MotoSimPhysics

final class ArcadeHandlingTests: XCTestCase {
    func testRollingBikeTravelsWhereItPointsDuringATurn() {
        let track = testTrack()
        for steer: Float in [-0.75, 0.75] {
            var bike = rollingBike(on: track, speed: 12)
            for _ in 0..<120 {
                XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput(steer: steer, throttle: 0.4)))
            }
            let state = bike.state
            let travelHeading = atan2(state.velocity.x, state.velocity.z)
            XCTAssertGreaterThan(-steer * state.heading, 0.25)
            XCTAssertGreaterThan(-steer * state.position.x, 0.5)
            XCTAssertGreaterThan(steer * state.lean, 0.2)
            XCTAssertEqual(travelHeading, state.heading, accuracy: 0.10)
            XCTAssertGreaterThan(state.contacts, 0)
        }
    }

    func testAirControlsAimTheBikeWhilePreservingJumpMomentum() {
        let track = testTrack()
        var bike = rollingBike(on: track, speed: 12, height: 8)
        for _ in 0..<120 {
            XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput(steer: 1, weight: 1)))
        }
        let state = bike.state
        let travelHeading = atan2(state.velocity.x, state.velocity.z)
        XCTAssertEqual(state.contacts, 0)
        XCTAssertLessThan(state.heading, -0.60)
        XCTAssertGreaterThan(state.pitch, 0.40)
        XCTAssertGreaterThan(state.lean, 0.35)
        XCTAssertLessThan(travelHeading, -0.10)
        XCTAssertGreaterThan(travelHeading, -0.33)
        XCTAssertLessThan(state.velocity.y, -4)
    }

    func testBadLandingRightsTheBikeAndKeepsRiding() {
        let track = testTrack()
        for sign: Float in [-1, 1] {
            let rolling = rollingBike(on: track, speed: 10, height: 1)
            var initial = rolling.state
            initial.pitch = sign * 1.65
            initial.lean = sign * 1.45
            initial.velocity.y = -8
            var bike = Motorcycle(track: track, physicsMode: .arcade, initialState: initial)
            for _ in 0..<480 {
                XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput(throttle: 0.45)))
            }
            let state = bike.state
            XCTAssertEqual(state.contacts, 2)
            XCTAssertLessThan(abs(state.pitch), 0.10)
            XCTAssertLessThan(abs(state.lean), 0.10)
            XCTAssertGreaterThan(state.position.z, 10)
        }
    }

    func testHardLandingAbsorbsImpactWithoutAnotherHop() {
        for slope: Float in [0, -0.15] {
            let track = testTrack(slope: slope)
            var bike = rollingBike(on: track, speed: 6, height: 5, slope: slope)
            var touchedDown = false
            var airborneSteps = 0
            for _ in 0..<480 {
                XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput()))
                if bike.state.contacts > 0 { touchedDown = true }
                if touchedDown && bike.state.contacts == 0 { airborneSteps += 1 }
            }
            XCTAssertTrue(touchedDown)
            XCTAssertEqual(airborneSteps, 0, "Slope \(slope)")
            XCTAssertEqual(bike.state.contacts, 2)
        }
    }

    func testSwitchingPhysicsModePreservesTheRide() {
        var bike = rollingBike(on: testTrack(), speed: 10)
        XCTAssertFalse(bike.advance(0.1, input: RideInput(steer: 0.4)))
        let before = bike.state
        bike.setPhysicsMode(.simulation)
        XCTAssertEqual(bike.physicsMode, .simulation)
        XCTAssertEqual(bike.state.position, before.position)
        XCTAssertEqual(bike.state.velocity, before.velocity)
        XCTAssertEqual(bike.state.compression, before.compression)
        XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput()))
    }

    private func testTrack(slope: Float = 0) -> Track {
        Track(name: "Arcade handling", heightField: HeightField(columns: 2, rows: 2, width: 160, length: 160,
                                                               elevationRange: abs(slope) * 160,
                                                               samples: [.max, .max, 0, 0]))
    }

    private func rollingBike(on track: Track, speed: Float, height: Float = 0, slope: Float = 0) -> Motorcycle {
        let resting = Motorcycle(track: track, physicsMode: .arcade)
        var initial = resting.state
        initial.velocity = [0, slope * speed, speed]
        initial.wheelSpeed = [speed / resting.configuration.frontRadius, speed / resting.configuration.rearRadius]
        if height > 0 {
            initial.position.y += height
            initial.compression = .zero
            initial.contacts = 0
        }
        return Motorcycle(track: track, physicsMode: .arcade, initialState: initial)
    }
}
