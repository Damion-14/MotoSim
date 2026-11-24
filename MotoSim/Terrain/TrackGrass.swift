import Foundation
import simd

struct TrackGrass: Sendable {
    let image: TrackGroundArt
    let maskWidth: Int
    let maskHeight: Int
    let mask: Data
    let density: Float
    let height: Float
    let heightVariation: Float
    let width: Float
    let widthVariation: Float

    static let maxImageSide = 1024
    static let maxMaskSide = 2048

    var isValid: Bool {
        (1...Self.maxImageSide).contains(image.width) && (1...Self.maxImageSide).contains(image.height) &&
        (1...Self.maxMaskSide).contains(maskWidth) && (1...Self.maxMaskSide).contains(maskHeight) &&
        image.pixels.count == image.width * image.height * 4 && mask.count == maskWidth * maskHeight &&
        (0.01...200).contains(density) && (0.01...10).contains(height) && (0...10).contains(heightVariation) &&
        (0.01...10).contains(width) && (0...10).contains(widthVariation)
    }

    struct Placement: Sendable, Equatable {
        let position: SIMD3<Float>
        let angle: Float
        let height: Float
        let width: Float
        let variant: Int
    }

    var variants: Int {
        image.width.isMultiple(of: image.height) ? min(8, image.width / image.height) : 1
    }

    static let cellSize: Float = 12

    func placements(field: HeightField, cell: SIMD2<Int>) throws -> [Placement] {
        let edge = Self.cellSize
        let spacing = 1 / sqrt(min(density, 8))
        let divisions = Int(ceil(edge / spacing))
        var placements: [Placement] = []
        for row in 0..<divisions {
            try Task.checkCancellation()
            for column in 0..<divisions {
                let seed = UInt32(truncatingIfNeeded: cell.x) &* 0x9e3779b9 ^
                    UInt32(truncatingIfNeeded: cell.y) &* 0x85ebca6b ^
                    UInt32(row * divisions + column) &* 0xc2b2ae35
                let dx = (Float(column) + random(seed, 1)) * spacing
                let dz = (Float(row) + random(seed, 2)) * spacing
                guard dx < edge, dz < edge else { continue }
                let x = Float(cell.x) * edge + dx
                let z = Float(cell.y) * edge + dz
                let u = x / field.width + 0.5
                let v = z / field.length + 0.5
                guard (0..<1).contains(u), (0..<1).contains(v) else { continue }
                let maskX = min(maskWidth - 1, Int(u * Float(maskWidth)))
                let maskY = min(maskHeight - 1, Int(v * Float(maskHeight)))
                let coverage = Float(mask[maskY * maskWidth + maskX]) / 255
                guard random(seed, 3) < coverage else { continue }
                placements.append(Placement(position: [x, field.height(x, z) - 0.015, z],
                    angle: random(seed, 4) * .pi,
                    height: max(0.03, height + (random(seed, 5) * 2 - 1) * heightVariation),
                    width: max(0.03, width + (random(seed, 6) * 2 - 1) * widthVariation),
                    variant: min(variants - 1, Int(random(seed, 7) * Float(variants)))))
            }
        }
        return placements
    }

    private func random(_ seed: UInt32, _ salt: UInt32) -> Float {
        var bits = seed &+ salt &* 0x9e3779b9
        bits = (bits ^ (bits >> 16)) &* 0x7feb352d
        bits = (bits ^ (bits >> 15)) &* 0x846ca68b
        return Float((bits ^ (bits >> 16)) & 0xffff) / 65_536
    }
}
