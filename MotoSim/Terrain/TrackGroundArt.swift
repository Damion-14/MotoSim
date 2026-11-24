import Foundation
import simd

struct TrackGroundArt: Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    struct Layout {
        let art: TrackGroundArt?
        let route: [SIMD2<Float>]
        let start: SIMD2<Float>
        let heading: Float
    }

    private struct Segment {
        let point: SIMD2<Float>
        let direction: SIMD2<Float>
        let length: Float
        let radius: Float

        func point(at distance: Float, turn: Float) -> SIMD2<Float> {
            guard radius > 0.01 else { return point + direction * distance }
            let angle = distance / radius
            let tangent = SIMD2<Float>(-direction.y, direction.x)
            return point + radius * (sin(angle) * direction + turn * (1 - cos(angle)) * tangent)
        }
    }

    static func layout(terrain: Data, artwork: Data?, field: HeightField) -> Layout? {
        guard let segments = embeddedSegments(terrain, field: field),
              let first = segments.first, let route = sampledRoute(segments, field: field) else { return nil }
        let aspect = field.width / field.length
        let art = artwork.flatMap(Targa.init)?.aligned(to: route, aspect: aspect)
        let start = first.point - SIMD2<Float>(field.width / 2, field.length / 2)
        let heading = atan2(first.direction.x, first.direction.y)
        return Layout(art: art, route: route, start: start, heading: heading < 0 ? heading + 2 * .pi : heading)
    }

    private static func embeddedSegments(_ data: Data, field: HeightField) -> [Segment]? {
        guard data.count >= 80, data.le32(data.count - 8) == 0x00545845 else { return nil }
        let footer = data.count - 8
        let end = footer - Int(data.le32(data.count - 4)) - 64
        let recordBytes = 60
        if end >= 8 {
            let countLimit = min(12_000, (end - 8) / recordBytes)
            if countLimit >= 3 {
                for count in 3...countLimit {
                    let header = end - count * recordBytes - 8
                    if data.le32(header) == 0, data.le32(header + 4) == count,
                       let segments = readSegments(data, at: header + 8, count: count, field: field) {
                        return segments
                    }
                }
            }
        }

        // Some TrackEd exports put the main route before extra collision and
        // layout records. Search only the bounded metadata after the height grid.
        guard data.le32(0) == 0x00485254 else { return nil }
        let columns = Int(data.le32(4))
        let rows = Int(data.le32(8))
        guard (2...4097).contains(columns), (2...4097).contains(rows) else { return nil }
        let start = 24 + columns * rows * 2
        guard start <= footer - 188 else { return nil }
        for header in stride(from: start, through: min(footer - 188, start + 65_536), by: 4) {
            guard data.le32(header) == 0 else { continue }
            let count = Int(data.le32(header + 4))
            guard (3...12_000).contains(count), count <= (footer - header - 8) / recordBytes,
                  let segments = readSegments(data, at: header + 8, count: count, field: field) else { continue }
            return segments
        }
        return nil
    }

    private static func readSegments(_ data: Data, at start: Int, count: Int, field: HeightField) -> [Segment]? {
        var segments: [Segment] = []
        for index in 0..<count {
            let offset = start + index * 60
            func value(_ relative: Int) -> Float { Float(bitPattern: data.le32(offset + relative)) }
            let point = SIMD2<Float>(value(32), value(44))
            let direction = SIMD2<Float>(value(28), value(40))
            let type = data.le32(offset)
            let radius = type == 0 ? 0 : abs(value(8))
            let length = value(4)
            guard type <= 1, (0.1...1500).contains(length), radius.isFinite,
                  (-1...field.width + 1).contains(point.x), (-1...field.length + 1).contains(point.y),
                  abs(simd_length(direction) - 1) < 0.01 else { return nil }
            segments.append(Segment(point: point, direction: direction, length: length, radius: radius))
        }

        let connected = segments.indices.filter { index in
            let segment = segments[index]
            let next = segments[(index + 1) % count].point
            return min(simd_distance(segment.point(at: segment.length, turn: 1), next),
                       simd_distance(segment.point(at: segment.length, turn: -1), next)) < 2.5
        }.count
        return connected >= max(count - 1, Int(ceil(Double(count) * 0.9))) ? segments : nil
    }

    private static func sampledRoute(_ segments: [Segment], field: HeightField) -> [SIMD2<Float>]? {
        var route: [SIMD2<Float>] = []
        for index in segments.indices {
            let segment = segments[index]
            let next = segments[(index + 1) % segments.count].point
            let sign: Float = simd_distance(segment.point(at: segment.length, turn: -1), next)
                < simd_distance(segment.point(at: segment.length, turn: 1), next) ? -1 : 1
            let steps = min(1500, max(1, Int(ceil(segment.length / 0.75))))
            for step in 0..<steps {
                let point = segment.point(at: segment.length * Float(step) / Float(steps), turn: sign)
                if (-1...field.width + 1).contains(point.x), (-1...field.length + 1).contains(point.y) {
                    route.append([point.x / field.width, point.y / field.length])
                }
            }
            if route.count > 40_000 { return nil }
        }
        return route.count >= 16 ? route : nil
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
                            if isGuideColor(color) { return true }
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
                let x = flipX ? right - column : left + column
                let y = flipY ? last - row : top + row
                let color = groundColor(x, y, columns: left...right, rows: top...last)
                pixels.append(UInt8(color.x))
                pixels.append(UInt8(color.y))
                pixels.append(UInt8(color.z))
                pixels.append(255)
            }
        }
        return TrackGroundArt(width: mapWidth, height: mapHeight, pixels: pixels)
    }

    private func isGuideColor(_ color: SIMD3<Int32>) -> Bool {
        color.x > 115 && color.y > 145 && color.z < 85 && color.y > color.x - 24
    }

    // The neon line is a map annotation. Sample the nearby ground before
    // using the overhead image as terrain artwork.
    private func groundColor(_ x: Int, _ y: Int, columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> SIMD3<Int32> {
        let original = rgb(x, y)
        guard isGuideColor(original) else { return original }
        let directions = [SIMD2<Int>(1, 0), [-1, 0], [0, 1], [0, -1], [1, 1], [-1, 1], [1, -1], [-1, -1]]
        for distance in 1...6 {
            var sum = SIMD3<Int32>.zero
            var count: Int32 = 0
            for direction in directions {
                let column = x + direction.x * distance
                let row = y + direction.y * distance
                guard columns.contains(column), rows.contains(row) else { continue }
                let color = rgb(column, row)
                if !isGuideColor(color) {
                    sum = sum &+ color
                    count += 1
                }
            }
            if count > 0 { return sum / count }
        }
        return original
    }

    private func rgb(_ x: Int, _ y: Int) -> SIMD3<Int32> {
        let row = topOrigin ? y : height - y - 1
        let index = offset + (row * width + x) * channels
        return [Int32(data[index + 2]), Int32(data[index + 1]), Int32(data[index])]
    }
}
