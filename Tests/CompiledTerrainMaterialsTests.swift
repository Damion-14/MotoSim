import Foundation
import XCTest
import zlib
@testable import MotoSimPhysics

final class CompiledTerrainMaterialsTests: XCTestCase {
    func testCompositesAuthoredTexturesAndMasks() throws {
        var map = Data("MP2\0".utf8)
        append(304, to: &map)
        map.append(Data(repeating: 0, count: 100))
        append(2, to: &map)
        try layer("Dirt", rgba: [130, 80, 44, 255], into: &map)
        append(0, to: &map)
        append(0, to: &map)
        try layer("Grass", rgba: [50, 113, 30, 255], into: &map)
        append(1, to: &map)
        append(2, to: &map)
        append(2, to: &map)
        let mask = try deflated(Data([0, 255, 0, 128]))
        append(UInt32(mask.count + 8), to: &map)
        append(2, to: &map)
        append(0, to: &map)
        map.append(mask)
        map.append(Data(repeating: 0, count: 8))

        let art = try XCTUnwrap(CompiledTerrainMaterials.groundArt(in: map))
        XCTAssertEqual(art.width, 2)
        XCTAssertEqual(art.height, 2)
        XCTAssertEqual(Array(art.pixels), [130, 80, 44, 255, 50, 113, 30, 255,
                                          130, 80, 44, 255, 90, 97, 37, 255])
        XCTAssertNil(try CompiledTerrainMaterials.groundArt(in: Data(map.dropLast(12))))
        // Replace the no-grass flag with a density-mapped grass record.
        map.removeLast(4)
        append(1, to: &map)
        append(2, to: &map)
        for value: Float in [3, 0.8, 0.1, 0.5, 0.05] { append(value.bitPattern, to: &map) }
        append(1, to: &map)
        append(1, to: &map)
        let blade = try deflated(Data([20, 55, 12, 175]))
        append(UInt32(blade.count + 8), to: &map)
        map.append(Data(repeating: 0, count: 8))
        map.append(blade)
        append(0, to: &map)
        append(0, to: &map)
        append(2, to: &map)
        append(2, to: &map)
        map.append(contentsOf: [0, 255, 0, 255])
        let result = try XCTUnwrap(CompiledTerrainMaterials.load(in: map))
        let grass = try XCTUnwrap(result.grass)
        XCTAssertEqual(grass.image.pixels, Data([20, 55, 12, 175]))
        XCTAssertEqual(grass.mask, Data([0, 255, 0, 255]))

        let field = HeightField(columns: 2, rows: 2, width: 24, length: 24,
                                elevationRange: 0, samples: [0, 0, 0, 0])
        var track = Track(name: "Grass test", heightField: field)
        track.grass = grass
        let unpacked = try SharedTrack.decode(SharedTrack.encode(track), name: track.name)
        let shared = try XCTUnwrap(unpacked.grass)
        XCTAssertEqual(shared.image.pixels, grass.image.pixels)
        XCTAssertEqual(shared.mask, grass.mask)
        XCTAssertTrue(try shared.placements(field: field, cell: [-1, 0]).isEmpty)
        let placements = try shared.placements(field: field, cell: [0, 0])
        XCTAssertFalse(placements.isEmpty)
        XCTAssertEqual(placements, try grass.placements(field: field, cell: [0, 0]))

    }

    private func layer(_ name: String, rgba: [UInt8], into map: inout Data) throws {
        append(0, to: &map)
        for _ in 0..<6 { append(Float(1).bitPattern, to: &map) }
        for _ in 0..<7 { append(0, to: &map) }
        append(1, to: &map)

        map.append(contentsOf: name.utf8)
        map.append(Data(repeating: 0, count: 100 - name.utf8.count))
        append(0, to: &map)
        append(1, to: &map)
        append(1, to: &map)
        map.append(Data(repeating: 0, count: 20))
        let image = try deflated(Data(rgba))
        append(UInt32(image.count + 8), to: &map)
        map.append(Data(repeating: 0, count: 8))
        map.append(image)

        append(0, to: &map)
        append(Float(1).bitPattern, to: &map)
        append(Float(1).bitPattern, to: &map)
    }

    private func deflated(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: 128)
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = result.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(result.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw CocoaError(.fileWriteUnknown) }
        return Data(output.prefix(Int(stream.total_out)))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
