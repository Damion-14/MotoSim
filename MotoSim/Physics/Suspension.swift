import Foundation

struct Suspension {
    static let tireRate: Float = 155_000
    static let tireDamping: Float = 1_000

    let front: Bool
    var travel: Float { front ? 0.310 : 0.300 }
    var unsprungMass: Float { front ? 10 : 14 }

    // Estimated linkage geometry. The derivative of shock stroke with respect to
    // wheel travel converts both wheel speed to shaft speed and shaft force to wheel force.
    func motionRatio(at compression: Float) -> Float {
        front ? 1 : 0.320 + 0.15 * compression / travel
    }

    func springForce(at compression: Float, tuning: RideTuning) -> Float {
        if front {
            let installedPreload: Float = 0.015
            let rateNewtonsPerMeter = Float(tuning.selectedForkSpringRate) * 1000
            return rateNewtonsPerMeter * (compression + installedPreload)
        }
        let shockStroke = compression * (0.320 + 0.075 * compression / travel)
        return 45_000 * (shockStroke + tuning.preloadMeters) * motionRatio(at: compression)
    }

    func damperForce(at compression: Float, speed: Float, tuning: RideTuning) -> Float {
        let ratio = motionRatio(at: compression)
        let shaftSpeed = speed * ratio
        let endStroke = max(0, (compression / travel - 0.75) / 0.25)
        if shaftSpeed < 0 {
            // Rebound support near sag controls chassis oscillation. The shallower
            // high-speed slope lets the wheel extend into holes and between bumps.
            let knee: Float = front ? 0.65 : 0.25
            let extensionSpeed = -shaftSpeed
            let low = min(knee, extensionSpeed) * (front ? 2_900 : 24_000)
            let high = max(0, extensionSpeed - knee) * (front ? 1_200 : 20_500)
            // Slow the release of the bump stop after a deep landing.
            let bottomStopRecovery = 7_000 * endStroke * endStroke * abs(speed)
            return -((low + high) * ratio + bottomStopRecovery) * tuning.reboundScale(front: front)
        }
        // Hydraulic bottoming resistance ramps in over the last 25% of travel.
        let bottoming = 1_600 * endStroke * endStroke * speed
        if front {
            let knee: Float = 0.70
            let low = min(knee, shaftSpeed) * 1_000
            let high = max(0, shaftSpeed - knee) * 2_800
            return (low + high) * tuning.compressionScale(tuning.forkCompression) + bottoming
        }
        let knee: Float = 0.30
        let low = min(knee, shaftSpeed) * 9_000 * tuning.compressionScale(tuning.shockLowSpeedCompression)
        let high = max(0, shaftSpeed - knee) * 14_500 * tuning.compressionScale(tuning.shockHighSpeedCompression)
        return (low + high) * ratio + bottoming
    }

    // Damping opposes motion, so the implicit speed is between zero and free speed.
    func implicitDamperForce(at compression: Float, freeSpeed: Float, response: Float,
                             tuning: RideTuning) -> Float {
        var low = min(0, freeSpeed)
        var high = max(0, freeSpeed)
        for _ in 0..<14 {
            let speed = (low + high) / 2
            let force = damperForce(at: compression, speed: speed, tuning: tuning)
            if speed + force * response > freeSpeed {
                high = speed
            } else {
                low = speed
            }
        }
        return damperForce(at: compression, speed: (low + high) / 2, tuning: tuning)
    }

    func bumpForce(at compression: Float) -> Float {
        let bump = max(0, compression - travel * 0.82)
        let top = max(0, 0.012 - compression)
        // Leave most of the landing energy dissipation to the damper.
        return 1_200_000 * bump * bump - 7_000_000 * top * top
    }

    func deflection(supporting force: Float, tuning: RideTuning) -> Float {
        var low: Float = 0
        var high = travel
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if springForce(at: middle, tuning: tuning) + bumpForce(at: middle) < force {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }
}
