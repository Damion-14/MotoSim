import XCTest
@testable import MotoSimPhysics

final class TireSurfaceTests: XCTestCase {
    func testDryGrassResistsSideSlipWhileAllowingLockedWheelSkids() {
        let grass = Track().tireSurface(0, 0)
        let rollingSideSlip = DirtTire.force(slip: 0, slipAngle: 0.04, camber: 0, load: 850, surface: grass)
        let nearPeak = DirtTire.force(slip: -0.175, slipAngle: 0, camber: 0, load: 850, surface: grass)
        let locked = DirtTire.force(slip: -1, slipAngle: 0, camber: 0, load: 850, surface: grass)

        XCTAssertLessThan(rollingSideSlip.y, -350)
        XCTAssertGreaterThan(abs(nearPeak.x), abs(locked.x))
        XCTAssertGreaterThan(grass.rollingResistance, 0)
    }

    func testShoulderBlendsBetweenDirtAndGrass() {
        let track = Track()
        let dirt = track.tireSurface(0, 31)
        let verge = track.tireSurface(0, 36)
        let grass = track.tireSurface(0, 40)

        XCTAssertEqual(dirt.peakGrip, TireSurface.trackDirt.peakGrip)
        XCTAssertEqual(grass.peakGrip, TireSurface.dryGrass.peakGrip)
        XCTAssertGreaterThan(verge.peakGrip, grass.peakGrip)
        XCTAssertLessThan(verge.peakGrip, dirt.peakGrip)
        XCTAssertGreaterThan(verge.rollingResistance, 0)
        XCTAssertLessThan(verge.rollingResistance, grass.rollingResistance)
    }
}
