import XCTest
import simd
@testable import MotoSimPhysics

final class SuspensionTests: XCTestCase {
    func testKTMRearSagAndSetupAdjusters() {
        let c = BikeConfiguration()
        let defaults = RideTuning()
        let staticSag = c.rearSag(tuning: defaults, withRider: false)
        let riderSag = c.rearSag(tuning: defaults, withRider: true)
        XCTAssertEqual(c.fork.travel, 0.310)
        XCTAssertEqual(c.shock.travel, 0.300)
        XCTAssertEqual(riderSag, 0.105, accuracy: 0.005)
        XCTAssertEqual(staticSag, 0.046, accuracy: 0.003)
        XCTAssertLessThan(c.rearSag(tuning: RideTuning(shockPreload: 14), withRider: true), riderSag)

        let high = RideTuning(shockHighSpeedCompression: 2)
        let low = RideTuning(shockLowSpeedCompression: 2)
        let shock = c.shock
        XCTAssertEqual(shock.damperForce(at: 0.1, speed: 0.3, tuning: high),
                       shock.damperForce(at: 0.1, speed: 0.3, tuning: defaults))
        XCTAssertGreaterThan(shock.damperForce(at: 0.1, speed: 0.3, tuning: low),
                             shock.damperForce(at: 0.1, speed: 0.3, tuning: defaults))
        XCTAssertGreaterThan(shock.damperForce(at: 0.1, speed: 3, tuning: high),
                             shock.damperForce(at: 0.1, speed: 3, tuning: defaults))
    }

    func testForkSpringRateControlsForceAndSag() {
        let c = BikeConfiguration()
        let soft = RideTuning(forkSpringRate: 8)
        let firm = RideTuning(forkSpringRate: 16)
        XCTAssertEqual(c.fork.springForce(at: 0.10, tuning: soft) - c.fork.springForce(at: 0.05, tuning: soft),
                       400, accuracy: 0.01)
        XCTAssertEqual(c.fork.springForce(at: 0.10, tuning: firm) - c.fork.springForce(at: 0.05, tuning: firm),
                       800, accuracy: 0.01)
        XCTAssertGreaterThan(Motorcycle(tuning: soft).state.compression.x, Motorcycle(tuning: firm).state.compression.x)
        XCTAssertEqual(RideTuning(forkSpringRate: .nan).selectedForkSpringRate, RideTuning.defaultForkSpringRate)
    }

    func testFlatDropAndDownslopeTouchdownSettleAndRecordContact() throws {
        for slope: Float in [0, -0.15] {
            let bike = drop(slope: slope)
            let trace = bike.suspensionTrace
            let touchdown = try XCTUnwrap(trace.touchdownStep)
            let impact = trace.samples.filter { $0.step >= touchdown }
            XCTAssertEqual(trace.samples.count, 241)
            XCTAssertEqual(impact.first?.step, touchdown)
            XCTAssertEqual(trace.samples.first?.load, .zero)
            XCTAssertFalse(trace.isRecording)
            XCTAssertTrue(trace.csv.hasPrefix("time_s,front_travel_mm"))
            let peaks = SIMD2(impact.map(\.travel.x).max()!, impact.map(\.travel.y).max()!)
            let frontContact = impact.filter { $0.load.x > 0 }.count
            let rearContact = impact.filter { $0.load.y > 0 }.count
            XCTAssertGreaterThan(peaks.x, 0.10)
            XCTAssertGreaterThan(peaks.y, 0.16)
            XCTAssertLessThanOrEqual(peaks.x, bike.configuration.fork.travel)
            XCTAssertLessThanOrEqual(peaks.y, bike.configuration.shock.travel)
            XCTAssertGreaterThan(frontContact, 140)
            XCTAssertGreaterThan(rearContact, 140)
            XCTAssertEqual(bike.state.contacts, 2)
            let normal = bike.track.normal(bike.state.position.x, bike.state.position.z)
            XCTAssertLessThan(abs(simd_dot(bike.state.velocity, normal)), 0.05)
            XCTAssertLessThan(abs(bike.state.suspensionSpeed.x), 0.05)
            XCTAssertLessThan(abs(bike.state.suspensionSpeed.y), 0.05)
            XCTAssertLessThan(abs(bike.state.pitchRate), 0.05)
        }
    }

    func testCompressionAndReboundSettingsChangeLandingResponse() {
        let soft = drop(tuning: RideTuning(forkCompression: 0.5, shockHighSpeedCompression: 0.5))
        let firm = drop(tuning: RideTuning(forkCompression: 2, shockHighSpeedCompression: 2))
        XCTAssertGreaterThan(soft.suspensionTrace.samples.map(\.travel.x).max()!,
                             firm.suspensionTrace.samples.map(\.travel.x).max()!)
        XCTAssertGreaterThan(soft.suspensionTrace.samples.map(\.travel.y).max()!,
                             firm.suspensionTrace.samples.map(\.travel.y).max()!)

        let fast = drop(tuning: RideTuning(forkRebound: 0.5, shockRebound: 0.5))
        let slow = drop(tuning: RideTuning(forkRebound: 2, shockRebound: 2))
        XCTAssertLessThan(fast.suspensionTrace.samples.filter { $0.load.x > 0 }.map(\.speed.x).min()!,
                          slow.suspensionTrace.samples.filter { $0.load.x > 0 }.map(\.speed.x).min()!)
        XCTAssertLessThan(fast.suspensionTrace.samples.filter { $0.load.y > 0 }.map(\.speed.y).min()!,
                          slow.suspensionTrace.samples.filter { $0.load.y > 0 }.map(\.speed.y).min()!)
    }

    func testReboundCanPackTheShockAcrossWhoops() {
        let length: Float = 40
        let rows = 401
        let samples = (0..<rows).flatMap { row -> [UInt16] in
            let z = Float(row) * length / Float(rows - 1) - length / 2
            let elevation: Float = z >= 0 && z <= 10 ? (1 - cos(z * .pi)) / 2 : 0
            let sample = UInt16((elevation * 65_535).rounded())
            return [sample, sample]
        }
        let field = HeightField(columns: 2, rows: rows, width: 20, length: length,
                                elevationRange: 0.20, samples: samples)
        var track = Track(name: "Whoops", heightField: field)
        track.startPosition.z = -3

        func valleyTravel(rebound: Double) -> [Float] {
            let tuning = RideTuning(shockRebound: rebound)
            let resting = Motorcycle(track: track, tuning: tuning)
            var initial = resting.state
            initial.velocity.z = 8
            initial.wheelSpeed = [8 / resting.configuration.frontRadius, 8 / resting.configuration.rearRadius]
            var bike = Motorcycle(track: track, tuning: tuning, initialState: initial)
            return [2, 4, 6, 8].map { valley in
                var minimum = Float.infinity
                while bike.state.position.z < Float(valley) + 1 && bike.state.velocity.z > 1 {
                    if bike.state.position.z > Float(valley) + 0.5 {
                        minimum = min(minimum, bike.state.compression.y)
                    }
                    if bike.advance(Motorcycle.stepSeconds, input: RideInput(throttle: 0.2)) {
                        XCTFail("Crash in whoops")
                        break
                    }
                }
                XCTAssertTrue(minimum.isFinite)
                return minimum
            }
        }

        let fast = valleyTravel(rebound: 0.5)
        let slow = valleyTravel(rebound: 2)
        XCTAssertGreaterThan(slow.dropFirst().reduce(0, +), fast.dropFirst().reduce(0, +) + 0.03)
    }

    func testHardLandingRecordsBottomOutOncePerEndStopVisit() {
        let bike = drop(tuning: RideTuning(forkCompression: 0.5, shockHighSpeedCompression: 0.5), height: 2.2)
        XCTAssertEqual(bike.bottomOutCount.y, 1)
        XCTAssertTrue(bike.suspensionTrace.samples.contains {
            $0.bottomOuts.y == 1 && $0.travel.y == bike.configuration.shock.travel
        })
    }

    private func drop(slope: Float = 0, tuning: RideTuning = RideTuning(), height: Float = 0.45) -> Motorcycle {
        let uphill: [UInt16] = slope <= 0 ? [.max, .max, 0, 0] : [0, 0, .max, .max]
        let field = HeightField(columns: 2, rows: 2, width: 40, length: 80,
                                elevationRange: abs(slope) * 80, samples: uphill)
        let track = Track(name: "Landing", heightField: field)
        let resting = Motorcycle(track: track, tuning: tuning)
        var initial = resting.state
        initial.position.y += height
        initial.velocity = slope == 0 ? .zero : [0, slope * 6, 6]
        initial.compression = .zero
        initial.contacts = 0
        initial.wheelSpeed = slope == 0 ? .zero : [6 / resting.configuration.frontRadius, 6 / resting.configuration.rearRadius]
        var bike = Motorcycle(track: track, tuning: tuning, initialState: initial)
        bike.collectsTireTrace = true
        for _ in 0..<480 {
            XCTAssertFalse(bike.advance(Motorcycle.stepSeconds, input: RideInput()))
        }
        return bike
    }
}
