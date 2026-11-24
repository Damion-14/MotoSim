import RealityKit
import UIKit

@MainActor
final class TireVectorRenderer {
    let root = Entity()
    private let front = WheelVectors()
    private let rear = WheelVectors()

    init() {
        root.addChild(front.root)
        root.addChild(rear.root)
    }

    func update(front: TireTrace, rear: TireTrace) {
        self.front.update(front)
        self.rear.update(rear)
    }

    @MainActor
    private final class WheelVectors {
        let root = Entity()
        private let heading = Arrow(color: .systemCyan)
        private let travel = Arrow(color: .white)
        private let force = Arrow(color: .systemOrange)

        init() {
            root.addChild(heading.root)
            root.addChild(travel.root)
            root.addChild(force.root)
        }

        func update(_ trace: TireTrace) {
            root.isEnabled = trace.load > 0
            guard root.isEnabled else { return }
            root.position = trace.contact
            heading.update(origin: [0, 0.09, 0], vector: trace.forward * 1.4)
            travel.update(origin: [0, 0.19, 0], vector: trace.patchTravel * 0.16)
            force.update(origin: [0, 0.30, 0], vector: trace.traction * 0.0013)
        }
    }

    @MainActor
    private final class Arrow {
        let root = Entity()
        private let shaft: ModelEntity
        private let tip: ModelEntity

        init(color: UIColor) {
            let material = UnlitMaterial(color: color)
            shaft = ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.022), materials: [material])
            tip = ModelEntity(mesh: .generateCone(height: 0.15, radius: 0.055), materials: [material])
            for entity in [shaft, tip] {
                entity.components.set(DynamicLightShadowComponent(castsShadow: false))
                root.addChild(entity)
            }
        }

        func update(origin: SIMD3<Float>, vector: SIMD3<Float>) {
            let magnitude = simd_length(vector)
            root.isEnabled = magnitude > 0.065 && magnitude.isFinite
            guard root.isEnabled else { return }
            let length = min(3.2, magnitude)
            let tipLength = min(length * 0.58, 0.15)
            let bodyLength = length - tipLength
            root.position = origin
            root.orientation = .init(from: [0, 1, 0], to: vector / magnitude)
            shaft.position.y = bodyLength / 2
            shaft.scale.y = bodyLength
            tip.position.y = bodyLength + tipLength / 2
            tip.scale.y = tipLength / 0.15
        }
    }
}
