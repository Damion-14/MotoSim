import RealityKit
import UIKit

@MainActor
final class BikeRenderer {
    let root = Entity()
    private let chassis = Entity()
    private let body = Entity()
    private let swingarm = Entity()
    private let frontSteering = Entity()
    private let frontAxle = Entity()
    private lazy var frontWheel = makeWheel(radius: configuration.frontRadius, width: 0.09)
    private lazy var rearWheel = makeWheel(radius: configuration.rearRadius, width: 0.125)
    private let rearAxle = Entity()
    private let rider = Entity()
    private let riderRestPosition: SIMD3<Float> = [0, 0.25, -0.21]
    private let configuration: BikeConfiguration
    private let metal = SimpleMaterial(color: .init(white: 0.70, alpha: 1), roughness: 0.35, isMetallic: true)
    private let black = SimpleMaterial(color: .init(white: 0.075, alpha: 1), roughness: 0.88, isMetallic: false)
    private let orange = SimpleMaterial(color: .init(red: 1, green: 0.27, blue: 0.04, alpha: 1), isMetallic: false)
    private let white = SimpleMaterial(color: .init(white: 0.94, alpha: 1), isMetallic: false)

    init(configuration: BikeConfiguration) {
        self.configuration = configuration
        root.addChild(chassis)
        chassis.addChild(body)
        chassis.addChild(swingarm)
        root.addChild(frontSteering)
        root.addChild(rearAxle)
        chassis.addChild(rider)
        frontSteering.addChild(frontAxle)
        frontAxle.addChild(frontWheel)
        rearAxle.addChild(rearWheel)

        box([0.27, 0.27, 0.34], [0, -0.10, 0.01], metal, in: body)
        box([0.19, 0.09, 0.72], [0, 0.22, -0.17], black, in: body)
        box([0.26, 0.21, 0.41], [0, 0.12, 0.20], orange, in: body)
        box([0.26, 0.055, 0.46], [0, 0.18, -0.62], orange, in: body)
        box([0.68, 0.035, 0.038], SIMD3<Float>(0, 0.39, 0.51) - configuration.steeringPivot, metal, in: frontSteering)
        box([0.20, 0.23, 0.045], [0, 0.24, 0.62], white, in: body)
        box([0.17, 0.055, 0.43], [0, 0.41, 0.09], orange, in: frontSteering)
        for x: Float in [-0.085, 0.085] {
            let tubeCenter = SIMD3<Float>(x, 0, 0) + configuration.frontCompressionAxis * 0.29
            let tube = box([0.038, 0.60, 0.038], tubeCenter, metal, in: frontAxle)
            tube.orientation = .init(from: [0, 1, 0], to: configuration.frontCompressionAxis)
        }

        for x: Float in [-0.09, 0.09] {
            box([0.043, 0.055, 1], [x, 0, 0.5], metal, in: swingarm)
        }
        rider.position = riderRestPosition
        box([0.26, 0.40, 0.18], [0, 0.24, 0.12], white, in: rider)
        let helmet = ModelEntity(mesh: .generateSphere(radius: 0.116), materials: [orange])
        helmet.position = [0, 0.53, 0.21]
        rider.addChild(helmet)
        box([0.18, 0.061, 0.05], [0, 0.55, 0.31], black, in: rider)
        for x: Float in [-0.14, 0.14] {
            limb(from: [x, 0.36, 0.14], to: [x * 2, 0.15, 0.72], in: rider)
            limb(from: [x * 0.6, 0.14, 0], to: [x, -0.35, 0.21], in: rider)
        }
    }

    func replaceBody(with entity: Entity) {
        body.children.removeAll()
        body.addChild(entity)
    }

    func update(_ pose: BikeState) {
        root.position = pose.position
        root.orientation = pose.orientation
        frontSteering.position = configuration.steeringPivot
        frontSteering.orientation = .init(angle: pose.steering, axis: configuration.frontCompressionAxis)
        frontAxle.position = configuration.frontAxleRest - configuration.steeringPivot
            + configuration.frontCompressionAxis * pose.compression.x
        rearAxle.position = [0, -configuration.axleDrop + pose.compression.y, -configuration.wheelbase / 2]
        let pivot = SIMD3<Float>(0, -0.17, -0.11)
        let swing = rearAxle.position - pivot
        swingarm.position = pivot
        swingarm.orientation = .init(from: [0, 0, 1], to: simd_normalize(swing))
        swingarm.scale.z = simd_length(swing)
        frontWheel.orientation = .init(angle: pose.wheelAngle.x, axis: [1, 0, 0])
        rearWheel.orientation = .init(angle: pose.wheelAngle.y, axis: [1, 0, 0])
        let offset = configuration.riderOffset(weight: pose.riderWeight, lateral: pose.riderLateralWeight)
        rider.position = riderRestPosition + offset * 0.38
        rider.orientation = simd_quatf(angle: pose.riderWeight * 0.28, axis: [1, 0, 0])
            * simd_quatf(angle: pose.riderLateralWeight * 0.32, axis: [0, 0, 1])
    }

    private func makeWheel(radius: Float, width: Float) -> Entity {
        let wheel = Entity()
        let tire = ModelEntity(mesh: .generateCylinder(height: width, radius: radius - 0.018), materials: [black])
        tire.orientation = .init(angle: .pi / 2, axis: [0, 0, 1])
        wheel.addChild(tire)
        for x in [-width / 2, width / 2] {
            let hub = ModelEntity(mesh: .generateCylinder(height: 0.018, radius: radius * 0.59), materials: [metal])
            hub.orientation = tire.orientation
            hub.position.x = x
            wheel.addChild(hub)
        }
        for index in 0..<18 {
            let angle = Float(index) * 2 * .pi / 18
            let knob = box([width * 0.92, 0.028, 0.052],
                           [0, cos(angle) * (radius - 0.014), sin(angle) * (radius - 0.014)],
                           black, in: wheel)
            knob.orientation = .init(angle: angle, axis: [1, 0, 0])
        }
        box([width + 0.041, 0.28, 0.023], .zero, black, in: wheel)
        return wheel
    }

    private func limb(from start: SIMD3<Float>, to end: SIMD3<Float>, in parent: Entity) {
        let part = box([0.078, simd_distance(start, end), 0.083], (start + end) / 2, black, in: parent)
        part.orientation = .init(from: [0, 1, 0], to: simd_normalize(end - start))
    }

    @discardableResult
    private func box(_ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: SimpleMaterial,
                     in parent: Entity) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.16),
                                 materials: [material])
        entity.position = position
        parent.addChild(entity)
        return entity
    }
}
