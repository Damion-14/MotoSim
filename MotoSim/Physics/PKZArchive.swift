import Foundation
import zlib

enum PKZArchive {
    enum ArchiveError: LocalizedError {
        case invalid, locked, unsupported, missingTerrain, multipleTerrains

        var errorDescription: String? {
            switch self {
            case .invalid: "The PKZ archive is incomplete or invalid."
            case .locked: "The track terrain in this PKZ is encrypted. Choose an unlocked copy."
            case .unsupported: "This PKZ uses an archive feature MotoSim cannot read."
            case .missingTerrain: "The PKZ has no supported terrain heightfield (.trh). Mesh-only tracks are currently unsupported."
            case .multipleTerrains: "MotoSim couldn’t identify the main terrain in this PKZ."
            }
        }
    }

    private struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let offset: Int

        var depth: Int { name.split(separator: "/").count }
        var stem: String { ((name as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    static func trackFiles(in archive: Data, named name: String) throws -> (terrain: Data, artwork: Data?) {
        guard archive.count >= 22 else { throw ArchiveError.invalid }
        var end = archive.count - 22
        let earliest = max(0, end - 65_535)
        while archive.le32(end) != 0x06054B50 || end + 22 + Int(archive.le16(end + 20)) != archive.count {
            guard end > earliest else { throw ArchiveError.invalid }
            end -= 1
        }

        let count = Int(archive.le16(end + 10))
        let directorySize = Int(archive.le32(end + 12))
        let directory = Int(archive.le32(end + 16))
        guard archive.le16(end + 4) == 0, archive.le16(end + 6) == 0,
              count == Int(archive.le16(end + 8)), count < 65_535 else { throw ArchiveError.unsupported }
        guard directory <= end, directorySize <= end - directory else { throw ArchiveError.invalid }

        var entries: [Entry] = []
        var cursor = directory
        let limit = directory + directorySize
        for _ in 0..<count {
            try Task.checkCancellation()
            guard limit - cursor >= 46, archive.le32(cursor) == 0x02014B50 else { throw ArchiveError.invalid }
            let nameEnd = cursor + 46 + Int(archive.le16(cursor + 28))
            let next = nameEnd + Int(archive.le16(cursor + 30)) + Int(archive.le16(cursor + 32))
            guard next <= limit else { throw ArchiveError.invalid }
            let filename = String(decoding: archive[(cursor + 46)..<nameEnd], as: UTF8.self)
                .replacingOccurrences(of: "\\", with: "/")
            let lowerName = filename.lowercased()
            if (lowerName.hasSuffix(".trh") || (lowerName as NSString).lastPathComponent == "track_map.tga"),
               !filename.hasPrefix("__MACOSX/") {
                entries.append(Entry(name: filename,
                                     flags: archive.le16(cursor + 8), method: archive.le16(cursor + 10),
                                     crc: archive.le32(cursor + 16), compressedSize: Int(archive.le32(cursor + 20)),
                                     size: Int(archive.le32(cursor + 24)), offset: Int(archive.le32(cursor + 42))))
            }
            cursor = next
        }

        let terrains = entries.filter { $0.name.lowercased().hasSuffix(".trh") }
        guard let depth = terrains.map(\.depth).min() else { throw ArchiveError.missingTerrain }
        let top = terrains.filter { $0.depth == depth }
        let matching = top.filter { $0.stem.caseInsensitiveCompare(name) == .orderedSame }
        let candidates = matching.isEmpty ? top : matching
        guard candidates.count == 1, let terrain = candidates.first else { throw ArchiveError.multipleTerrains }
        let path = (terrain.name as NSString).deletingLastPathComponent
        let map = entries.first {
            ($0.name as NSString).lastPathComponent.lowercased() == "track_map.tga"
                && ($0.name as NSString).deletingLastPathComponent == path && $0.size < 17_000_000
        }
        let terrainData = try contents(terrain, archive: archive, before: directory)
        let artwork = map.flatMap { try? contents($0, archive: archive, before: directory) }
        return (terrainData, artwork)
    }

    private static func contents(_ entry: Entry, archive: Data, before directory: Int) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ArchiveError.locked }
        guard (24...300_000_000).contains(entry.size) else { throw ArchiveError.unsupported }
        let offset = entry.offset
        guard offset <= directory - 30, archive.le32(offset) == 0x04034B50 else { throw ArchiveError.invalid }
        guard archive.le16(offset + 6) & 1 == 0 else { throw ArchiveError.locked }
        let start = offset + 30 + Int(archive.le16(offset + 26)) + Int(archive.le16(offset + 28))
        guard start <= directory, entry.compressedSize <= directory - start else { throw ArchiveError.invalid }

        let data: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw ArchiveError.invalid }
            data = archive.subdata(in: start..<(start + entry.size))
        case 8:
            data = try inflateEntry(archive, start: start, entry: entry)
        default:
            throw ArchiveError.unsupported
        }

        let checksum = data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
        guard UInt32(checksum) == entry.crc else { throw ArchiveError.invalid }
        return data
    }

    private static func inflateEntry(_ archive: Data, start: Int, entry: Entry) throws -> Data {
        var output = Data(count: entry.size)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ArchiveError.invalid
        }
        defer { inflateEnd(&stream) }
        let result = archive.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress?.advanced(by: start))
                stream.avail_in = uInt(entry.compressedSize)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(entry.size)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == entry.size,
              stream.total_in == entry.compressedSize else { throw ArchiveError.invalid }
        return output
    }
}

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | (UInt32(le16(offset + 2)) << 16)
    }
}
