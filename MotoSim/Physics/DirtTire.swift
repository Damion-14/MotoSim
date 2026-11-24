import Foundation
import simd

struct DirtTire {
    private static let longitudinalStiffness: Float = 5.7
    static let longitudinalSlope = longitudinalStiffness * Float.pi / 2
    static func lateralSlope(on surface: TireSurface) -> Float {
        surface.lateralStiffness * .pi / 2
    }

    static func force(slip: Float, slipAngle: Float, camber: Float,
                      load: Float, surface: TireSurface) -> SIMD2<Float> {
        guard load > 0 else { return .zero }
        let demand = SIMD2<Float>(longitudinalStiffness * slip, -surface.lateralStiffness * slipAngle + 0.85 * sin(camber))
        let magnitude = simd_length(demand)
        guard magnitude > 0 else { return .zero }

        // Rolling sideways retains more grip than a locked or rapidly spinning tire.
        let direction = demand / magnitude
        let retainedGrip = surface.lockedGripFraction
            + (surface.lateralGripFraction - surface.lockedGripFraction) * direction.y * direction.y
        let excess = max(0, magnitude - 1)
        let response = magnitude <= 1
            ? sin(magnitude * .pi / 2)
            : retainedGrip + (1 - retainedGrip) * exp(-excess * excess * 0.65)
        return direction * (response * tractionLimit(load: load, grip: surface.peakGrip))
    }

    static func tractionLimit(load: Float, grip: Float) -> Float {
        guard load > 0 else { return 0 }
        let loadSensitivity = min(1.12, max(0.70, pow(load / 850, -0.10)))
        return load * grip * loadSensitivity
    }
}
