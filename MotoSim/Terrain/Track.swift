import Foundation
import simd

struct Track: Sendable {
    static let spawn = SIMD3<Float>(0, 0, 31)
    static let spawnHeading = Float.pi / 2

    var name = "MotoSim Circuit"
    var heightField: HeightField?
    var groundArt: TrackGroundArt?
    var grass: TrackGrass?
    var courseLine: [SIMD2<Float>] = []
    var startPosition = Track.spawn
    var startHeading = Track.spawnHeading

    init() {}

    init(name: String, heightField: HeightField) {
        self.name = name
        self.heightField = heightField
        startPosition = .zero
        startHeading = 0
    }

    var halfExtents: SIMD2<Float> {
        heightField.map { [$0.width / 2, $0.length / 2] } ?? [92, 72]
    }

    func contains(_ position: SIMD3<Float>) -> Bool {
        let half = halfExtents
        if heightField != nil { return abs(position.x) < half.x && abs(position.z) < half.y }
        return abs(position.x) <= half.x && abs(position.z) <= half.y
    }

    func coordinates(_ x: Float, _ z: Float) -> (offset: Float, angle: Float) {
        let u = x / 45
        let v = z / 31
        return ((sqrt(u * u + v * v) - 1) * 37, atan2(u, v))
    }

    func height(_ x: Float, _ z: Float) -> Float {
        if let heightField { return heightField.height(x, z) }
        let (offset, angle) = coordinates(x, z)
        let lane = 1 - smooth(3, 7, abs(offset))
        let rise = 1.45 * bump(angle, 0.68, 0.23)
            + 1.8 * bump(angle, -2.6, 0.28)
        let rollers = 0.4 * bump(angle, 2.3, 0.42) * (1 + cos((angle - 2.3) * 42))
        let berm = 0.9 * smooth(2, 6, offset) * (1 - smooth(6, 11, offset))
            * (bump(angle, 1.57, 0.77) + bump(angle, -1.57, 0.77))
        let hills = 0.3 * sin(x * 0.09) * sin(z * 0.13)
        return hills * (1 - 0.92 * lane) + lane * (rise + rollers) + berm
    }

    func normal(_ x: Float, _ z: Float) -> SIMD3<Float> {
        let d: Float = 0.08
        return simd_normalize([height(x - d, z) - height(x + d, z),
                               2 * d, height(x, z - d) - height(x, z + d)])
    }

    func tireSurface(_ x: Float, _ z: Float) -> TireSurface {
        if heightField != nil { return .trackDirt }
        let grass = smooth(4.7, 7, abs(coordinates(x, z).offset))
        return .infieldTransition(grass: grass)
    }

    private func bump(_ angle: Float, _ center: Float, _ width: Float) -> Float {
        1 - smooth(0, width, abs(angle - center))
    }

    private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
