import Foundation

enum MXTrackImporter {
    enum Progress: Sendable, Equatable {
        case opening, terrain, extracting(Double), textures, complete

        var fraction: Double {
            switch self {
            case .opening: 0
            case .terrain: 0.12
            case .extracting(let fraction): 0.22 + fraction * 0.56
            case .textures: 0.82
            case .complete: 1
            }
        }
    }

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

    static func load(file: URL, progress: (Progress) -> Void = { _ in }) throws -> Track {
        if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            return try load(folder: file, progress: progress)
        }
        progress(.opening)
        let name = file.deletingPathExtension().lastPathComponent
        guard ["pkz", "zip"].contains(file.pathExtension.lowercased()) else { throw ImportError.unsupportedFile }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        progress(.terrain)
        let files = try PKZArchive.trackFiles(in: data, named: name)
        var track = try loadCompiled(files.terrain, name: name, artwork: files.artwork)
        if let compiled = files.map {
            progress(.extracting(0))
            if let material = try? compiled.materials(extractionProgress: {
                progress(.extracting($0))
            }, beforeDecoding: {
                progress(.textures)
            }) {
                track.groundArt = material.ground
                track.grass = material.grass
            }
        }
        try Task.checkCancellation()
        progress(.complete)
        return track
    }

    private static func loadCompiled(_ data: Data, name: String, artwork: Data?) throws -> Track {
        // TerrainEd TRH heightfield: magic, dimensions, signed 16-bit heights, then dimensions in meters.
        guard data.count >= 24, data.le32(0) == 0x00485254 else { throw ImportError.invalidCompiledHeightfield }
        let columns = Int(data.le32(4))
        let rows = Int(data.le32(8))
        guard (2...HeightField.maxImportedSamplesPerAxis).contains(columns), (2...HeightField.maxImportedSamplesPerAxis).contains(rows) else {
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
        if let field = track.heightField,
           let layout = TrackGroundArt.layout(terrain: data, artwork: artwork, field: field) {
            track.groundArt = layout.art
            track.courseLine = layout.route
            if track.contains([layout.start.x, 0, layout.start.y]) {
                track.startPosition = [layout.start.x, 0, layout.start.y]
                track.startHeading = layout.heading
            }
        }
        return track
    }

    static func load(folder: URL, progress: (Progress) -> Void = { _ in }) throws -> Track {
        progress(.opening)
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
                progress(.terrain)
                var track = try loadCompiled(Data(contentsOf: url, options: .mappedIfSafe),
                                             name: folder.lastPathComponent, artwork: artwork)
                progress(.textures)
                let mapURL = url.deletingPathExtension().appendingPathExtension("map")
                if let data = artworkFile(mapURL, root: root, limit: 1_500_000_000),
                   let material = try? CompiledTerrainMaterials.load(in: data) {
                    track.groundArt = material.ground
                    track.grass = material.grass
                }
                try Task.checkCancellation()
                progress(.complete)
                return track
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

        progress(.terrain)
        let bytesData = try Data(contentsOf: rawURL, options: .mappedIfSafe)
        guard bytesData.count == expectedBytes else { throw ImportError.invalidHeightmapSize(expectedBytes) }
        var track = try makeTrack(name: folder.lastPathComponent, data: bytesData, offset: 0, signed: false,
                                  columns: config.columns, rows: config.rows, width: config.width,
                                  length: config.length, scale: config.scale)
        let matchingVisual = visual.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(
                descriptor.deletingPathExtension().lastPathComponent
            ) == .orderedSame
        }
        if let hmf = matchingVisual ?? (visual.count == 1 ? visual.first : nil),
           let field = track.heightField,
           let data = artworkFile(hmf, root: root, limit: 1_048_576),
           let text = String(data: data, encoding: .utf8) {
            progress(.textures)
            track.groundArt = try TerrainTexture.bake(text, field: field) { path in
                let relative = path.replacingOccurrences(of: "\\", with: "/")
                guard !relative.hasPrefix("/"), !relative.contains(":"),
                      !relative.split(separator: "/").contains(".."),
                      (relative as NSString).pathExtension.lowercased() == "tga" else { return nil }
                return artworkFile(root.appending(path: relative), root: root, limit: 20_000_000)
            }
        }
        try Task.checkCancellation()
        progress(.complete)
        return track
    }

    private static func artworkFile(_ url: URL, root: URL, limit: Int) -> Data? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: root),
              let info = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let bytes = info.fileSize, (1...limit).contains(bytes) else { return nil }
        return try? Data(contentsOf: resolved, options: .mappedIfSafe)
    }

    private static func makeTrack(name: String, data: Data, offset: Int, signed: Bool,
                                  columns sourceColumns: Int, rows sourceRows: Int,
                                  width: Float, length: Float, scale: Float) throws -> Track {
        let samples: [UInt16] = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let source = bytes.bindMemory(to: UInt8.self)
            var heights: [UInt16] = []
            heights.reserveCapacity(sourceColumns * sourceRows)
            for row in 0..<sourceRows {
                try Task.checkCancellation()
                for column in 0..<sourceColumns {
                    let index = offset + (row * sourceColumns + column) * 2
                    let raw = UInt16(source[index]) | (UInt16(source[index + 1]) << 8)
                    heights.append(signed ? raw ^ 0x8000 : raw)
                }
            }
            return heights
        }
        let field = HeightField(columns: sourceColumns, rows: sourceRows, width: width, length: length,
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
        guard let columns = fields["samples_x"].flatMap(Int.init), (2...HeightField.maxImportedSamplesPerAxis).contains(columns),
              let rows = fields["samples_z"].flatMap(Int.init), (2...HeightField.maxImportedSamplesPerAxis).contains(rows),
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
