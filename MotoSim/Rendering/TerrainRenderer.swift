import RealityKit
import UIKit

@MainActor
enum TerrainRenderer {
    static func make(_ track: Track, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Entity {
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
        return ModelEntity(mesh: try .generate(from: [mesh]), materials: palette.map {
            SimpleMaterial(color: $0, roughness: 1, isMetallic: false)
        })
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
    ) async throws -> Entity {
        let terrain = Entity()
        var dirt = SimpleMaterial(color: .init(red: 0.56, green: 0.34, blue: 0.22, alpha: 1),
                                  roughness: 1, isMetallic: false)
        if let image = groundArt?.makeImage(),
           let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) {
            dirt.color = .init(tint: .white, texture: .init(texture))
        }
        let tileCells = 128
        let tilesX = (field.columns - 2) / tileCells + 1
        let tilesZ = (field.rows - 2) / tileCells + 1
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let worker = Task.detached(priority: .userInitiated) {
                    try importedTile(field, x: x * tileCells, z: z * tileCells, cells: tileCells)
                }
                let descriptor = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                terrain.addChild(ModelEntity(mesh: try .generate(from: [descriptor]), materials: [dirt]))
                progress(Double(z * tilesX + x + 1) / Double(tilesX * tilesZ))
            }
        }
        return terrain
    }

    private nonisolated static func importedTile(_ field: HeightField, x: Int, z: Int, cells: Int) throws -> MeshDescriptor {
        let columns = min(cells + 1, field.columns - x)
        let rows = min(cells + 1, field.rows - z)
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
        for row in 0..<rows {
            try Task.checkCancellation()
            let j = z + row
            for column in 0..<columns {
                let i = x + column
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
