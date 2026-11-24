import CryptoKit
import Foundation

enum SharedTrack {
    static let version = 1
    static let maxBytes = 32 * 1024 * 1024

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

    static func encode(_ track: Track) throws -> Data {
        guard let field = track.heightField else { throw Failure.invalid }
        let art = track.groundArt
        let samples = field.samples.map { $0.littleEndian }.withUnsafeBytes { Data($0) }
        var data = magic
        let fields: [UInt32] = [UInt32(version), field.width.bitPattern, field.length.bitPattern,
                                field.elevationRange.bitPattern, UInt32(field.columns), UInt32(field.rows),
                                UInt32(art?.width ?? 0), UInt32(art?.height ?? 0)]
        data.append(fields.map { $0.littleEndian }.withUnsafeBytes { Data($0) })
        data.append(samples)
        if let art { data.append(art.pixels) }
        guard data.count <= maxBytes else { throw Failure.invalid }
        return data
    }

    static func decode(_ data: Data, name: String) throws -> Track {
        guard (headerBytes...maxBytes).contains(data.count), data.starts(with: magic) else { throw Failure.invalid }
        let bytes = Data(data)
        guard bytes.le32(4) == version else { throw Failure.incompatible }
        let width = Float(bitPattern: bytes.le32(8))
        let length = Float(bitPattern: bytes.le32(12))
        let elevationRange = Float(bitPattern: bytes.le32(16))
        let columns = Int(bytes.le32(20))
        let rows = Int(bytes.le32(24))
        let artWidth = Int(bytes.le32(28))
        let artHeight = Int(bytes.le32(32))
        guard (2...1025).contains(columns), (2...1025).contains(rows),
              (4...10_000).contains(width), (4...10_000).contains(length),
              (0...5_000).contains(elevationRange),
              (artWidth == 0 && artHeight == 0) ||
                ((1...2048).contains(artWidth) && (1...2048).contains(artHeight)) else { throw Failure.invalid }
        let artworkOffset = headerBytes + columns * rows * 2
        guard bytes.count == artworkOffset + artWidth * artHeight * 4 else { throw Failure.invalid }
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
                                            pixels: bytes.subdata(in: artworkOffset..<bytes.count))
        }
        return track
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
