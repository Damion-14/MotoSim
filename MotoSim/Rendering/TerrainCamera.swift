import simd

extension Track {
    func minimumCameraHeight(from camera: SIMD3<Float>, lookingAt focus: SIMD3<Float>) -> Float {
        var required = height(camera.x, camera.z) + 0.85
        for sample in 1..<12 {
            let t = Float(sample) / 12
            let point = camera + (focus - camera) * t
            let clearance = 0.55 * (1 - t) + 0.12
            let ground = height(point.x, point.z) + clearance
            required = max(required, (ground - t * focus.y) / (1 - t))
        }
        return required
    }
}
