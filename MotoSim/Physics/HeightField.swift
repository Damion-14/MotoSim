import Foundation
import simd

struct HeightField: Sendable {
    let columns: Int
    let rows: Int
    let width: Float
    let length: Float
    let elevationRange: Float
    let samples: [UInt16]
    let elevationBounds: ClosedRange<Float>

    init(columns: Int, rows: Int, width: Float, length: Float, elevationRange: Float, samples: [UInt16]) {
        self.columns = columns
        self.rows = rows
        self.width = width
        self.length = length
        self.elevationRange = elevationRange
        self.samples = samples
        let scale = elevationRange / 65_535
        elevationBounds = Float(samples.min() ?? 0) * scale...Float(samples.max() ?? 0) * scale
    }

    func position(u: Float, v: Float) -> SIMD2<Float> {
        [(u - 0.5) * width, (v - 0.5) * length]
    }

    func height(_ x: Float, _ z: Float) -> Float {
        let column = min(Float(columns - 1), max(0, (x / width + 0.5) * Float(columns - 1)))
        let row = min(Float(rows - 1), max(0, (z / length + 0.5) * Float(rows - 1)))
        let i = min(columns - 2, Int(column))
        let j = min(rows - 2, Int(row))
        let u = column - Float(i)
        let v = row - Float(j)
        let a = Float(samples[j * columns + i])
        let b = Float(samples[j * columns + i + 1])
        let c = Float(samples[(j + 1) * columns + i])
        let d = Float(samples[(j + 1) * columns + i + 1])
        // Match the rendered triangles, whose shared edge joins the top-right and bottom-left vertices.
        let height = u + v <= 1 ? a + (b - a) * u + (c - a) * v
            : d + (c - d) * (1 - u) + (b - d) * (1 - v)
        return height * elevationRange / 65_535
    }
}
