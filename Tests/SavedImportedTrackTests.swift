import XCTest
@testable import MotoSimPhysics

final class SavedImportedTrackTests: XCTestCase {
    func testSavedTrackRestoresTerrainArtworkAndStartAfterReplacingThePreviousSave() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "LastImportedTrack.mstk")
        XCTAssertNil(try SavedImportedTrack.load(from: file))

        let field = HeightField(columns: 2, rows: 2, width: 40, length: 55,
                                elevationRange: 8, samples: [1, 200, 30_000, .max])
        var track = Track(name: "Weekend Ride", heightField: field)
        track.groundArt = TrackGroundArt(width: 1, height: 1, pixels: Data([8, 32, 128, 255]))
        try SavedImportedTrack.save(track, to: file)

        track.startPosition = [4, 0, 10]
        track.startHeading = 2
        track.courseLine = [[0.4, 0.2], [0.7, 0.8]]
        try SavedImportedTrack.save(track, to: file)

        let restored = try XCTUnwrap(SavedImportedTrack.load(from: file))
        XCTAssertEqual(restored.name, track.name)
        XCTAssertEqual(restored.startPosition, track.startPosition)
        XCTAssertEqual(restored.startHeading, track.startHeading)
        XCTAssertEqual(restored.courseLine, track.courseLine)
        XCTAssertEqual(try SharedTrack.encode(restored), try SharedTrack.encode(track))

        try Data("truncated".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try SavedImportedTrack.load(from: file))
    }
}
