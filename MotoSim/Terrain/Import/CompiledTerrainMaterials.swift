import Foundation
import zlib

/// Reads the terrain material stack from the observed TerrainEd MP2 v304 layout.
/// Geometry, scenery materials, shaders and vegetation records are independent.
enum CompiledTerrainMaterials {
    private static let mapVersion: UInt32 = 304
    private static let maxSide = 2048
    private static let materialSignature = Data(
        Array(repeating: [UInt8(0), 0, 0x80, 0x3f], count: 6).flatMap { $0 }
            + Array(repeating: 0, count: 28) + [1, 0, 0, 0]
    )

    private struct Image {
        let width: Int
        let height: Int
        let bytes: Range<Int>
    }

    private struct Layer {
        let texture: Image
        let mask: Image?
        let repeatsX: Float
        let repeatsZ: Float
    }

    struct Result {
        let ground: TrackGroundArt
        let grass: TrackGrass?
    }

    static func groundArt(in data: Data) throws -> TrackGroundArt? {
        try load(in: data)?.ground
    }

    static func load(in data: Data) throws -> Result? {
        guard data.count >= 256, data.le32(0) == 0x0032504D, data.le32(4) == mapVersion else { return nil }
        var cursor = 16
        while cursor < data.count,
              let signature = data.range(of: materialSignature, in: cursor..<data.count) {
            try Task.checkCancellation()
            cursor = signature.lowerBound + 1
            guard signature.lowerBound >= 8 else { continue }
            let group = signature.lowerBound - 8
            let count = Int(data.le32(group))
            guard (2...12).contains(count) else { continue }
            if let stack = readStack(data, at: group + 4, count: count),
               let art = try bake(stack.layers, in: data) {
                return Result(ground: art, grass: try readGrass(data, at: stack.end))
            }
        }
        try Task.checkCancellation()
        return nil
    }

    private static func readStack(_ data: Data, at start: Int, count: Int) -> (layers: [Layer], end: Int)? {
        var cursor = start
        var layers: [Layer] = []
        for index in 0..<count {
            guard cursor <= data.count - 204, data.le32(cursor) == 0,
                  data.le32(cursor + 56) == 1,
                  let diffuse = namedImage(data, at: cursor + 60, hasType: true) else { return nil }
            cursor = diffuse.bytes.upperBound
            guard cursor <= data.count - 24 else { return nil }
            switch data.le32(cursor) {
            case 0:
                cursor += 4
            case 1:
                // Skip the normal map's compressed extent without expanding it.
                guard data.le32(cursor + 4) == 0, data.le32(cursor + 8) == 0,
                      data.le32(cursor + 12) == 1,
                      let normal = namedImage(data, at: cursor + 20, hasType: false) else { return nil }
                cursor = normal.bytes.upperBound
            default:
                return nil
            }
            guard cursor <= data.count - 12 else { return nil }
            let x = Float(bitPattern: data.le32(cursor))
            let z = Float(bitPattern: data.le32(cursor + 4))
            guard (0.01...1024).contains(x), (0.01...1024).contains(z) else { return nil }
            cursor += 8
            let flag = data.le32(cursor)
            let mask: Image?
            if flag == 1, cursor <= data.count - 24,
               data.le32(cursor + 16) == 2,
               let image = image(data, widthAt: cursor + 4, sizeAt: cursor + 12, payload: cursor + 24) {
                mask = image
                cursor = image.bytes.upperBound
            } else if flag == 0 {
                mask = nil
                cursor += 4
            } else {
                return nil
            }
            guard index != 0 || mask == nil else { return nil }
            layers.append(Layer(texture: diffuse, mask: mask, repeatsX: x, repeatsZ: z))
            cursor += 4 // Terrain-layer thickness before the next material.
        }
        return layers.contains { $0.mask != nil } ? (layers, cursor) : nil
    }

    private static func readGrass(_ data: Data, at cursor: Int) throws -> TrackGrass? {
        // Observed MP2 density-map grass record: flag, mode, five shape values,
        // a deflated RGBA image, then the terrain-aligned 8-bit density grid.
        guard cursor <= data.count - 48, data.le32(cursor) == 1, data.le32(cursor + 4) == 2 else { return nil }
        let start = cursor + 8
        func value(_ offset: Int) -> Float { Float(bitPattern: data.le32(start + offset)) }
        guard (0.01...200).contains(value(0)), (0.01...10).contains(value(4)),
              (0...10).contains(value(8)), (0.01...10).contains(value(12)), (0...10).contains(value(16)),
              let texture = image(data, widthAt: start + 20, sizeAt: start + 28, payload: start + 40)
        else { return nil }
        let end = texture.bytes.upperBound
        guard end <= data.count - 16, data.le32(end) == 0, data.le32(end + 4) == 0 else { return nil }
        let maskColumns = Int(data.le32(end + 8))
        let maskRows = Int(data.le32(end + 12))
        guard (1...8192).contains(maskColumns), (1...8192).contains(maskRows),
              maskColumns * maskRows <= data.count - end - 16 else { return nil }
        let ratio = min(1, Float(TrackGrass.maxImageSide) / Float(max(texture.width, texture.height)))
        let width = max(1, Int(Float(texture.width) * ratio))
        let height = max(1, Int(Float(texture.height) * ratio))
        guard let pixels = try decode(texture, in: data, channels: 4, width: width, height: height) else { return nil }
        let maskWidth = min(TrackGrass.maxMaskSide, maskColumns)
        let maskHeight = min(TrackGrass.maxMaskSide, maskRows)
        var mask = Data(count: maskWidth * maskHeight)
        try mask.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0..<maskHeight {
                    try Task.checkCancellation()
                    let sourceStart = end + 16 + row * maskRows / maskHeight * maskColumns
                    for column in 0..<maskWidth {
                        output[row * maskWidth + column] = source[sourceStart + column * maskColumns / maskWidth]
                    }
                }
            }
        }
        return TrackGrass(image: TrackGroundArt(width: width, height: height, pixels: pixels),
                          maskWidth: maskWidth, maskHeight: maskHeight, mask: mask,
                          density: value(0), height: value(4), heightVariation: value(8),
                          width: value(12), widthVariation: value(16))
    }

    private static func namedImage(_ data: Data, at name: Int, hasType: Bool) -> Image? {
        let extra = hasType ? 4 : 0
        guard name <= data.count - 140 - extra,
              let zero = data[name..<(name + 100)].firstIndex(of: 0), zero > name,
              data[name..<zero].allSatisfy({ (32...126).contains($0) }),
              data[zero..<(name + 100)].allSatisfy({ $0 == 0 }),
              !hasType || data.le32(name + 100) == 0 else { return nil }
        return image(data, widthAt: name + 100 + extra, sizeAt: name + 128 + extra,
                     payload: name + 140 + extra)
    }

    private static func image(_ data: Data, widthAt: Int, sizeAt: Int, payload: Int) -> Image? {
        let width = Int(data.le32(widthAt))
        let height = Int(data.le32(widthAt + 4))
        // TerrainEd counts eight bytes past the end of each raw deflate stream.
        let size = Int(data.le32(sizeAt)) - 8
        guard (1...8192).contains(width), (1...8192).contains(height), size > 0,
              size <= data.count - payload else { return nil }
        return Image(width: width, height: height, bytes: payload..<(payload + size))
    }

    private static func bake(_ layers: [Layer], in data: Data) throws -> TrackGroundArt? {
        guard let mask = layers.compactMap(\.mask).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let width = min(maxSide, mask.width)
        let height = min(maxSide, mask.height)
        var output = Data(count: width * height * 4)
        for layer in layers {
            let tx = min(maxSide, layer.texture.width)
            let tz = min(maxSide, layer.texture.height)
            guard let texture = try decode(layer.texture, in: data, channels: 4, width: tx, height: tz) else { return nil }
            let alpha: Data?
            if let mask = layer.mask {
                guard let decoded = try decode(mask, in: data, channels: 1, width: width, height: height) else { return nil }
                alpha = decoded
            } else {
                alpha = nil
            }
            let columns = tiled(count: width, textureSize: tx, repeats: layer.repeatsX)
            let rows = tiled(count: height, textureSize: tz, repeats: layer.repeatsZ)
            try output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                try texture.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    let composite = { (mask: UnsafeRawBufferPointer?) in
                        for row in 0..<height {
                            try Task.checkCancellation()
                            for column in 0..<width {
                                let pixel = row * width + column
                                let opacity = Int(mask?[pixel] ?? 255)
                                if opacity == 0 { continue }
                                let i = pixel * 4
                                let j = (rows[row] * tx + columns[column]) * 4
                                for channel in 0..<3 {
                                    target[i + channel] = UInt8((Int(target[i + channel]) * (255 - opacity)
                                        + Int(source[j + channel]) * opacity + 127) / 255)
                                }
                                target[i + 3] = 255
                            }
                        }
                    }
                    if let alpha { try alpha.withUnsafeBytes { try composite($0) } }
                    else { try composite(nil) }
                }
            }
        }
        return TrackGroundArt(width: width, height: height, pixels: output)
    }

    private static func tiled(count: Int, textureSize: Int, repeats: Float) -> [Int] {
        (0..<count).map { index in
            let coordinate = (Float(index) + 0.5) * repeats / Float(count)
            return min(textureSize - 1, Int((coordinate - floor(coordinate)) * Float(textureSize)))
        }
    }

    // Decode a row at a time. A full 8192² mask never needs to live in memory.
    private static func decode(_ image: Image, in data: Data, channels: Int, width: Int, height: Int) throws -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        let rowBytes = image.width * channels
        var row = Data(count: rowBytes)
        var output = Data(count: width * height * channels)
        let columns = (0..<width).map { $0 * image.width / width * channels }
        var targetRow = 0
        var status: Int32 = Z_OK
        let valid = try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress?.advanced(by: image.bytes.lowerBound))
            stream.avail_in = uInt(image.bytes.count)
            let rowsValid = try output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for sourceRow in 0..<image.height {
                    if sourceRow.isMultiple(of: 32) { try Task.checkCancellation() }
                    status = row.withUnsafeMutableBytes {
                        stream.next_out = $0.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(rowBytes)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    guard stream.avail_out == 0, status == Z_OK ||
                        (status == Z_STREAM_END && sourceRow == image.height - 1) else { return false }
                    try row.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                        while targetRow < height && targetRow * image.height / height == sourceRow {
                            try Task.checkCancellation()
                            for column in 0..<width {
                                let offset = (targetRow * width + column) * channels
                                for channel in 0..<channels {
                                    target[offset + channel] = source[columns[column] + channel]
                                }
                            }
                            targetRow += 1
                        }
                    }
                }
                return true
            }
            if rowsValid && status == Z_OK {
                var terminator = UInt8(0)
                status = withUnsafeMutablePointer(to: &terminator) {
                    stream.next_out = $0
                    stream.avail_out = 1
                    return inflate(&stream, Z_FINISH)
                }
            }
            return rowsValid
        }
        guard valid, status == Z_STREAM_END, stream.total_in == image.bytes.count,
              stream.total_out == image.width * image.height * channels else { return nil }
        return output
    }
}
