import Foundation
import simd

struct TireContactFrame {
    let forward: SIMD3<Float>
    let lateral: SIMD3<Float>
    let camber: Float

    init(wheel: simd_quatf, normal: SIMD3<Float>) {
        let spinAxis = wheel.act([1, 0, 0])
        // The rolling direction lies in both the road plane and the wheel plane.
        let tangent = simd_cross(spinAxis, normal)
        if simd_length_squared(tangent) < 0.000001 {
            let wheelForward = wheel.act([0, 0, 1])
            forward = simd_normalize(wheelForward - normal * simd_dot(wheelForward, normal))
        } else {
            forward = simd_normalize(tangent)
        }
        lateral = simd_cross(normal, forward)
        // Positive spin-axis tilt corresponds to lean toward -lateral.
        camber = -asin(min(1, max(-1, simd_dot(spinAxis, normal))))
    }
}
