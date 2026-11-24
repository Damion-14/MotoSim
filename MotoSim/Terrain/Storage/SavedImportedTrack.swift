import Foundation

enum SavedImportedTrack {
    private struct Metadata: Codable {
        let name: String
        let startPosition: SIMD3<Float>
        let startHeading: Float
        let courseLine: [SIMD2<Float>]
    }

    private static let magic = Data("MSL1".utf8)
    private static let headerSize = 8
    private static let metadataLimit = 4 * 1024 * 1024

    static let location = URL.applicationSupportDirectory
        .appending(path: "MotoSim", directoryHint: .isDirectory)
        .appending(path: "LastImportedTrack.mstk")

    static func save(_ track: Track, to file: URL) throws {
        let metadata = try JSONEncoder().encode(Metadata(name: track.name, startPosition: track.startPosition,
                                                         startHeading: track.startHeading, courseLine: track.courseLine))
        guard metadata.count <= metadataLimit else { throw SharedTrack.Failure.invalid }
        let package = try SharedTrack.encode(track)
        var data = magic
        data.reserveCapacity(headerSize + metadata.count + package.count)
        var length = UInt32(metadata.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(metadata)
        data.append(package)

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    static func load(from file: URL) throws -> Track? {
        let data: Data
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, (headerSize...headerSize + metadataLimit + SharedTrack.maxBytes).contains(size)
            else { throw SharedTrack.Failure.invalid }
            data = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard data.count >= headerSize, data.starts(with: magic) else { throw SharedTrack.Failure.invalid }
        let metadataSize = Int(data.le32(4))
        let packageStart = headerSize + metadataSize
        guard metadataSize <= metadataLimit, packageStart < data.count else { throw SharedTrack.Failure.invalid }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data.subdata(in: headerSize..<packageStart))
        var track = try SharedTrack.decode(data.subdata(in: packageStart..<data.count), name: metadata.name)
        guard track.contains(metadata.startPosition), metadata.startPosition.y.isFinite, metadata.startHeading.isFinite
        else { throw SharedTrack.Failure.invalid }
        track.startPosition = metadata.startPosition
        track.startHeading = metadata.startHeading
        track.courseLine = metadata.courseLine
        return track
    }
}
