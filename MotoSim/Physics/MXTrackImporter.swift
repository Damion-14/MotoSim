import Foundation

enum MXTrackImporter {
    enum ImportError: LocalizedError {
        case descriptorMissing
        case multipleDescriptors
        case invalidDescriptor
        case missingHeightmap(String)
        case invalidHeightmapSize(Int)
        case compiledTrackOnly
        case invalidCompiledHeightfield
        case unsupportedFile

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                "Choose an MX Bikes .pkz archive, a ZIP containing compiled terrain, or an unpacked track folder."
            case .descriptorMissing:
                "Choose an MX Bikes source folder containing a .tht or .hmf file and its RAW heightmap."
            case .multipleDescriptors:
                "This folder has multiple terrain layouts. Choose a folder with one .tht or one .hmf layout."
            case .compiledTrackOnly:
                "This folder has no supported terrain heightfield. Choose a PKZ with a .trh file or the original terrain source."
            case .invalidCompiledHeightfield:
                "This compiled track uses an unrecognized or incomplete .trh heightfield."
            case .invalidDescriptor:
                "The descriptor needs valid samples_x, samples_z, size_x, size_z, scale, and a relative RAW data path."
            case .missingHeightmap(let path):
                "The source folder is missing the referenced RAW heightmap: \(path)."
            case .invalidHeightmapSize(let bytes):
                "The RAW heightmap must be unsigned 16-bit little-endian and exactly \(bytes) bytes."
            }
        }
    }

    static func load(file: URL) throws -> Track {
        if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            return try load(folder: file)
        }
        let name = file.deletingPathExtension().lastPathComponent
        guard ["pkz", "zip"].contains(file.pathExtension.lowercased()) else { throw ImportError.unsupportedFile }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let files = try PKZArchive.trackFiles(in: data, named: name)
        return try loadCompiled(files.terrain, name: name, artwork: files.artwork)
    }

    private static func loadCompiled(_ data: Data, name: String, artwork: Data?) throws -> Track {
        // TerrainEd TRH heightfield: magic, dimensions, signed 16-bit heights, then dimensions in meters.
        guard data.count >= 24, data.le32(0) == 0x00485254 else { throw ImportError.invalidCompiledHeightfield }
        let columns = Int(data.le32(4))
        let rows = Int(data.le32(8))
        guard (2...4097).contains(columns), (2...4097).contains(rows) else {
            throw ImportError.invalidCompiledHeightfield
        }
        let dimensions = 12 + columns * rows * 2
        guard dimensions <= data.count - 12 else { throw ImportError.invalidCompiledHeightfield }
        let width = Float(bitPattern: data.le32(dimensions))
        let scale = Float(bitPattern: data.le32(dimensions + 4))
        let length = Float(bitPattern: data.le32(dimensions + 8))
        guard (4...10_000).contains(width), (4...10_000).contains(length), (0...5_000).contains(scale) else {
            throw ImportError.invalidCompiledHeightfield
        }

        var track = try makeTrack(name: name, data: data, offset: 12, signed: true, columns: columns, rows: rows,
                                  width: width, length: length, scale: scale)
        if let field = track.heightField {
            track.groundArt = TrackGroundArt.make(terrain: data, artwork: artwork, field: field)
        }
        return track
    }

    static func load(folder: URL) throws -> Track {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        let collision = items.filter { $0.pathExtension.lowercased() == "tht" }
        let visual = items.filter { $0.pathExtension.lowercased() == "hmf" }
        let candidates = collision.isEmpty ? visual : collision
        guard let descriptor = candidates.first else {
            let binary = items.filter { $0.pathExtension.lowercased() == "trh" }
            if binary.count == 1, let terrain = binary.first {
                let url = terrain.resolvingSymlinksInPath().standardizedFileURL
                guard isInside(url, root: root),
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ImportError.invalidCompiledHeightfield
                }
                let map = items.first { $0.lastPathComponent.lowercased() == "track_map.tga" }
                let artwork = map.flatMap { candidate -> Data? in
                    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                    guard isInside(resolved, root: root),
                          let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size < 17_000_000 else { return nil }
                    return try? Data(contentsOf: resolved, options: .mappedIfSafe)
                }
                return try loadCompiled(Data(contentsOf: url, options: .mappedIfSafe),
                                        name: folder.lastPathComponent, artwork: artwork)
            }
            if binary.count > 1 { throw ImportError.multipleDescriptors }
            let compiledExtensions = Set(["pkz", "trh", "map", "trp"])
            if items.contains(where: { compiledExtensions.contains($0.pathExtension.lowercased()) }) {
                throw ImportError.compiledTrackOnly
            }
            throw ImportError.descriptorMissing
        }
        guard candidates.count == 1 else { throw ImportError.multipleDescriptors }

        let descriptorURL = descriptor.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(descriptorURL, root: root) else { throw ImportError.invalidDescriptor }
        let descriptorInfo = try descriptorURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard descriptorInfo.isRegularFile == true, let bytes = descriptorInfo.fileSize,
              bytes <= 1_048_576 else { throw ImportError.invalidDescriptor }
        let config = try parse(String(contentsOf: descriptorURL, encoding: .utf8))
        let rawURL = root.appending(path: config.path).resolvingSymlinksInPath().standardizedFileURL
        guard isInside(rawURL, root: root) else { throw ImportError.invalidDescriptor }
        guard let raw = try? rawURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), raw.isRegularFile == true else {
            throw ImportError.missingHeightmap(config.path)
        }
        let expectedBytes = config.columns * config.rows * 2
        guard raw.fileSize == expectedBytes else { throw ImportError.invalidHeightmapSize(expectedBytes) }

        let bytesData = try Data(contentsOf: rawURL, options: .mappedIfSafe)
        guard bytesData.count == expectedBytes else { throw ImportError.invalidHeightmapSize(expectedBytes) }
        return try makeTrack(name: folder.lastPathComponent, data: bytesData, offset: 0, signed: false,
                             columns: config.columns, rows: config.rows, width: config.width,
                             length: config.length, scale: config.scale)
    }

    private static func makeTrack(name: String, data: Data, offset: Int, signed: Bool,
                                  columns sourceColumns: Int, rows sourceRows: Int,
                                  width: Float, length: Float, scale: Float) throws -> Track {
        let columns = min(1025, sourceColumns)
        let rows = min(1025, sourceRows)
        let samples: [UInt16] = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func value(_ x: Int, _ y: Int) -> Float {
                let index = offset + (y * sourceColumns + x) * 2
                let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                return Float(signed ? raw ^ 0x8000 : raw)
            }
            var heights: [UInt16] = []
            heights.reserveCapacity(columns * rows)
            for row in 0..<rows {
                try Task.checkCancellation()
                let z = Float(row) * Float(sourceRows - 1) / Float(rows - 1)
                let j = Int(z)
                let nextRow = min(j + 1, sourceRows - 1)
                for column in 0..<columns {
                    let x = Float(column) * Float(sourceColumns - 1) / Float(columns - 1)
                    let i = Int(x)
                    let nextColumn = min(i + 1, sourceColumns - 1)
                    let u = x - Float(i)
                    let v = z - Float(j)
                    let top = value(i, j) * (1 - u) + value(nextColumn, j) * u
                    let bottom = value(i, nextRow) * (1 - u) + value(nextColumn, nextRow) * u
                    heights.append(UInt16((top * (1 - v) + bottom * v).rounded()))
                }
            }
            return heights
        }
        let field = HeightField(columns: columns, rows: rows, width: width, length: length,
                                elevationRange: scale, samples: samples)
        return Track(name: name, heightField: field)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.pathComponents.starts(with: root.pathComponents) && url.pathComponents.count > root.pathComponents.count
    }

    private static func parse(_ text: String) throws -> (columns: Int, rows: Int, width: Float, length: Float, scale: Float, path: String) {
        var fields: [String: String] = [:]
        let keys = Set(["samples_x", "samples_z", "size_x", "size_z", "scale", "data"])
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard keys.contains(key), fields[key] == nil else { continue }
            let value = parts[1].components(separatedBy: "//")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let columns = fields["samples_x"].flatMap(Int.init), (2...4097).contains(columns),
              let rows = fields["samples_z"].flatMap(Int.init), (2...4097).contains(rows),
              let width = fields["size_x"].flatMap(Float.init), (4...10_000).contains(width),
              let length = fields["size_z"].flatMap(Float.init), (4...10_000).contains(length),
              let scale = fields["scale"].flatMap(Float.init), (0...5_000).contains(scale),
              let data = fields["data"] else { throw ImportError.invalidDescriptor }
        let path = data.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.split(separator: "/").contains(".."),
              (path as NSString).pathExtension.lowercased() == "raw" else { throw ImportError.invalidDescriptor }
        return (columns, rows, width, length, scale, path)
    }
}
