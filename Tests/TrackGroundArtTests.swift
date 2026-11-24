import Foundation
import XCTest
@testable import MotoSimPhysics

final class TrackGroundArtTests: XCTestCase {
    func testFallbackPaintsRouteAndGrassAtDifferentTerrainCoordinates() throws {
        var data = Data(repeating: 0, count: 32)
        append(0, to: &data)
        append(4, to: &data)
        for (x, z, dx, dz) in [(Float(20), Float(20), Float(1), Float(0)),
                                (80, 20, 0, 1), (80, 80, -1, 0), (20, 80, 0, -1)] {
            append(0, to: &data)
            for value: Float in [60, 0, 0, 0, 0, dx, dz, x, -dz, dx, z, 0, 0, 1] {
                append(value.bitPattern, to: &data)
            }
        }
        data.append(Data(repeating: 0, count: 64))
        append(0x00545845, to: &data)
        append(0, to: &data)

        let field = HeightField(columns: 2, rows: 2, width: 100, length: 100,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        let art = try XCTUnwrap(TrackGroundArt.make(terrain: data, artwork: nil, field: field))
        func red(_ x: Float, _ z: Float) -> UInt8 {
            let row = Int(z * Float(art.height - 1))
            let column = Int(x * Float(art.width - 1))
            return art.pixels[(row * art.width + column) * 4]
        }

        XCTAssertGreaterThan(red(0.5, 0.2), 140)
        XCTAssertLessThan(red(0.5, 0.5), 90)
        XCTAssertNil(TrackGroundArt.make(terrain: Data(data.dropLast()), artwork: nil, field: field))
    }

    private func append(_ number: UInt32, to data: inout Data) {
        var littleEndian = number.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
