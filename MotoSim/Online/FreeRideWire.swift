import Foundation
import simd

struct TrackDownload: Codable, Equatable, Sendable {
    let server: URL
    let grant: String
    let sha256: String
}

struct RideStart {
    let position: SIMD2<Float>
    let heading: Float

    func placed(_ input: Track, slot: Int) throws -> Track {
        guard (0..<4).contains(slot), heading.isFinite, abs(heading) < 100,
              position.x.isFinite, position.y.isFinite, input.contains([position.x, 0, position.y]) else {
            throw SharedTrack.Failure.invalid
        }
        let forward = SIMD2<Float>(sin(heading), cos(heading))
        let right = SIMD2<Float>(-forward.y, forward.x)
        let offsets: [SIMD2<Float>] = [.zero, right * 1.15, -forward * 1.5, right * 1.15 - forward * 1.5]
        let half = input.halfExtents
        var origin = position
        for axis in 0..<2 {
            let edges = offsets.map { $0[axis] }
            origin[axis] = min(half[axis] - 0.15 - (edges.max() ?? 0),
                               max(-half[axis] + 0.15 - (edges.min() ?? 0), origin[axis]))
        }
        let start = origin + offsets[slot]
        var track = input
        track.startPosition = [start.x, 0, start.y]
        track.startHeading = heading
        return track
    }
}

struct RideSnapshot: Codable {
    let sequence: UInt32
    let generation: UInt32
    let position: SIMD3<Float>
    let velocity: SIMD3<Float>
    let angles: SIMD3<Float>
    let steering: Float
    let wheelSpeed: SIMD2<Float>
    let wheelAngle: SIMD2<Float>
    let travel: SIMD2<Float>
    let rider: SIMD2<Float>

    init(_ pose: BikeState, sequence: UInt32, generation: UInt32) {
        self.sequence = sequence
        self.generation = generation
        position = pose.position
        velocity = pose.velocity
        angles = [pose.heading, pose.pitch, pose.lean]
        steering = pose.steering
        wheelSpeed = pose.wheelSpeed
        wheelAngle = pose.wheelAngle
        travel = pose.compression
        rider = [pose.riderWeight, pose.riderLateralWeight]
    }

    var isValid: Bool {
        func bounded<V: SIMD>(_ vector: V, by limit: Float) -> Bool where V.Scalar == Float {
            (0..<V.scalarCount).allSatisfy { abs(vector[$0]) <= limit }
        }
        return bounded(position, by: 20_000) && bounded(velocity, by: 200) && bounded(angles, by: 50_000) &&
            abs(steering) <= 0.55 && bounded(wheelSpeed, by: 2_000) && bounded(wheelAngle, by: 10_000_000) &&
            (0...0.310).contains(travel.x) && (0...0.300).contains(travel.y) && bounded(rider, by: 1.01)
    }

    func blend(to next: Self, progress t: Float) -> BikeState {
        var pose = BikeState()
        func angle(_ a: Float, _ b: Float) -> Float {
            a + (b - a).remainder(dividingBy: 2 * .pi) * t
        }
        pose.position = position + (next.position - position) * t
        pose.velocity = velocity + (next.velocity - velocity) * t
        pose.heading = angle(angles.x, next.angles.x)
        pose.pitch = angle(angles.y, next.angles.y)
        pose.lean = angle(angles.z, next.angles.z)
        pose.steering = steering + (next.steering - steering) * t
        pose.wheelSpeed = wheelSpeed + (next.wheelSpeed - wheelSpeed) * t
        pose.wheelAngle = wheelAngle + (next.wheelAngle - wheelAngle) * t
        pose.compression = travel + (next.travel - travel) * t
        let rider = rider + (next.rider - rider) * t
        pose.riderWeight = rider.x
        pose.riderLateralWeight = rider.y
        return pose
    }
}

struct RemoteBikeMotion {
    private struct Frame {
        let received: TimeInterval
        let snapshot: RideSnapshot
    }

    private var frames: [Frame] = []
    private static let delay: TimeInterval = 0.10

    mutating func receive(_ snapshot: RideSnapshot, at time: TimeInterval) {
        guard snapshot.isValid else { return }
        if let last = frames.last?.snapshot {
            guard snapshot.sequence > last.sequence, snapshot.generation >= last.generation else { return }
            if snapshot.generation != last.generation { frames.removeAll(keepingCapacity: true) }
        }
        frames.append(Frame(received: time, snapshot: snapshot))
        if frames.count > 12 { frames.removeFirst() }
    }

    func pose(at time: TimeInterval) -> BikeState? {
        guard let first = frames.first, let last = frames.last else { return nil }
        let target = time - Self.delay
        guard let nextIndex = frames.firstIndex(where: { $0.received > target }) else {
            return last.snapshot.blend(to: last.snapshot, progress: 0)
        }
        guard nextIndex > 0 else { return first.snapshot.blend(to: first.snapshot, progress: 0) }
        let previous = frames[nextIndex - 1]
        let next = frames[nextIndex]
        let t = Float((target - previous.received) / (next.received - previous.received))
        return previous.snapshot.blend(to: next.snapshot, progress: t)
    }
}
