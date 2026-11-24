import Foundation
import simd

struct TrackGroundArt: Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    static func make(terrain: Data, artwork: Data?, field: HeightField) -> TrackGroundArt? {
        guard let route = embeddedRoute(terrain, field: field) else { return nil }
        if let artwork, let targa = Targa(artwork),
           let aligned = targa.aligned(to: route, aspect: field.width / field.length) {
            return aligned
        }
        return routeTexture(route, aspect: field.width / field.length, terrainWidth: field.width)
    }

    private static func embeddedRoute(_ data: Data, field: HeightField) -> [SIMD2<Float>]? {
        guard data.count >= 80, data.le32(data.count - 8) == 0x00545845 else { return nil }
        let extensionSize = Int(data.le32(data.count - 4))
        let end = data.count - 8 - extensionSize - 64
        guard end >= 8, end <= data.count - 72 else { return nil }
        let stride = 60
        let candidateLimit = min(12_000, (end - 8) / stride)
        guard candidateLimit >= 3 else { return nil }

        for count in 3...candidateLimit {
            let start = end - count * stride
            guard data.le32(start - 8) == 0, data.le32(start - 4) == count else { continue }
            var records: [(point: SIMD2<Float>, direction: SIMD2<Float>, length: Float, radius: Float)] = []
            for index in 0..<count {
                let offset = start + index * stride
                func value(_ relative: Int) -> Float { Float(bitPattern: data.le32(offset + relative)) }
                let point = SIMD2<Float>(value(32), value(44))
                let direction = SIMD2<Float>(value(24), value(28))
                let radius = data.le32(offset) == 0 ? 0 : abs(value(8))
                let length = value(4)
                guard data.le32(offset) <= 1,
                      (-1...field.width + 1).contains(point.x), (-1...field.length + 1).contains(point.y),
                      abs(simd_length(direction) - 1) < 0.01,
                      (0...1500).contains(length), radius.isFinite else { break }
                records.append((point, direction, length, radius))
            }
            guard records.count == count else { continue }
            var route: [SIMD2<Float>] = []
            for index in records.indices {
                let segment = records[index]
                let next = records[(index + 1) % count].point
                let steps = min(500, max(1, Int(ceil(segment.length / 0.75))))
                let sideways = SIMD2<Float>(-segment.direction.y, segment.direction.x)
                func endpoint(_ distance: Float, sign: Float) -> SIMD2<Float> {
                    let angle = distance / segment.radius
                    return segment.point + segment.radius * (sin(angle) * segment.direction
                        + sign * (1 - cos(angle)) * sideways)
                }
                let curved = segment.radius > 0.01
                let sign: Float = curved && simd_distance(endpoint(segment.length, sign: -1), next)
                    < simd_distance(endpoint(segment.length, sign: 1), next) ? -1 : 1
                for step in 0..<steps {
                    let t = Float(step) / Float(steps)
                    let point = curved ? endpoint(segment.length * t, sign: sign)
                        : segment.point + segment.length * t * segment.direction
                    if (-1...field.width + 1).contains(point.x), (-1...field.length + 1).contains(point.y) {
                        route.append([point.x / field.width, point.y / field.length])
                    }
                }
                if route.count > 40_000 { return nil }
            }
            return route.count >= 16 ? route : nil
        }
        return nil
    }

    private static func routeTexture(_ route: [SIMD2<Float>], aspect: Float, terrainWidth: Float) -> TrackGroundArt {
        let width = 768
        let height = max(128, min(1024, Int(Float(width) / aspect)))
        let laneX = max(2, min(32, Int(3 * Float(width) / terrainWidth)))
        let laneZ = max(2, min(32, Int(Float(laneX) * Float(height) * aspect / Float(width))))
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let noise = (x * 23 ^ y * 47) % 13
                    bytes[offset] = UInt8(74 + noise)
                    bytes[offset + 1] = UInt8(83 + noise)
                    bytes[offset + 2] = UInt8(46 + noise)
                    bytes[offset + 3] = 255
                }
            }
            for point in route {
                let x = Int(point.x * Float(width - 1))
                let y = Int(point.y * Float(height - 1))
                guard x >= -laneX, x < width + laneX, y >= -laneZ, y < height + laneZ else { continue }
                for row in max(0, y - laneZ)..<min(height, y + laneZ + 1) {
                    for column in max(0, x - laneX)..<min(width, x + laneX + 1) {
                        let dx = Float(column - x) / Float(laneX)
                        let dz = Float(row - y) / Float(laneZ)
                        guard dx * dx + dz * dz <= 1 else { continue }
                        let offset = (row * width + column) * 4
                        let noise = (column * 23 ^ row * 47) % 13
                        bytes[offset] = UInt8(145 + noise)
                        bytes[offset + 1] = UInt8(94 + noise)
                        bytes[offset + 2] = UInt8(56 + noise)
                    }
                }
            }
        }
        return TrackGroundArt(width: width, height: height, pixels: pixels)
    }
}

private struct Targa {
    let data: Data
    let width: Int
    let height: Int
    let channels: Int
    let offset: Int
    let topOrigin: Bool

    init?(_ data: Data) {
        guard data.count >= 18, data[1] == 0, data[2] == 2 else { return nil }
        let width = Int(data.le16(12))
        let height = Int(data.le16(14))
        let channels = Int(data[16]) / 8
        let offset = 18 + Int(data[0])
        guard (64...2048).contains(width), (64...2048).contains(height), channels == 3 || channels == 4,
              data[17] & 0x10 == 0, offset + width * height * channels <= data.count else { return nil }
        self.data = data
        self.width = width
        self.height = height
        self.channels = channels
        self.offset = offset
        topOrigin = data[17] & 0x20 != 0
    }

    func aligned(to route: [SIMD2<Float>], aspect: Float) -> TrackGroundArt? {
        let background = rgb(0, 0)
        func foreground(_ x: Int, _ y: Int) -> Bool {
            let color = rgb(x, y)
            return simd_length(SIMD3<Float>(color &- background)) > 30
        }
        let filledRows = (0..<height).filter { y in
            let hits = stride(from: 0, to: width, by: 8).filter { foreground($0, y) }.count
            return hits * 8 > width * 2 / 3
        }
        guard let top = filledRows.first, let last = filledRows.last,
              filledRows.count == last - top + 1, last > top else { return nil }
        let midpoint = (top + last) / 2
        guard let left = (0..<width).first(where: { foreground($0, midpoint) }),
              let right = (0..<width).last(where: { foreground($0, midpoint) }), right > left else { return nil }

        let mapWidth = right - left + 1
        let mapHeight = last - top + 1
        guard abs(Float(mapWidth) / Float(mapHeight) / aspect - 1) < 0.035,
              mapWidth < width - 4 || mapHeight < height - 4 else { return nil }

        // Match the author's high-visibility centerline against the compiled course before projection.
        let samples = stride(from: 0, to: route.count, by: max(1, route.count / 500)).map { route[$0] }
        let orientations = [(false, false), (true, false), (false, true), (true, true)]
            .map { flipX, flipY in
                let matches = samples.filter { point in
                    let u = flipX ? 1 - point.x : point.x
                    let v = flipY ? 1 - point.y : point.y
                    let x = left + Int((u * Float(mapWidth - 1)).rounded())
                    let y = top + Int((v * Float(mapHeight - 1)).rounded())
                    for dy in -3...3 {
                        for dx in -3...3 where (left...right).contains(x + dx) && (top...last).contains(y + dy) {
                            let color = rgb(x + dx, y + dy)
                            if color.x > 115, color.y > 145, color.z < 85, color.y > color.x - 24 { return true }
                        }
                    }
                    return false
                }.count
                return (matches, flipX, flipY)
            }.sorted { $0.0 > $1.0 }
        let (matches, flipX, flipY) = orientations[0]
        guard matches * 2 > samples.count, matches - orientations[1].0 > samples.count / 4 else { return nil }
        var pixels = Data()
        pixels.reserveCapacity(mapWidth * mapHeight * 4)
        for row in 0..<mapHeight {
            for column in 0..<mapWidth {
                let color = rgb(flipX ? right - column : left + column, flipY ? last - row : top + row)
                pixels.append(UInt8(color.x))
                pixels.append(UInt8(color.y))
                pixels.append(UInt8(color.z))
                pixels.append(255)
            }
        }
        return TrackGroundArt(width: mapWidth, height: mapHeight, pixels: pixels)
    }

    private func rgb(_ x: Int, _ y: Int) -> SIMD3<Int32> {
        let row = topOrigin ? y : height - y - 1
        let index = offset + (row * width + x) * channels
        return [Int32(data[index + 2]), Int32(data[index + 1]), Int32(data[index])]
    }
}
