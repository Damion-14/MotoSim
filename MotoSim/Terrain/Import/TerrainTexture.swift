import Foundation

enum TerrainTexture {
    private static let dirt = SIMD3<Int>(143, 100, 65)
    struct Layer {
        let image: String
        let mask: String?
        let repeatX: Float
        let repeatZ: Float
    }

    static func layers(in descriptor: String) -> [Layer] {
        var depth = 0
        var block = ""
        var fields: [String: String] = [:]
        var layers: [Int: Layer] = [:]
        let lines = descriptor.split(whereSeparator: \.isNewline).map {
            $0.components(separatedBy: "//")[0]
        }.joined(separator: "\n").replacingOccurrences(of: "{", with: "\n{\n")
            .replacingOccurrences(of: "}", with: "\n}\n")
        for line in lines.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            switch text {
            case "{":
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 {
                    if block.hasPrefix("layer"), let index = Int(block.dropFirst(5)), (0..<16).contains(index),
                       let image = fields["map"] {
                        let repeatBoth = repeats(fields["repetitions"], fallback: 1)
                        layers[index] = Layer(image: image, mask: fields["mask"],
                                              repeatX: repeats(fields["repetitions_x"], fallback: repeatBoth),
                                              repeatZ: repeats(fields["repetitions_z"], fallback: repeatBoth))
                    }
                    fields.removeAll(keepingCapacity: true)
                    block = ""
                }
            default:
                if depth == 0 {
                    block = text.lowercased()
                } else if depth == 1 {
                    let parts = text.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                        let value = parts[1].trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !value.isEmpty { fields[key] = value }
                    }
                }
            }
        }
        return layers.keys.sorted().compactMap { layers[$0] }
    }

    private static func repeats(_ text: String?, fallback: Float) -> Float {
        guard let text, let value = Float(text), (0.01...1024).contains(value) else { return fallback }
        return value
    }

    static func bake(_ descriptor: String, field: HeightField,
                     read: (String) -> Data?) throws -> TrackGroundArt? {
        let width = resolution(field.width)
        let height = resolution(field.length)
        var output = Data(count: width * height * 4)
        var painted = false
        for layer in layers(in: descriptor) {
            try Task.checkCancellation()
            guard let bytes = read(layer.image), let texture = GroundTGA(bytes) else { continue }
            let mask = layer.mask.flatMap { read($0).flatMap(GroundTGA.init) }
            guard layer.mask == nil || mask != nil else { continue }
            try output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                let columns = tiledCoordinates(count: width, size: texture.width, repeats: layer.repeatX)
                let rows = tiledCoordinates(count: height, size: texture.height, repeats: layer.repeatZ)
                for y in 0..<height {
                    try Task.checkCancellation()
                    let maskRow = y * (mask?.height ?? 1) / height
                    for x in 0..<width {
                        let opacity = mask.map {
                            let channel = $0.channels == 4 ? 3 : 0
                            return Int($0.pixels[(maskRow * $0.width + x * $0.width / width) * 4 + channel])
                        } ?? 255
                        if opacity == 0 { continue }
                        let source = (rows[y] * texture.width + columns[x]) * 4
                        let destination = (y * width + x) * 4
                        let base = buffer[destination + 3] == 0
                        for channel in 0..<3 {
                            let previous = base ? dirt[channel] : Int(buffer[destination + channel])
                            buffer[destination + channel] = UInt8(
                                (previous * (255 - opacity) + Int(texture.pixels[source + channel]) * opacity + 127) / 255
                            )
                        }
                        buffer[destination + 3] = 255
                    }
                }
            }
            painted = true
        }
        guard painted else { return nil }
        output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in stride(from: 0, to: buffer.count, by: 4) where buffer[index + 3] == 0 {
                buffer[index] = UInt8(dirt.x)
                buffer[index + 1] = UInt8(dirt.y)
                buffer[index + 2] = UInt8(dirt.z)
                buffer[index + 3] = 255
            }
        }
        return TrackGroundArt(width: width, height: height, pixels: output)
    }

    private static func tiledCoordinates(count: Int, size: Int, repeats: Float) -> [Int] {
        (0..<count).map { index in
            let phase = ((Float(index) + 0.5) * repeats / Float(count)).truncatingRemainder(dividingBy: 1)
            return Int(phase * Float(size)) % size
        }
    }

    private static func resolution(_ meters: Float) -> Int {
        min(2048, max(128, Int(ceil(meters * 6))))
    }

}

// TerrainEd source TGA files can be RGB, RGBA, or grayscale, with optional RLE.
private struct GroundTGA {
    let width: Int
    let height: Int
    let channels: Int
    let pixels: Data

    init?(_ data: Data) {
        guard data.count >= 18, data[1] == 0, [2, 3, 10, 11].contains(data[2]) else { return nil }
        let width = Int(data.le16(12))
        let height = Int(data.le16(14))
        let stride = Int(data[16]) / 8
        let grayscale = data[2] == 3 || data[2] == 11
        guard (1...2048).contains(width), (1...2048).contains(height),
              grayscale ? data[16] == 8 : (data[16] == 24 || data[16] == 32) else { return nil }
        channels = stride
        let runLength = data[2] >= 10
        let topOrigin = data[17] & 0x20 != 0
        let rightOrigin = data[17] & 0x10 != 0
        let count = width * height
        var output = Data(count: count * 4)
        var source = 18 + Int(data[0])
        var written = 0
        let valid = output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            while written < count {
                if written.isMultiple(of: 4096) && Task.isCancelled { return false }
                guard source < data.count else { return false }
                let packet = runLength ? Int(data[source]) : 0
                if runLength { source += 1 }
                let length = (packet & 127) + 1
                let repeated = packet & 128 != 0
                let bytes = (repeated ? 1 : length) * stride
                guard length <= count - written, bytes <= data.count - source else { return false }
                for index in 0..<length {
                    let offset = source + (repeated ? 0 : index * stride)
                    let x = written % width
                    let y = written / width
                    let pixel = ((topOrigin ? y : height - y - 1) * width + (rightOrigin ? width - x - 1 : x)) * 4
                    buffer[pixel] = grayscale ? data[offset] : data[offset + 2]
                    buffer[pixel + 1] = grayscale ? data[offset] : data[offset + 1]
                    buffer[pixel + 2] = data[offset]
                    buffer[pixel + 3] = stride == 4 ? data[offset + 3] : 255
                    written += 1
                }
                source += bytes
            }
            return true
        }
        guard valid else { return nil }
        self.width = width
        self.height = height
        pixels = output
    }
}
