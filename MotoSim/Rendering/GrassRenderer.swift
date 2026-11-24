import RealityKit
import UIKit

@MainActor
final class GrassRenderer {
    let root = Entity()
    private let field: HeightField
    private let grass: TrackGrass
    private let material: PhysicallyBasedMaterial
    private var desiredCell: SIMD2<Int>?
    private var worker: Task<Void, Never>?
    private var model: ModelEntity?

    static func make(field: HeightField, grass: TrackGrass) async throws -> GrassRenderer? {
        guard let color = grass.image.makeImage(), let opacity = opacityImage(grass.image) else { return nil }
        let colorTexture = try await TextureResource(image: color, options: .init(semantic: .color))
        let alphaTexture = try await TextureResource(image: opacity, options: .init(semantic: .raw))
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(colorTexture))
        material.blending = .transparent(opacity: .init(scale: 1, texture: .init(alphaTexture)))
        material.opacityThreshold = 0.43
        material.faceCulling = .none
        material.roughness = .init(floatLiteral: 1)
        material.specular = .init(floatLiteral: 0)
        return GrassRenderer(field: field, grass: grass, material: material)
    }

    private init(field: HeightField, grass: TrackGrass, material: PhysicallyBasedMaterial) {
        self.field = field
        self.grass = grass
        self.material = material
    }

    func update(near position: SIMD3<Float>) {
        let cell = SIMD2(Int(floor(position.x / TrackGrass.cellSize)), Int(floor(position.z / TrackGrass.cellSize)))
        guard cell != desiredCell else { return }
        desiredCell = cell
        if worker == nil {
            worker = Task { [weak self] in await self?.updateMesh() }
        }
    }

    func cancel() { worker?.cancel() }

    private func updateMesh() async {
        defer { worker = nil }
        while !Task.isCancelled, let cell = desiredCell {
            let field = self.field
            let grass = self.grass
            let build = Task.detached(priority: .utility) {
                try Self.mesh(field: field, grass: grass, center: cell)
            }
            let descriptor = try? await withTaskCancellationHandler {
                try await build.value
            } onCancel: {
                build.cancel()
            }
            guard !Task.isCancelled else { return }
            guard cell == desiredCell else { continue }
            model?.removeFromParent()
            model = nil
            if let descriptor, let mesh = try? MeshResource.generate(from: [descriptor]) {
                let plant = ModelEntity(mesh: mesh, materials: [material])
                plant.components.set(DynamicLightShadowComponent(castsShadow: false))
                root.addChild(plant)
                model = plant
            }
            return
        }
    }

    private nonisolated static func mesh(field: HeightField, grass: TrackGrass, center: SIMD2<Int>) throws -> MeshDescriptor? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for z in -1...1 {
            for x in -1...1 {
                let plants = try grass.placements(field: field, cell: center &+ [x, z])
                for plant in plants {
                    let u0 = (Float(plant.variant) + 0.002) / Float(grass.variants)
                    let u1 = (Float(plant.variant + 1) - 0.002) / Float(grass.variants)
                    let up = SIMD3<Float>(0, plant.height, 0)
                    for offset: Float in [0, .pi / 2] {
                        let angle = plant.angle + offset
                        let across = SIMD3<Float>(cos(angle), 0, sin(angle)) * (plant.width / 2)
                        let a = plant.position - across
                        let b = plant.position + across
                        let i = UInt32(positions.count)
                        positions.append(contentsOf: [a, b, a + up, b + up])
                        normals.append(contentsOf: Array(repeating: [0, 1, 0], count: 4))
                        // The compiled atlas stores each clump with its roots in the first row.
                        uv.append(contentsOf: [[u0, 1], [u1, 1], [u0, 0], [u1, 0]])
                        indices.append(contentsOf: [i, i + 1, i + 2, i + 1, i + 3, i + 2])
                    }
                }
            }
        }
        guard !indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "Track-authored grass")
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.textureCoordinates = .init(uv)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    private static func opacityImage(_ source: TrackGroundArt) -> CGImage? {
        let bytes = source.pixels.withUnsafeBytes { (pixels: UnsafeRawBufferPointer) in
            Data(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] })
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: source.width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: source.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
