import XCTest
import simd
@testable import MotoSimPhysics

final class FreeRideTests: XCTestCase {
    func testSharedTrackPreservesTerrainAndArtworkAndIgnoresLocalNameAndStart() throws {
        let field = HeightField(columns: 2, rows: 2, width: 40, length: 55,
                                elevationRange: 8, samples: [1, 200, 30_000, .max])
        var local = Track(name: "Host track", heightField: field)
        local.groundArt = TrackGroundArt(width: 1, height: 1, pixels: Data([8, 32, 128, 255]))
        let data = try SharedTrack.encode(local)
        let guest = try SharedTrack.decode(data, name: "Host track")
        XCTAssertEqual(guest.heightField?.samples, field.samples)
        XCTAssertEqual(guest.height(6, -6), local.height(6, -6))
        XCTAssertEqual(guest.groundArt?.pixels, local.groundArt?.pixels)
        local.name = "Renamed copy"
        local.startPosition = [4, 0, 10]
        local.startHeading = 2
        XCTAssertEqual(try SharedTrack.encode(local), data)
        XCTAssertEqual(try SharedTrack.encode(guest), data)
        XCTAssertTrue(SharedTrack.validHash(SharedTrack.hash(data)))

        var different = Track(name: "Host track", heightField: field)
        different.groundArt = TrackGroundArt(width: 1, height: 1, pixels: Data([9, 32, 128, 255]))
        XCTAssertNotEqual(try SharedTrack.hash(SharedTrack.encode(different)), SharedTrack.hash(data))
        XCTAssertThrowsError(try SharedTrack.decode(data.dropLast(), name: "Broken"))
        var wrongVersion = data
        wrongVersion[4] = 2
        XCTAssertThrowsError(try SharedTrack.decode(wrongVersion, name: "Different version"))
    }

    func testStartingFormationFitsBesideHostAtTrackEdge() throws {
        let field = HeightField(columns: 2, rows: 2, width: 4, length: 4,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        let track = Track(name: "Edge", heightField: field)
        let start = RideStart(position: [1.98, -1.99], heading: .pi / 4)
        let positions = try (0..<4).map { try start.placed(track, slot: $0).startPosition }
        for index in positions.indices {
            XCTAssertTrue(track.contains(positions[index]))
            for other in positions.dropFirst(index + 1) {
                XCTAssertGreaterThan(simd_distance(positions[index], other), 1)
            }
        }
        XCTAssertThrowsError(try start.placed(track, slot: 4))
    }

    func testRemoteInterpolationSurvivesJitterDropoutAndRespawn() throws {
        func snapshot(_ x: Float, _ sequence: UInt32, generation: UInt32 = 0) -> RideSnapshot {
            var state = BikeState()
            state.position.x = x
            state.velocity.x = 10
            state.lean = 0.2
            state.steering = 0.3
            state.compression = [0.1, 0.2]
            return RideSnapshot(state, sequence: sequence, generation: generation)
        }
        let encoded = try JSONEncoder().encode(snapshot(0, 1))
        var motion = RemoteBikeMotion()
        motion.receive(try JSONDecoder().decode(RideSnapshot.self, from: encoded), at: 1)
        motion.receive(snapshot(2, 3), at: 1.08)
        motion.receive(snapshot(1, 2), at: 1.09)
        motion.receive(snapshot(4, 4), at: 1.18)
        let middle = try XCTUnwrap(motion.pose(at: 1.23))
        XCTAssertEqual(middle.position.x, 3, accuracy: 0.001)
        XCTAssertEqual(middle.lean, 0.2)
        XCTAssertEqual(middle.compression, [0.1, 0.2])
        XCTAssertEqual(motion.pose(at: 3)?.position.x, 4)
        motion.receive(snapshot(50, 6, generation: 1), at: 3)
        motion.receive(snapshot(100, 5), at: 3.02)
        motion.receive(snapshot(.infinity, 7, generation: 1), at: 3.03)
        XCTAssertEqual(motion.pose(at: 3.04)?.position.x, 50)
        XCTAssertEqual(motion.pose(at: 5)?.position.x, 50)
    }
}
