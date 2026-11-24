import Foundation
import simd

enum RidePhysicsMode: String {
    case simulation
    case arcade
}

enum ArcadeHandling {
    // Keep tire contact and suspension in the shared solver. Drive heading and
    // attitude directly here, with a smaller change to the flight path in air.
    static func advance(_ state: inout BikeState, input: RideInput, normal: SIMD3<Float>,
                        loadInBikeWeights: Float, maximumLean: Float, dt: Float) -> Float {
        let grounded = state.contacts > 0
        let steer = bounded(input.steer, limit: 1)
        let weight = bounded(input.weight, limit: 1)
        let horizontalVelocity = SIMD2(state.velocity.x, state.velocity.z)
        let speed = simd_length(horizontalVelocity)
        let groundTurn = min(2.4, 16 / max(1, speed)) * min(1, speed / 2.5)
        let targetYawRate = -steer * (grounded ? groundTurn : 1.65)
        state.yawRate += (targetYawRate - state.yawRate) * (1 - exp(-13 * dt))
        state.heading += state.yawRate * dt

        let leanLimit = min(maximumLean, 0.72)
        let corneringLean = atan(-state.yawRate * speed / LeanSteering.gravity)
        let targetLean = grounded ? bounded(corneringLean, limit: leanLimit) : steer * min(0.45, leanLimit)
        let forward = SIMD3<Float>(sin(state.heading), 0, cos(state.heading))
        let terrainPitch = atan2(simd_dot(normal, forward), normal.y)
        let descending = simd_dot(state.velocity, normal) < 0
        let landingPitch = descending ? bounded(terrainPitch, limit: 0.45) * (1 - abs(weight)) : 0
        let targetPitch = grounded ? bounded(terrainPitch, limit: 0.85) : weight * 0.50 + landingPitch
        state.pitchRate = settle(&state.pitch, toward: targetPitch, limit: 0.95,
                                 response: grounded ? 9 : 7, dt: dt)
        state.rollRate = settle(&state.lean, toward: targetLean, limit: 0.80,
                                response: grounded ? 11 : 9, dt: dt)
        let barAngle = -steer * (grounded ? max(0.12, 0.55 / (1 + speed * 0.16)) : 0.28)
        state.steeringRate = settle(&state.steering, toward: barAngle, limit: LeanSteering.barLock,
                                    response: 17, dt: dt)

        if speed > 0.01 {
            let travelHeading = atan2(horizontalVelocity.x, horizontalVelocity.y)
            let difference = state.heading - travelHeading
            let error = atan2(sin(difference), cos(difference))
            // Rotate momentum gradually. In the air the bike can be aimed for
            // landing while its trajectory still carries through the jump.
            let turn = grounded ? error * (1 - exp(-24 * dt)) : bounded(error * 1.5, limit: 0.65) * dt
            let direction = travelHeading + turn
            state.velocity.x = sin(direction) * speed
            state.velocity.z = cos(direction) * speed
        }

        // Give hard landings extra energy absorption through the rider. This
        // acts on loaded, descending bikes and leaves takeoff velocity alone.
        let closingSpeed = -simd_dot(state.velocity, normal)
        let landingSupport = min(1, max(0, (loadInBikeWeights - 1) / 3))
        let absorption = max(0, closingSpeed - 2.5) * (1 - exp(-20 * landingSupport * dt))
        state.velocity += normal * absorption
        return targetLean
    }

    private static func settle(_ angle: inout Float, toward target: Float, limit: Float,
                               response: Float, dt: Float) -> Float {
        let initial = angle
        angle = bounded(initial + (target - initial) * (1 - exp(-response * dt)), limit: limit)
        return bounded((angle - initial) / dt, limit: 7)
    }

    private static func bounded(_ value: Float, limit: Float) -> Float {
        min(limit, max(-limit, value))
    }
}
