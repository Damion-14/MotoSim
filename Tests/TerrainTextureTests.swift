import Foundation
import XCTest
@testable import MotoSimPhysics

final class TerrainTextureTests: XCTestCase {
    func testSourceFolderUsesDryLayersAndAlphaMaskOverCollisionGeometry() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let geometry = """
        samples_x = 2
        samples_z = 2
        size_x = 20
        size_z = 20
        data = height.raw
        scale = 10
        """
        try geometry.write(to: folder.appending(path: "test.tht"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 8).write(to: folder.appending(path: "height.raw"))
        try """
        layer0 {
          map = dirt.tga
          repetitions = 2
          frame1 {
            map = wet.tga
          }
        }
        layer1 {
          map = grass.tga
          mask = mask.tga
        }
        """.write(to: folder.appending(path: "test.hmf"), atomically: true, encoding: .utf8)
        try tga(width: 2, bytes: [30, 80, 160, 255, 20, 55, 130, 255])
            .write(to: folder.appending(path: "dirt.tga"))
        try tga(width: 1, bytes: [30, 120, 50, 255], compressed: true)
            .write(to: folder.appending(path: "grass.tga"))
        try tga(width: 2, bytes: [255, 255, 255, 0, 0, 0, 0, 255])
            .write(to: folder.appending(path: "mask.tga"))

        let track = try MXTrackImporter.load(folder: folder)
        let art = try XCTUnwrap(track.groundArt)
        XCTAssertEqual(track.height(0, 0), 0)
        XCTAssertEqual(art.pixels[0], 160)
        XCTAssertEqual(art.pixels[art.width / 4 * 4], 130)
        XCTAssertEqual(art.pixels[art.width / 2 * 4], 50)
        XCTAssertEqual(art.pixels[art.width / 2 * 4 + 1], 120)

        let shared = try SharedTrack.decode(SharedTrack.encode(track), name: track.name)
        XCTAssertEqual(shared.groundArt?.pixels, art.pixels)
    }

    func testLockedFooterProducesSpecificImportError() {
        var archive = Data(repeating: 0, count: 128)
        archive.replaceSubrange(66..<70, with: "KCOL".utf8)
        XCTAssertThrowsError(try PKZArchive.trackFiles(in: archive, named: "Locked")) { error in
            guard case PKZArchive.ArchiveError.locked = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func tga(width: UInt8, bytes: [UInt8], compressed: Bool = false) -> Data {
        var header = Data(repeating: 0, count: 18)
        header[2] = compressed ? 10 : 2
        header[12] = width
        header[14] = 1
        header[16] = 32
        header[17] = 0x28
        if compressed { header.append(0x80 | (width - 1)) }
        header.append(contentsOf: bytes)
        return header
    }
}
