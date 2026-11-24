import RealityKit
import UIKit

@MainActor
enum TerrainRenderer {
    struct Surface {
        let entity: Entity
        var detail: TileDetail? = nil
    }

    static func make(_ track: Track, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Surface {
        if let field = track.heightField { return try await makeImported(field, groundArt: track.groundArt, progress: progress) }
        let worker = Task.detached(priority: .userInitiated) {
            try await buildMesh(track, progress: progress)
        }
        let mesh = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        let palette: [UIColor] = [
            .init(red: 0.56, green: 0.32, blue: 0.17, alpha: 1),
            .init(red: 0.52, green: 0.29, blue: 0.15, alpha: 1),
            .init(red: 0.43, green: 0.28, blue: 0.16, alpha: 1),
            .init(red: 0.36, green: 0.38, blue: 0.22, alpha: 1),
            .init(red: 0.34, green: 0.36, blue: 0.20, alpha: 1)
        ]
        return Surface(entity: ModelEntity(mesh: try .generate(from: [mesh]), materials: palette.map {
            SimpleMaterial(color: $0, roughness: 1, isMetallic: false)
        }))
    }

    private nonisolated static func buildMesh(
        _ track: Track, progress: @MainActor @Sendable (Double) -> Void
    ) async throws -> MeshDescriptor {
        let columns = 401
        let rows = 321
        let spacing: Float = 0.5
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var materials: [UInt32] = []
        positions.reserveCapacity(rows * columns)
        normals.reserveCapacity(rows * columns)
        indices.reserveCapacity((rows - 1) * (columns - 1) * 6)
        materials.reserveCapacity((rows - 1) * (columns - 1) * 2)
        for row in 0..<rows {
            if row.isMultiple(of: 32) {
                try Task.checkCancellation()
                await progress(Double(row) / Double(rows))
            }
            let z = Float(row - rows / 2) * spacing
            for column in 0..<columns {
                let x = Float(column - columns / 2) * spacing
                positions.append([x, track.height(x, z), z])
                normals.append(track.normal(x, z))
                guard row < rows - 1, column < columns - 1 else { continue }
                let a = UInt32(row * columns + column)
                let b = a + 1
                let c = a + UInt32(columns)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
                let offset = abs(track.coordinates(x + spacing / 2, z + spacing / 2).offset)
                let noise = (row * 8317 ^ column * 3499) % 29
                let color: UInt32
                if offset < 4.7 {
                    color = noise < 5 ? 1 : 0
                } else if offset < 6.5 {
                    color = 2
                } else {
                    color = noise < 5 ? 4 : 3
                }
                materials.append(contentsOf: [color, color])
            }
        }
        var mesh = MeshDescriptor(name: "Dirt circuit")
        mesh.positions = MeshBuffers.Positions(positions)
        mesh.normals = MeshBuffers.Normals(normals)
        mesh.primitives = .triangles(indices)
        mesh.materials = .perFace(materials)
        return mesh
    }

    private static func makeImported(
        _ field: HeightField, groundArt: TrackGroundArt?, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Surface {
        let terrain = Entity()
        var dirt = SimpleMaterial(color: .init(white: 0.52, alpha: 1), roughness: 1, isMetallic: false)
        if let image = groundArt?.makeImage(),
           let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) {
            dirt.color = .init(tint: .white, texture: .init(texture))
        }
        let tiledDetail = max(field.columns, field.rows) > 2049
        let tileCells = tiledDetail ? 256 : 128
        let tilesX = (field.columns - 2) / tileCells + 1
        let tilesZ = (field.rows - 2) / tileCells + 1
        var base: [SIMD2<Int>: ModelEntity] = [:]
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let tile = SIMD2(x, z)
                let descriptor = try await buildTile(field, tile: tile, cells: tileCells,
                                                     step: tiledDetail ? 2 : 1, skirts: tiledDetail)
                try Task.checkCancellation()
                let model = ModelEntity(mesh: try .generate(from: [descriptor]), materials: [dirt])
                terrain.addChild(model)
                if tiledDetail { base[tile] = model }
                progress(Double(z * tilesX + x + 1) / Double(tilesX * tilesZ))
            }
        }
        let detail = tiledDetail ? TileDetail(field: field, base: base, material: dirt, cells: tileCells) : nil
        return Surface(entity: terrain, detail: detail)
    }

    // Keep full-resolution tiles around the rider on large grids. The view
    // toggles each tile to its finer mesh only once that mesh is available.
    @MainActor
    final class TileDetail {
        private let field: HeightField
        private let base: [SIMD2<Int>: ModelEntity]
        private let material: SimpleMaterial
        private let cells: Int
        private var fine: [SIMD2<Int>: ModelEntity] = [:]
        private var center: SIMD2<Int>?
        private var desired: [SIMD2<Int>] = []
        private var worker: Task<Void, Never>?

        init(field: HeightField, base: [SIMD2<Int>: ModelEntity], material: SimpleMaterial, cells: Int) {
            self.field = field
            self.base = base
            self.material = material
            self.cells = cells
        }

        func update(near position: SIMD3<Float>) {
            let column = max(0, min(field.columns - 2,
                                    Int((position.x / field.width + 0.5) * Float(field.columns - 1))))
            let row = max(0, min(field.rows - 2,
                                 Int((position.z / field.length + 0.5) * Float(field.rows - 1))))
            let tile = SIMD2(column / cells, row / cells)
            guard tile != center else { return }
            center = tile
            let neighbors: [SIMD2<Int>] = [.zero, [-1, 0], [0, -1], [1, 0], [0, 1],
                                            [-1, -1], [1, -1], [-1, 1], [1, 1]]
            desired = neighbors.map { tile &+ $0 }.filter { base[$0] != nil }
            for key in fine.keys.filter({ !desired.contains($0) }) {
                fine.removeValue(forKey: key)?.removeFromParent()
                base[key]?.isEnabled = true
            }
            if worker == nil {
                worker = Task { [weak self] in
                    await self?.loadDesired()
                }
            }
        }

        private func loadDesired() async {
            defer { worker = nil }
            var failed: Set<SIMD2<Int>> = []
            while !Task.isCancelled, let tile = desired.first(where: { fine[$0] == nil && !failed.contains($0) }),
                  let coarse = base[tile] {
                do {
                    let descriptor = try await TerrainRenderer.buildTile(field, tile: tile, cells: cells, step: 1, skirts: true)
                    try Task.checkCancellation()
                    guard desired.contains(tile), let parent = coarse.parent else { continue }
                    let model = ModelEntity(mesh: try .generate(from: [descriptor]), materials: [material])
                    parent.addChild(model)
                    fine[tile] = model
                    coarse.isEnabled = false
                } catch is CancellationError {
                    return
                } catch {
                    failed.insert(tile)
                }
            }
        }

        func cancel() { worker?.cancel() }
    }

    private static func buildTile(_ field: HeightField, tile: SIMD2<Int>, cells: Int,
                                  step: Int, skirts: Bool) async throws -> MeshDescriptor {
        let worker = Task.detached(priority: .userInitiated) {
            try importedTile(field, x: tile.x * cells, z: tile.y * cells, cells: cells, step: step, skirts: skirts)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func importedTile(_ field: HeightField, x: Int, z: Int, cells: Int,
                                                 step: Int, skirts: Bool) throws -> MeshDescriptor {
        let endX = min(x + cells, field.columns - 1)
        let endZ = min(z + cells, field.rows - 1)
        let columnSamples = Array(stride(from: x, to: endX, by: step)) + [endX]
        let rowSamples = Array(stride(from: z, to: endZ, by: step)) + [endZ]
        let columns = columnSamples.count
        let rows = rowSamples.count
        let dx = field.width / Float(field.columns - 1)
        let dz = field.length / Float(field.rows - 1)
        let heightScale = field.elevationRange / 65_535
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(columns * rows)
        normals.reserveCapacity(columns * rows)
        uv.reserveCapacity(columns * rows)
        indices.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for (row, j) in rowSamples.enumerated() {
            try Task.checkCancellation()
            for (column, i) in columnSamples.enumerated() {
                let u = Float(i) / Float(field.columns - 1)
                let v = Float(j) / Float(field.rows - 1)
                let point = field.position(u: u, v: v)
                uv.append([u, 1 - v])
                let index = j * field.columns + i
                positions.append([point.x, Float(field.samples[index]) * heightScale, point.y])
                let left = max(0, i - 1)
                let right = min(field.columns - 1, i + 1)
                let top = max(0, j - 1)
                let bottom = min(field.rows - 1, j + 1)
                let slopeX = (Float(field.samples[j * field.columns + right])
                              - Float(field.samples[j * field.columns + left])) * heightScale / (Float(right - left) * dx)
                let slopeZ = (Float(field.samples[bottom * field.columns + i])
                              - Float(field.samples[top * field.columns + i])) * heightScale / (Float(bottom - top) * dz)
                normals.append(simd_normalize([-slopeX, 1, -slopeZ]))
                guard row < rows - 1, column < columns - 1 else { continue }
                let a = UInt32(row * columns + column)
                let b = a + 1
                let c = a + UInt32(columns)
                indices.append(contentsOf: [a, c, b, b, c, c + 1])
            }
        }
        if skirts {
            // Cover the height difference where a fine edge meets a coarser
            // one. Size each skirt to the maximum skipped-sample error.
            func height(_ column: Int, _ row: Int) -> Float {
                Float(field.samples[row * field.columns + column]) * heightScale
            }
            func error(from: Int, to: Int, sample: (Int) -> Float) -> Float {
                stride(from: from + 1, to: to, by: 2).reduce(0) { largest, i in
                    max(largest, abs(sample(i) - (sample(i - 1) + sample(i + 1)) / 2))
                }
            }
            func skirt(_ edge: [Int], depth: Float, outward: SIMD3<Float>) {
                guard depth > 0.001 else { return }
                let start = UInt32(positions.count)
                for index in edge {
                    positions.append(positions[index])
                    positions.append(positions[index] - [0, depth + 0.015, 0])
                    normals.append(contentsOf: [outward, outward])
                    let coordinate = uv[index]
                    uv.append(contentsOf: [coordinate, coordinate])
                }
                for segment in 0..<(edge.count - 1) {
                    let a = start + UInt32(segment * 2)
                    let b = a + 1
                    let c = a + 2
                    let d = a + 3
                    indices.append(contentsOf: [a, c, b, b, c, d, b, c, a, d, c, b])
                }
            }
            skirt(Array(0..<columns), depth: error(from: x, to: endX) { height($0, z) }, outward: [0, 0, -1])
            skirt((0..<rows).map { $0 * columns + columns - 1 },
                  depth: error(from: z, to: endZ) { height(endX, $0) }, outward: [1, 0, 0])
            skirt(Array(((rows - 1) * columns..<(rows * columns)).reversed()),
                  depth: error(from: x, to: endX) { height($0, endZ) }, outward: [0, 0, 1])
            skirt((0..<rows).reversed().map { $0 * columns },
                  depth: error(from: z, to: endZ) { height(x, $0) }, outward: [-1, 0, 0])
        }
        var mesh = MeshDescriptor(name: "Imported terrain")
        mesh.positions = MeshBuffers.Positions(positions)
        mesh.normals = MeshBuffers.Normals(normals)
        mesh.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
        mesh.primitives = .triangles(indices)
        return mesh
    }

    static func addMarkers(to root: Entity, track: Track) {
        let white = SimpleMaterial(color: .init(white: 0.94, alpha: 1), isMetallic: false)
        let red = SimpleMaterial(color: .systemOrange, isMetallic: false)
        for index in 0..<36 {
            let angle = Float(index) * 2 * .pi / 36
            for scale: Float in [0.86, 1.14] {
                let x = sin(angle) * 45 * scale
                let z = cos(angle) * 31 * scale
                let y = track.height(x, z)
                let pole = ModelEntity(mesh: .generateCylinder(height: 0.86, radius: 0.045), materials: [white])
                pole.position = [x, y + 0.43, z]
                let marker = ModelEntity(mesh: .generateBox(size: [0.22, 0.14, 0.22]), materials: [red])
                marker.position = [0, 0.34, 0]
                pole.addChild(marker)
                root.addChild(pole)
            }
        }
    }
}
