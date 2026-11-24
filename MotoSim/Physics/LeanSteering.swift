import Foundation

struct LeanSteering {
    static let gravity: Float = 9.81
    private static let centerLeanGain: Float = 0.66

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
        walkingSteer = -stick * 0.54 / (1 + speed * 0.18)
        let walkingLean = -atan(speed * speed * tan(walkingSteer) / (Self.gravity * wheelbase))
        let t = min(1, max(0, (speed - 2) / 6))
        countersteerBlend = t * t * (3 - 2 * t)
        targetLean = walkingLean + (requestedLean - walkingLean) * countersteerBlend

        // Flat-ground equilibrium gives curvature g*tan(lean)/v². Use the no-slip
        // steering angle as feedforward; the contact forces determine the actual radius.
        let rollingSpeed = max(2, speed)
        turningScale = wheelbase * Self.gravity / (rollingSpeed * rollingSpeed)
        let ridingSteer = max(-0.54, min(0.54, -atan(turningScale * tan(requestedLean))))
        baseSteering = walkingSteer + (ridingSteer - walkingSteer) * countersteerBlend
    }

    func barTarget(actualLean: Float, rollRate: Float) -> Float {
        let supportSteer = -atan(turningScale * tan(actualLean))
        let correction = (targetLean - actualLean) * 0.58 - rollRate * 0.085
        let ridingSteer = supportSteer + correction
        return min(0.54, max(-0.54, walkingSteer + (ridingSteer - walkingSteer) * countersteerBlend))
    }

    static func equilibriumCurvature(lean: Float, speed: Float) -> Float {
        gravity * tan(lean) / (speed * speed)
    }
}
