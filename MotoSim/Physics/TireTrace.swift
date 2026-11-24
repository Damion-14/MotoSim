import Foundation
import simd

struct TireTrace {
    var contact = SIMD3<Float>.zero
    var forward = SIMD3<Float>.zero
    var patchTravel = SIMD3<Float>.zero
    var traction = SIMD3<Float>.zero
    var load: Float = 0
    var gripLimit: Float = 0
    var forwardSpeed: Float = 0
    var sidewaysSpeed: Float = 0
    var treadSpeed: Float = 0

    var slipAngle: Float {
        atan2(sidewaysSpeed, max(0.6, abs(forwardSpeed)))
    }

    var slipRatio: Float {
        (treadSpeed - forwardSpeed) / max(0.6, abs(forwardSpeed))
    }

    func isLocked(brake: Float) -> Bool {
        brake > 0.05 && load > 0 && abs(forwardSpeed) > 2 && abs(treadSpeed) < abs(forwardSpeed) * 0.1
    }
}

struct TireDebugReadout: Equatable {
    struct Wheel: Equatable {
        let load: Int
        let slipDegrees: Int
        let slipPercent: Int
        let gripUsed: Int
        let locked: Bool
        let contact: Bool
        let travelMM: Int
        let speedCM: Int
        let bottomOuts: Int32

        init(_ trace: TireTrace, brake: Float, travel: Float, speed: Float, load: Float, bottomOuts: Int32) {
            contact = load > 0
            travelMM = Int((travel * 1000).rounded())
            speedCM = Int((speed * 100).rounded())
            self.bottomOuts = bottomOuts
            self.load = Int(load.rounded())
            slipDegrees = Int((trace.slipAngle * 180 / .pi).rounded())
            slipPercent = Int((min(9.99, max(-9.99, trace.slipRatio)) * 100).rounded())
            gripUsed = trace.gripLimit > 0
                ? Int((min(1, simd_length(trace.traction) / trace.gripLimit) * 100).rounded()) : 0
            locked = trace.isLocked(brake: brake)
        }
    }

    let front: Wheel
    let rear: Wheel
    let brakePercent: Int
    let barDegrees: Int
    let leanDegrees: Int
    let targetLeanDegrees: Int

    let recordingTouchdown: Bool
    let hasTouchdown: Bool

    init(bike: Motorcycle, brake: Float) {
        let state = bike.state
        front = Wheel(bike.frontTrace, brake: brake, travel: state.compression.x,
                      speed: state.suspensionSpeed.x, load: bike.suspensionLoad.x, bottomOuts: bike.bottomOutCount.x)
        rear = Wheel(bike.rearTrace, brake: brake, travel: state.compression.y,
                     speed: state.suspensionSpeed.y, load: bike.suspensionLoad.y, bottomOuts: bike.bottomOutCount.y)
        let steering = state.steering
        let lean = state.lean
        let targetLean = bike.debugTargetLean
        recordingTouchdown = bike.suspensionTrace.isRecording
        hasTouchdown = bike.suspensionTrace.touchdownStep != nil
        brakePercent = Int((brake * 100).rounded())
        barDegrees = Int((-steering * 180 / .pi).rounded())
        leanDegrees = Int((lean * 180 / .pi).rounded())
        targetLeanDegrees = Int((targetLean * 180 / .pi).rounded())
    }
}
