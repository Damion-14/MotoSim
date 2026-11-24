import CryptoKit
import Foundation

enum SharedTrack {
    static let version = 2

    static func supportsVersion(_ value: Int) -> Bool { (1...version).contains(value) }
    static let maxBytes = 64 * 1024 * 1024

    enum Failure: LocalizedError {
        case invalid, incompatible, mismatch

        var errorDescription: String? {
            switch self {
            case .invalid: "The shared track package is invalid or too large."
            case .incompatible: "This track requires a newer version of MotoSim."
            case .mismatch: "The downloaded track does not match the host’s track."
            }
        }
    }

    // Fixed little-endian header makes identical imported terrain hash identically across devices.
    private static let magic = Data("MSTK".utf8)
    private static let headerBytes = 36
    private static let grassHeaderBytes = 36

    static func encode(_ track: Track) throws -> Data {
        guard let field = track.heightField,
              (2...HeightField.maxImportedSamplesPerAxis).contains(field.columns),
              (2...HeightField.maxImportedSamplesPerAxis).contains(field.rows) else { throw Failure.invalid }
        let art = track.groundArt
        let grass = track.grass
        guard grass?.isValid != false else { throw Failure.invalid }
        // Swift's supported Apple targets are little-endian. Append directly
        // from the UInt16 array to avoid a second full heightfield allocation.
        let bytesPerSample = MemoryLayout<UInt16>.size
        var data = magic
        let fields: [UInt32] = [UInt32(version), field.width.bitPattern, field.length.bitPattern,
                                field.elevationRange.bitPattern, UInt32(field.columns), UInt32(field.rows),
                                UInt32(art?.width ?? 0), UInt32(art?.height ?? 0)]
        data.append(fields.map { $0.littleEndian }.withUnsafeBytes { Data($0) })
        data.reserveCapacity(headerBytes + field.samples.count * bytesPerSample + (art?.pixels.count ?? 0))
        field.samples.withUnsafeBytes { data.append(contentsOf: $0) }
        if let art { data.append(art.pixels) }
        if let grass {
            let fields = [UInt32(grass.image.width), UInt32(grass.image.height),
                          UInt32(grass.maskWidth), UInt32(grass.maskHeight), grass.density.bitPattern,
                          grass.height.bitPattern, grass.heightVariation.bitPattern,
                          grass.width.bitPattern, grass.widthVariation.bitPattern]
            data.append(fields.map { $0.littleEndian }.withUnsafeBytes { Data($0) })
            data.append(grass.image.pixels)
            data.append(grass.mask)
        }
        guard data.count <= maxBytes else { throw Failure.invalid }
        return data
    }

    static func decode(_ data: Data, name: String) throws -> Track {
        guard (headerBytes...maxBytes).contains(data.count), data.starts(with: magic) else { throw Failure.invalid }
        let bytes = Data(data)
        let version = Int(bytes.le32(4))
        guard supportsVersion(version) else { throw Failure.incompatible }
        let width = Float(bitPattern: bytes.le32(8))
        let length = Float(bitPattern: bytes.le32(12))
        let elevationRange = Float(bitPattern: bytes.le32(16))
        let columns = Int(bytes.le32(20))
        let rows = Int(bytes.le32(24))
        let artWidth = Int(bytes.le32(28))
        let artHeight = Int(bytes.le32(32))
        guard (2...HeightField.maxImportedSamplesPerAxis).contains(columns),
              (2...HeightField.maxImportedSamplesPerAxis).contains(rows),
              (4...10_000).contains(width), (4...10_000).contains(length),
              (0...5_000).contains(elevationRange),
              (artWidth == 0 && artHeight == 0) ||
                ((1...2048).contains(artWidth) && (1...2048).contains(artHeight)) else { throw Failure.invalid }
        let artworkOffset = headerBytes + columns * rows * 2
        let grassOffset = artworkOffset + artWidth * artHeight * 4
        guard bytes.count >= grassOffset, version > 1 || bytes.count == grassOffset else { throw Failure.invalid }
        let samples = bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            stride(from: headerBytes, to: artworkOffset, by: 2).map { index in
                UInt16(buffer[index]) | UInt16(buffer[index + 1]) << 8
            }
        }
        let field = HeightField(columns: columns, rows: rows, width: width,
                                length: length, elevationRange: elevationRange, samples: samples)
        var track = Track(name: name, heightField: field)
        if artWidth > 0 {
            track.groundArt = TrackGroundArt(width: artWidth, height: artHeight,
                                            pixels: bytes.subdata(in: artworkOffset..<grassOffset))
        }
        if bytes.count > grassOffset {
            track.grass = try decodeGrass(bytes, at: grassOffset)
        }
        return track
    }

    private static func decodeGrass(_ bytes: Data, at offset: Int) throws -> TrackGrass {
        guard bytes.count - offset >= grassHeaderBytes else { throw Failure.invalid }
        let width = Int(bytes.le32(offset))
        let height = Int(bytes.le32(offset + 4))
        let maskWidth = Int(bytes.le32(offset + 8))
        let maskHeight = Int(bytes.le32(offset + 12))
        guard (1...TrackGrass.maxImageSide).contains(width), (1...TrackGrass.maxImageSide).contains(height),
              (1...TrackGrass.maxMaskSide).contains(maskWidth), (1...TrackGrass.maxMaskSide).contains(maskHeight)
        else { throw Failure.invalid }
        let imageStart = offset + grassHeaderBytes
        let maskStart = imageStart + width * height * 4
        guard bytes.count == maskStart + maskWidth * maskHeight else { throw Failure.invalid }
        func value(_ relative: Int) -> Float { Float(bitPattern: bytes.le32(offset + relative)) }
        let grass = TrackGrass(image: TrackGroundArt(width: width, height: height,
                                                     pixels: bytes.subdata(in: imageStart..<maskStart)),
                               maskWidth: maskWidth, maskHeight: maskHeight, mask: bytes.subdata(in: maskStart..<bytes.count),
                               density: value(16), height: value(20), heightVariation: value(24),
                               width: value(28), widthVariation: value(32))
        guard grass.isValid else { throw Failure.invalid }
        return grass
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
