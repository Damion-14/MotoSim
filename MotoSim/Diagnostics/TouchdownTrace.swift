import Foundation

struct TouchdownTrace {
    struct Sample {
        let step: Int
        let travel: SIMD2<Float>
        let speed: SIMD2<Float>
        let load: SIMD2<Float>
        let bottomOuts: SIMD2<Int32>
        let chassisHeight: Float
        let chassisVerticalSpeed: Float
        let pitchRate: Float
        let heading: Float
        let lean: Float
        let yawRate: Float
        let rollRate: Float
        let steering: Float
        let velocityX: Float
        let velocityZ: Float
        let patchSidewaysSpeed: SIMD2<Float>
    }

    // At 240 Hz, retain 250 ms before touchdown and 750 ms after it.
    private static let before = 60
    private static let after = 180
    private var history: [Sample] = []
    private var cursor = 0
    private var airborneSteps = 0
    private(set) var touchdownStep: Int?
    private(set) var isRecording = false
    private(set) var samples: [Sample] = []

    mutating func finishRecording() {
        isRecording = false
        history.removeAll(keepingCapacity: true)
        cursor = 0
        airborneSteps = 0
    }

    mutating func record(step: Int, state: BikeState, load: SIMD2<Float>, bottomOuts: SIMD2<Int32>,
                         patchSidewaysSpeed: SIMD2<Float>) {
        let sample = Sample(step: step, travel: state.compression, speed: state.suspensionSpeed,
                            load: load, bottomOuts: bottomOuts, chassisHeight: state.position.y,
                            chassisVerticalSpeed: state.velocity.y, pitchRate: state.pitchRate,
                            heading: state.heading, lean: state.lean, yawRate: state.yawRate,
                            rollRate: state.rollRate, steering: state.steering,
                            velocityX: state.velocity.x, velocityZ: state.velocity.z,
                            patchSidewaysSpeed: patchSidewaysSpeed)
        let airborne = load == .zero
        if isRecording {
            samples.append(sample)
            if let touchdownStep, step - touchdownStep >= Self.after { isRecording = false }
        } else if !airborne && airborneSteps >= 12 {
            touchdownStep = step
            isRecording = true
            samples = Array(history[cursor...]) + history[..<cursor]
            samples.append(sample)
        }
        airborneSteps = airborne ? airborneSteps + 1 : 0
        if history.count < Self.before {
            history.append(sample)
        } else {
            history[cursor] = sample
            cursor = (cursor + 1) % Self.before
        }
    }

    var csv: String {
        guard let touchdownStep else { return "" }
        var rows = ["time_s,front_travel_mm,rear_travel_mm,front_speed_m_s,rear_speed_m_s,front_load_n,rear_load_n,front_bottom_outs,rear_bottom_outs,chassis_height_m,chassis_vertical_speed_m_s,chassis_pitch_rate_rad_s"]
        rows[0] += ",heading_rad,lean_rad,yaw_rate_rad_s,roll_rate_rad_s,steering_rad,velocity_x_m_s,velocity_z_m_s,front_patch_side_speed_m_s,rear_patch_side_speed_m_s"
        let initialBottomOuts = samples.first?.bottomOuts ?? .zero
        rows += samples.map { sample in
            let time = Float(sample.step - touchdownStep) * Motorcycle.stepSeconds
            let suspension = "\(time),\(sample.travel.x * 1000),\(sample.travel.y * 1000),\(sample.speed.x),\(sample.speed.y),\(sample.load.x),\(sample.load.y),\(sample.bottomOuts.x - initialBottomOuts.x),\(sample.bottomOuts.y - initialBottomOuts.y)"
            let motion = "\(sample.chassisHeight),\(sample.chassisVerticalSpeed),\(sample.pitchRate),\(sample.heading),\(sample.lean),\(sample.yawRate),\(sample.rollRate),\(sample.steering),\(sample.velocityX),\(sample.velocityZ)"
            return "\(suspension),\(motion),\(sample.patchSidewaysSpeed.x),\(sample.patchSidewaysSpeed.y)"
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
