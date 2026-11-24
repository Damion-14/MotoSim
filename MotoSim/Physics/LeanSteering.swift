import Foundation

struct LeanSteering {
    static let gravity: Float = 9.81
    static let barLock: Float = 0.62
    private static let centerLeanGain: Float = 0.74

    let targetLean: Float
    let baseSteering: Float
    let countersteerBlend: Float
    private let walkingSteer: Float
    private let turningScale: Float

    init(input: Float, speed: Float, wheelbase: Float, maximumLean: Float = RideTuning().maximumLeanRadians) {
        let stick = min(1, max(-1, input))
        // Add most of the extra lean near the outer end of the stick travel.
        let centerGain = min(Self.centerLeanGain, maximumLean)
        let gain = centerGain + (maximumLean - centerGain) * stick * stick
        let requestedLean = stick * gain

        // Rider-right is positive roll and negative front wheel yaw in our +Z-forward frame.
        walkingSteer = -stick * Self.barLock / (1 + speed * 0.18)
        let walkingLean = -atan(speed * speed * tan(walkingSteer) / (Self.gravity * wheelbase))
        let t = min(1, max(0, (speed - 2) / 6))
        countersteerBlend = t * t * (3 - 2 * t)
        targetLean = walkingLean + (requestedLean - walkingLean) * countersteerBlend

        // Flat-ground equilibrium gives curvature g*tan(lean)/v². Use the no-slip
        // steering angle as feedforward; the contact forces determine the actual radius.
        let rollingSpeed = max(2, speed)
        turningScale = wheelbase * Self.gravity / (rollingSpeed * rollingSpeed)
        let ridingSteer = max(-Self.barLock, min(Self.barLock, -atan(turningScale * tan(requestedLean))))
        baseSteering = walkingSteer + (ridingSteer - walkingSteer) * countersteerBlend
    }

    func barTarget(actualLean: Float, rollRate: Float) -> Float {
        let supportSteer = -atan(turningScale * tan(actualLean))
        let correction = (targetLean - actualLean) * 0.67 - rollRate * 0.10
        let ridingSteer = supportSteer + correction
        return min(Self.barLock, max(-Self.barLock, walkingSteer + (ridingSteer - walkingSteer) * countersteerBlend))
    }

    static func equilibriumCurvature(lean: Float, speed: Float) -> Float {
        gravity * tan(lean) / (speed * speed)
    }
}

enum StraightLineSteering {
    // Discrete LQR gains from central differences of MotoSim's 240 Hz
    // physics step on level dirt at default setup. The state cost weights
    // lean, roll rate, bar angle, bar rate, yaw rate, and lateral speed in
    // that order. Q = diag(180, 10, 260, 2, 220, 24), R = 0.015.
    private static let gains: [(speed: Float, weights: SIMD8<Float>)] = [
        (8,  [79.441, 29.834,  71.176, 13.227,  74.837, 17.120, 0, 0]),
        (12, [80.515, 25.534,  80.061, 14.703,  85.311, 11.734, 0, 0]),
        (18, [79.806, 19.474,  94.319, 16.608, 101.630,  4.700, 0, 0]),
        (24, [79.464, 13.838, 107.927, 18.183, 117.456, -0.625, 0, 0]),
        (30, [78.861,  8.500, 120.167, 19.494, 132.564, -4.789, 0, 0]),
        (36, [78.035,  3.440, 130.750, 20.595, 146.794, -8.184, 0, 0])
    ]

    static func authority(speed: Float, stick: Float) -> Float {
        let speedBlend = smoothUnit((speed - 8) / 6)
        let neutralBlend = 1 - smoothUnit((abs(stick) - 0.03) / 0.12)
        return speedBlend * neutralBlend
    }

    static func torque(state: BikeState, speed: Float, lateralSpeed: Float) -> Float {
        var weights = gains[gains.count - 1].weights
        for (lower, upper) in zip(gains, gains.dropFirst()) where speed <= upper.speed {
            let fraction = max(0, (speed - lower.speed) / (upper.speed - lower.speed))
            weights = lower.weights + (upper.weights - lower.weights) * fraction
            break
        }
        let feedback = SIMD8(state.lean, state.rollRate, state.steering, state.steeringRate,
                             state.yawRate, lateralSpeed, 0, 0)
        return min(45, max(-45, -(weights * feedback).sum()))
    }

    private static func smoothUnit(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
