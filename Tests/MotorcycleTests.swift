import XCTest
import simd
@testable import MotoSimPhysics

final class MotorcycleTests: XCTestCase {
    private var unitGripDirt: TireSurface {
        var surface = TireSurface.trackDirt
        surface.peakGrip = 1
        return surface
    }
    func testBikeSettlesWithBothWheelsLoaded() {
        var bike = Motorcycle()
        for _ in 0..<240 { bike.advance(1 / 60, input: RideInput()) }
        XCTAssertEqual(bike.state.contacts, 2)
        XCTAssertEqual(simd_length(bike.state.velocity), 0, accuracy: 0.2)
        XCTAssertTrue((0.015...0.07).contains(bike.state.compression.x))
        XCTAssertEqual(bike.state.compression.y, 0.105, accuracy: 0.005)
    }

    func testThrottleAndBrakeChangeSpeed() {
        var bike = Motorcycle()
        for _ in 0..<120 { bike.advance(1 / 60, input: RideInput(throttle: 1)) }
        let movingSpeed = simd_length(bike.state.velocity)
        XCTAssertGreaterThan(movingSpeed, 5)
        for _ in 0..<90 { bike.advance(1 / 60, input: RideInput(brake: 1)) }
        XCTAssertLessThan(simd_length(bike.state.velocity), movingSpeed * 0.35)
    }

    func testRearwardWeightAndThrottleCanLiftTheFrontWheel() {
        var neutral = Motorcycle()
        var wheelie = Motorcycle()
        wheelie.collectsTireTrace = true
        for _ in 0..<155 {
            neutral.advance(1 / 120, input: RideInput(throttle: 1))
            wheelie.advance(1 / 120, input: RideInput(throttle: 1, weight: -1))
        }

        XCTAssertEqual(neutral.state.contacts, 2)
        XCTAssertGreaterThan(neutral.state.compression.x, 0)
        XCTAssertEqual(wheelie.state.contacts, 1)
        XCTAssertEqual(wheelie.frontTrace.load, 0)
        XCTAssertLessThan(wheelie.state.compression.x, 0.012)
        XCTAssertGreaterThan(wheelie.state.compression.y, 0)
        XCTAssertLessThan(wheelie.state.pitch, -0.15)

        for _ in 0..<50 {
            wheelie.advance(1 / 120, input: RideInput())
        }
        XCTAssertGreaterThan(wheelie.state.position.x, 2)
        XCTAssertEqual(wheelie.state.contacts, 2)
        XCTAssertGreaterThan(wheelie.state.compression.x, 0)
    }

    func testRiderCanShiftLaterallyWithTheStickCentered() {
        var bike = Motorcycle()
        for _ in 0..<30 {
            bike.advance(1 / 120, input: RideInput(lateralWeight: 1))
        }
        let state = bike.state
        let center = bike.configuration.centerOfMass(weight: state.riderWeight, lateral: state.riderLateralWeight)
        XCTAssertGreaterThan(state.riderLateralWeight, 0.7)
        XCTAssertLessThan(center.x, 0)
        XCTAssertGreaterThan(state.lean, 0.01)
        XCTAssertLessThan(abs(state.steering), 0.06)
        XCTAssertEqual(state.riderWeight, 0)

        for _ in 0..<60 { bike.advance(1 / 120, input: RideInput()) }
        XCTAssertLessThan(abs(bike.state.riderLateralWeight), 0.03)
    }

    func testLeavingTerrainRewindsToARecentUprightPoint() throws {
        let heightField = HeightField(columns: 2, rows: 2, width: 30, length: 50,
                                      elevationRange: 0, samples: [0, 0, 0, 0])
        var track = Track(name: "Recovery Course", heightField: heightField)
        track.startHeading = 0.1
        var bike = Motorcycle(track: track)
        var positions = [bike.state.position]
        var crashFrame: Int?
        for frame in 1...720 {
            if bike.advance(1 / 120, input: RideInput(throttle: 1)) {
                crashFrame = frame
                break
            }
            positions.append(bike.state.position)
        }
        let frame = try XCTUnwrap(crashFrame)
        XCTAssertGreaterThan(frame, 240)
        let beforeCrash = positions[max(0, frame - 240)]
        XCTAssertEqual(bike.state.position.z, beforeCrash.z, accuracy: 1.0)
        XCTAssertGreaterThan(bike.state.position.z, 1)
        XCTAssertEqual(bike.state.heading, track.startHeading, accuracy: 0.03)
        XCTAssertEqual(bike.state.velocity, .zero)
        XCTAssertEqual(bike.pose.position, bike.state.position)
        XCTAssertEqual(bike.state.contacts, 2)
    }

    func testFixedStepsAgreeAcrossFrameRates() {
        var sixty = Motorcycle()
        var oneTwenty = Motorcycle()
        let input = RideInput(steer: 0.32, throttle: 0.8)
        for _ in 0..<120 { sixty.advance(1 / 60, input: input) }
        for _ in 0..<240 { oneTwenty.advance(1 / 120, input: input) }
        XCTAssertEqual(simd_distance(sixty.state.position, oneTwenty.state.position), 0, accuracy: 0.0001)
    }

    func testSteeringFollowsTheRidersLeftAndRight() {
        var left = Motorcycle()
        var right = Motorcycle()
        for _ in 0..<120 {
            left.advance(1 / 60, input: RideInput(steer: -0.32, throttle: 0.8))
            right.advance(1 / 60, input: RideInput(steer: 0.32, throttle: 0.8))
        }

        let spawnForward = SIMD3<Float>(sin(Track.spawnHeading), 0, cos(Track.spawnHeading))
        let riderRight = simd_cross(spawnForward, SIMD3<Float>(0, 1, 0))
        XCTAssertGreaterThan(simd_dot(right.state.position - Track.spawn, riderRight), 0.1)
        XCTAssertLessThan(simd_dot(left.state.position - Track.spawn, riderRight), -0.1)
        XCTAssertGreaterThan(right.state.lean, 0)
        XCTAssertLessThan(left.state.lean, 0)
    }

    func testLateralAndLongitudinalGripShareTheSameLimit() {
        let pureCornering = DirtTire.force(slip: 0, slipAngle: 0.13, camber: 0, load: 850, surface: unitGripDirt)
        let brakingInTurn = DirtTire.force(slip: -0.17, slipAngle: 0.13, camber: 0, load: 850, surface: unitGripDirt)
        XCTAssertLessThan(abs(brakingInTurn.y), abs(pureCornering.y))
        XCTAssertLessThanOrEqual(simd_length(brakingInTurn), 850)
        XCTAssertLessThan(brakingInTurn.x, 0)
    }

    func testRollingTireOpposesSmallSideSlipAndKeepsTractionInASlide() {
        let smallSlip = DirtTire.force(slip: 0, slipAngle: 0.03, camber: 0, load: 850, surface: unitGripDirt)
        let broadslide = DirtTire.force(slip: 0, slipAngle: 0.60, camber: 0, load: 850, surface: unitGripDirt)
        XCTAssertLessThan(smallSlip.y, -220)
        XCTAssertLessThan(broadslide.y, -700)
        XCTAssertGreaterThanOrEqual(broadslide.y, -850)
    }

    func testTireLosesLongitudinalGripAfterPeakSlip() {
        let peak = DirtTire.force(slip: 0.175, slipAngle: 0, camber: 0, load: 850, surface: unitGripDirt)
        let spinning = DirtTire.force(slip: 0.65, slipAngle: 0, camber: 0, load: 850, surface: unitGripDirt)
        XCTAssertLessThan(spinning.x, peak.x * 0.85)
    }

    func testFirstJumpLosesAndRegainsWheelContact() {
        var bike = Motorcycle()
        var flew = false
        var landed = false
        for _ in 0..<540 {
            let position = bike.state.position
            let angle = bike.track.coordinates(position.x, position.z).angle
            let target = SIMD2<Float>(45 * sin(angle + 0.13), 31 * cos(angle + 0.13))
            let headingError = atan2(target.x - position.x, target.y - position.z) - bike.state.heading
            let steer = min(1, max(-1, -2.5 * atan2(sin(headingError), cos(headingError))))
            bike.advance(1 / 120, input: RideInput(steer: steer, throttle: 1))
            if bike.state.contacts == 0 && !flew {
                flew = true
                var underThrottle = bike
                var underBrake = bike
                underThrottle.advance(Motorcycle.stepSeconds, input: RideInput(throttle: 1))
                underBrake.advance(Motorcycle.stepSeconds, input: RideInput(brake: 1))
                XCTAssertLessThan(underThrottle.state.pitchRate, underBrake.state.pitchRate)
            }
            if flew && bike.state.contacts == 2 && bike.state.position.x > 10 { landed = true }
        }
        XCTAssertTrue(flew)
        XCTAssertTrue(landed)
    }
}
