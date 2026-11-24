import Foundation
import XCTest
@testable import MotoSimPhysics

final class MXTrackImporterTests: XCTestCase {
    func testImportsRectangularRAWAtItsAuthoredScaleAndUsesItForSpawn() throws {
        try withFolder { folder in
            try descriptor().write(to: folder.appending(path: "test.hmf"), atomically: true, encoding: .utf8)
            try writeRAW([0, 0, 0, 0, .max, 0], to: folder.appending(path: "height field.raw"))
            var track = try MXTrackImporter.load(folder: folder)
            let heightField = try XCTUnwrap(track.heightField)

            XCTAssertEqual(heightField.columns, 3)
            XCTAssertEqual(heightField.rows, 2)
            XCTAssertEqual(heightField.width, 80)
            XCTAssertEqual(heightField.length, 40)
            XCTAssertEqual(track.height(0, 20), 12, accuracy: 0.001)
            XCTAssertEqual(track.height(-20, 0), 0, accuracy: 0.001)
            XCTAssertEqual(track.height(-10, 10), 6, accuracy: 0.001)
            XCTAssertFalse(track.contains([0, 0, 21]))
            track.startPosition = [-10, 0, 10]
            track.startHeading = 0.5
            let bike = Motorcycle(track: track)
            XCTAssertEqual(bike.state.position.x, -10)
            XCTAssertGreaterThan(bike.state.position.y, 6)
            XCTAssertEqual(bike.state.heading, 0.5)
        }
    }

    func testUsesTHTWhenBothSourceDescriptorsExist() throws {
        try withFolder { folder in
            try descriptor(raw: "missing.raw").write(to: folder.appending(path: "test.hmf"), atomically: true, encoding: .utf8)
            try descriptor().write(to: folder.appending(path: "test.tht"), atomically: true, encoding: .utf8)
            try writeRAW(Array(repeating: 500, count: 6), to: folder.appending(path: "height field.raw"))
            XCTAssertEqual(try MXTrackImporter.load(folder: folder).heightField?.samples.first, 500)
        }
    }

    func testReportsTruncatedRAWAndCompiledTrack() throws {
        try withFolder { folder in
            try Data().write(to: folder.appending(path: "test.trp"))
            XCTAssertThrowsError(try MXTrackImporter.load(folder: folder)) {
                guard case MXTrackImporter.ImportError.compiledTrackOnly = $0 else {
                    return XCTFail("Unexpected error \($0)")
                }
            }

            try descriptor().write(to: folder.appending(path: "test.tht"), atomically: true, encoding: .utf8)
            try writeRAW([0, 1], to: folder.appending(path: "height field.raw"))
            XCTAssertThrowsError(try MXTrackImporter.load(folder: folder)) {
                guard case MXTrackImporter.ImportError.invalidHeightmapSize(12) = $0 else {
                    return XCTFail("Unexpected error \($0)")
                }
            }
        }
    }

    func testReadsDeflatedCompiledTerrainDirectlyFromPKZ() throws {
        try withFolder { folder in
            let url = folder.appending(path: "track.pkz")
            try archiveFixture().write(to: url)
            let track = try MXTrackImporter.load(file: url)
            XCTAssertEqual(track.heightField?.width, 32)
            XCTAssertEqual(track.heightField?.length, 20)
            XCTAssertEqual(track.height(-16, -10), 0, accuracy: 0.001)
            XCTAssertEqual(track.height(16, -10), 7, accuracy: 0.001)
            XCTAssertEqual(track.height(-16, 10), 10.5, accuracy: 0.001)
            XCTAssertEqual(track.height(16, 10), 14, accuracy: 0.001)
        }
    }

    func testRejectsTruncatedAndEncryptedArchives() throws {
        var archive = try archiveFixture()
        XCTAssertThrowsError(try PKZArchive.trackFiles(in: Data(archive.dropLast()), named: "track"))
        let directory = Int(archive.le32(archive.count - 22 + 16))
        archive[directory + 8] |= 1
        XCTAssertThrowsError(try PKZArchive.trackFiles(in: archive, named: "track")) {
            guard case PKZArchive.ArchiveError.locked = $0 else { return XCTFail("Unexpected archive error") }
        }
    }

    func testImportedSpawnFollowsAnUphillGrade() {
        let field = HeightField(columns: 2, rows: 2, width: 20, length: 20,
                                elevationRange: 8, samples: [0, 0, .max, .max])
        let track = Track(name: "Slope", heightField: field)
        let bike = Motorcycle(track: track)
        XCTAssertLessThan(bike.state.pitch, -0.30)
        XCTAssertGreaterThan(bike.state.position.y, track.height(0, 0))
        XCTAssertGreaterThan(bike.suspensionLoad.x, 0)
        XCTAssertLessThan(bike.state.compression.x, bike.configuration.fork.travel)
        XCTAssertGreaterThan(bike.suspensionLoad.y, 0)
        XCTAssertLessThan(bike.state.compression.y, bike.configuration.shock.travel)
    }

    func testChaseCameraClearsARidgeBetweenTheCameraAndBike() {
        let field = HeightField(columns: 2, rows: 3, width: 10, length: 10,
                                elevationRange: 3, samples: [0, 0, .max, .max, 0, 0])
        let track = Track(name: "Ridge", heightField: field)
        let focus: SIMD3<Float> = [0, 1.2, 5]
        let camera: SIMD3<Float> = [0, 2, -5]
        let safeY = track.minimumCameraHeight(from: camera, lookingAt: focus)

        XCTAssertGreaterThan((safeY + focus.y) / 2, track.height(0, 0) + 0.30)
    }

    private func archiveFixture() throws -> Data {
        // ZIP containing one DEFLATE-compressed 2 × 2 signed TRH heightfield.
        try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIAHO1d13HWsvGHAAAACAAAAAPAAAAdHJhY2svdHJhY2sudHJoCwnyYGBiYABjhgYgdvhfDySdGBgSHBkYFjgCAFBLAQIUAxQAAAAIAHO1d13HWsvGHAAAACAAAAAPAAAAAAAAAAAAAACAAQAAAAB0cmFjay90cmFjay50cmhQSwUGAAAAAAEAAQA9AAAASQAAAAAA"))
    }

    private func descriptor(raw: String = "height field.raw") -> String {
        """
        samples_x = 3
        samples_z = 2
        data = "\(raw)"
        size_x = 80
        size_z = 40
        scale = 12
        """
    }

    private func writeRAW(_ values: [UInt16], to url: URL) throws {
        let bytes = values.flatMap { value in [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)] }
        try Data(bytes).write(to: url)
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }
}
