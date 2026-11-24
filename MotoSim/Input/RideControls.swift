import CoreMotion
import GameController
import UIKit

@MainActor
final class RideControls {
    var touch = RideInput()
    private let motion = CMMotionManager()
    private var tiltReference: Double?
    private var tiltDirection: Double = 1

    var input: RideInput {
        if let gamepad = GCController.current?.extendedGamepad {
            return RideInput(steer: gamepad.leftThumbstick.xAxis.value,
                             throttle: gamepad.rightTrigger.value,
                             brake: gamepad.leftTrigger.value,
                             weight: riderAxis(gamepad.rightThumbstick.yAxis.value),
                             lateralWeight: riderAxis(gamepad.rightThumbstick.xAxis.value))
        }
        var result = touch
        if let acceleration = motion.deviceMotion?.gravity.y {
            let reference = tiltReference ?? acceleration
            tiltReference = reference
            result.steer = min(1, max(-1, Float((reference - acceleration) * tiltDirection * 2.9)))
        }
        return result
    }

    @discardableResult
    func setTilt(_ enabled: Bool) -> Bool {
        tiltReference = nil
        if enabled && motion.isDeviceMotionAvailable {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })
            if #available(iOS 26, *) {
                tiltDirection = window?.effectiveGeometry.interfaceOrientation == .landscapeLeft ? -1 : 1
            } else {
                tiltDirection = window?.interfaceOrientation == .landscapeLeft ? -1 : 1
            }
            motion.deviceMotionUpdateInterval = 1 / 60
            motion.startDeviceMotionUpdates()
        } else {
            motion.stopDeviceMotionUpdates()
        }
        return motion.isDeviceMotionActive
    }

    private func riderAxis(_ value: Float) -> Float {
        let magnitude = max(0, abs(value) - 0.10) / 0.90
        return value < 0 ? -magnitude : magnitude
    }

    func releaseTouch() {
        touch = RideInput()
    }
}
