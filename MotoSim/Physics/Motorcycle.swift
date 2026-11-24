import Foundation
import simd

private func roundedTireContact(on track: Track, axle: SIMD3<Float>, spinAxis: SIMD3<Float>,
                                radius: Float, crown: Float)
    -> (offset: SIMD3<Float>, normal: SIMD3<Float>, rollingRadius: Float) {
    var offset = SIMD3<Float>.zero
    var patch = axle
    var normal = track.normal(patch.x, patch.z)
    // Bound the refinement cost on sharp terrain and stop once the patch settles within 1 mm.
    for _ in 0..<4 {
        let radial = normal - spinAxis * simd_dot(normal, spinAxis)
        offset = -(radius - crown) * radial / max(0.001, simd_length(radial)) - crown * normal
        let nextPatch = axle + offset
        let movement = SIMD2(nextPatch.x - patch.x, nextPatch.z - patch.z)
        patch = nextPatch
        let movementSquared = simd_length_squared(movement)
        if movementSquared == 0 { break }
        normal = track.normal(patch.x, patch.z)
        if movementSquared < 0.000001 { break }
    }
    let radialLength = simd_length(normal - spinAxis * simd_dot(normal, spinAxis))
    return (offset, normal, radius - crown * (1 - radialLength))
}

struct BikeConfiguration {
    var mass: Float = 177
    var wheelbase: Float = 1.48
    var frontRadius: Float = 0.345
    var rearRadius: Float = 0.335
    var frontCrownRadius: Float = 0.042
    var rearCrownRadius: Float = 0.059
    var axleDrop: Float = 0.53
    var riderMass: Float = 76
    var neutralCenterOfMass: SIMD3<Float> = [0, -0.30, 0]
    var riderForeAftTravel: Float = 0.53
    var riderRearwardRise: Float = 0.22
    var riderLateralTravel: Float = 0.24

    func riderOffset(weight: Float, lateral: Float) -> SIMD3<Float> {
        // Rider-right is local -X with +Z forward.
        [-lateral * riderLateralTravel, max(0, -weight) * riderRearwardRise, weight * riderForeAftTravel]
    }

    func centerOfMass(weight: Float, lateral: Float) -> SIMD3<Float> {
        neutralCenterOfMass + riderOffset(weight: weight, lateral: lateral) * (riderMass / mass)
    }

    var wheelInertia: Float = 0.76
    var pitchInertia: Float = 55
    var rollInertia: Float = 31
    var yawInertia: Float = 68
    let fork = Suspension(front: true)
    let shock = Suspension(front: false)

    var frontUnsprungMass: Float { fork.unsprungMass }
    var rearUnsprungMass: Float { shock.unsprungMass }
    var sprungMass: Float { mass - frontUnsprungMass - rearUnsprungMass }

    // Distance from the rear axle to a fixed chassis mark directly above it.
    // Compare full extension with the bike supported by both tires, with and without the rider.
    func rearSag(tuning: RideTuning, withRider: Bool) -> Float {
        let ground = HeightField(columns: 2, rows: 2, width: 10, length: 10,
                                 elevationRange: 0, samples: [0, 0, 0, 0])
        let track = Track(name: "Sag measurement", heightField: ground)
        let loaded = restingPose(on: track, at: .zero, heading: 0, tuning: tuning, withRider: withRider)
        let mark = SIMD3<Float>(0, 0.20, -wheelbase / 2)
        let extendedAxle = SIMD3<Float>(0, -axleDrop, -wheelbase / 2)
        let loadedAxle = extendedAxle + [0, loaded.state.compression.y, 0]
        return simd_distance(mark, extendedAxle) - simd_distance(mark, loadedAxle)
    }

    private func restingSuspension(pitch: Float, tuning: RideTuning, withRider: Bool)
        -> (travel: SIMD2<Float>, load: SIMD2<Float>) {
        let weight = (mass - (withRider ? 0 : riderMass)) * 9.81
        let orientation = simd_quatf(angle: pitch, axis: [1, 0, 0])
        let center = orientation.act(neutralCenterOfMass)
        var travel = SIMD2<Float>(0.07, 0.105)
        var frontLoad = weight / 2
        for _ in 0..<5 {
            let front = orientation.act(frontAxleRest + frontCompressionAxis * travel.x)
            let rear = orientation.act([0, -axleDrop + travel.y, -wheelbase / 2])
            frontLoad = weight * (center.z - rear.z) / (front.z - rear.z)
            travel.x = fork.deflection(supporting: (frontLoad - frontUnsprungMass * 9.81)
                                       * orientation.act(frontCompressionAxis).y, tuning: tuning)
            travel.y = shock.deflection(supporting: (weight - frontLoad - rearUnsprungMass * 9.81)
                                        * orientation.act([0, 1, 0]).y, tuning: tuning)
        }
        return (travel, [frontLoad, weight - frontLoad])
    }

    func restingPose(on track: Track, at position: SIMD3<Float>, heading: Float, tuning: RideTuning,
                     withRider: Bool = true) -> (state: BikeState, load: SIMD2<Float>) {
        var state = BikeState(position: position, heading: heading)
        var load = SIMD2<Float>.zero
        // Find the pitch at which both loaded tires can rest on the surface.
        var low: Float = -0.62
        var high: Float = 0.62
        for _ in 0..<18 {
            state.pitch = (low + high) / 2
            let rest = restingSuspension(pitch: state.pitch, tuning: tuning, withRider: withRider)
            func restingHeight(localAxle: SIMD3<Float>, radius: Float, crown: Float, load: Float) -> Float {
                let arm = state.orientation.act(localAxle)
                let axle = state.position + arm
                let spinAxis = state.orientation.act([1, 0, 0])
                let contact = roundedTireContact(on: track, axle: axle, spinAxis: spinAxis,
                                                 radius: radius, crown: crown)
                let patch = axle + contact.offset
                return track.height(patch.x, patch.z) - arm.y - contact.offset.y
                    - load / (Suspension.tireRate * contact.normal.y)
            }
            let front = restingHeight(localAxle: frontAxleRest + frontCompressionAxis * rest.travel.x,
                                      radius: frontRadius, crown: frontCrownRadius, load: rest.load.x)
            let rear = restingHeight(localAxle: [0, -axleDrop + rest.travel.y, -wheelbase / 2],
                                     radius: rearRadius, crown: rearCrownRadius, load: rest.load.y)
            if front > rear { high = state.pitch } else { low = state.pitch }
            state.position.y = max(front, rear)
            state.compression = rest.travel
            load = rest.load
        }
        state.contacts = 2
        return (state, load)
    }

    var forkRake: Float = 0.46
    var frontTrail: Float = 0.105
    var steeringInertia: Float = 0.75
    var frontCompressionAxis: SIMD3<Float> { [0, cos(forkRake), -sin(forkRake)] }
    var frontAxleRest: SIMD3<Float> { [0, -axleDrop, wheelbase / 2] }
    var steeringPivot: SIMD3<Float> { frontAxleRest + [0, 0, frontTrail - frontRadius * tan(forkRake)] }
}

struct BikeState {
    var position: SIMD3<Float> = .zero
    var velocity: SIMD3<Float> = .zero
    var heading: Float = 0
    var pitch: Float = 0
    var lean: Float = 0
    var pitchRate: Float = 0
    var rollRate: Float = 0
    var riderWeight: Float = 0
    var riderLateralWeight: Float = 0
    var yawRate: Float = 0
    var wheelSpeed: SIMD2<Float> = .zero
    var wheelAngle: SIMD2<Float> = .zero
    var compression: SIMD2<Float> = .zero
    var suspensionSpeed: SIMD2<Float> = .zero
    var steering: Float = 0
    var steeringRate: Float = 0
    var contacts = 0
    var rpm: Float = 2200
    var ignitionCut = false
    var gear = 1

    var orientation: simd_quatf {
        simd_quatf(angle: heading, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
            * simd_quatf(angle: lean, axis: [0, 0, 1])
    }
}

struct Motorcycle {
    private struct RecoveryPoint {
        let position: SIMD3<Float>
        let heading: Float
    }

    static let stepSeconds: Float = 1 / 240
    private static let recoveryInterval = 24
    private static let recoveryEdgeClearance: Float = 1.5
    let configuration: BikeConfiguration
    let track: Track
    var tuning: RideTuning
    private(set) var physicsMode: RidePhysicsMode
    var collectsTireTrace = false {
        didSet { if !collectsTireTrace { suspensionTrace = TouchdownTrace() } }
    }
    private(set) var suspensionTrace = TouchdownTrace()
    private(set) var bottomOutCount = SIMD2<Int32>.zero
    private(set) var suspensionLoad = SIMD2<Float>.zero
    private var forkSupport: Float = 0
    private var balanceSupport: Float = 0
    private var airborneTime: Float = 0
    private var bottomed = [false, false]
    private(set) var frontTrace = TireTrace()
    private(set) var rearTrace = TireTrace()
    private(set) var debugTargetLean: Float = 0
    private(set) var state = BikeState()
    private var previous = BikeState()
    private var accumulator: Float = 0
    private var revLimiter = RevLimiter()
    private var recoveryStep = 0
    private var lastRecoveryPoint: RecoveryPoint?
    private let ratios: [Float] = [25, 20, 16, 13, 11]

    init(configuration: BikeConfiguration = BikeConfiguration(), track: Track = Track(),
         tuning: RideTuning = RideTuning(), physicsMode: RidePhysicsMode = .simulation,
         initialState: BikeState? = nil) {
        self.configuration = configuration
        self.track = track
        self.tuning = tuning
        self.physicsMode = physicsMode
        if let initialState {
            state = initialState
            previous = initialState
        } else {
            restart(at: track.startPosition, heading: track.startHeading)
        }
    }

    mutating func setPhysicsMode(_ mode: RidePhysicsMode) {
        guard mode != physicsMode else { return }
        physicsMode = mode
        forkSupport = 0
        balanceSupport = 0
        airborneTime = 0
    }

    mutating func reset() {
        var trace = suspensionTrace
        trace.finishRecording()
        let point = lastRecoveryPoint
        restart(at: point?.position ?? track.startPosition, heading: point?.heading ?? track.startHeading)
        suspensionTrace = trace
    }

    private mutating func restart(at position: SIMD3<Float>, heading: Float) {
        (state, suspensionLoad) = configuration.restingPose(on: track, at: position, heading: heading, tuning: tuning)
        forkSupport = 1
        balanceSupport = 1
        airborneTime = 0
        revLimiter = RevLimiter()
        frontTrace = TireTrace()
        rearTrace = TireTrace()
        debugTargetLean = 0
        suspensionTrace = TouchdownTrace()
        bottomOutCount = .zero
        bottomed = [false, false]
        previous = state
        accumulator = 0
        recoveryStep = 0
        lastRecoveryPoint = nil
        recordRecoveryPoint()
    }

    @discardableResult
    mutating func advance(_ elapsed: Float, input: RideInput) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return false }
        accumulator += min(elapsed, 0.1)
        while accumulator >= Self.stepSeconds {
            previous = state
            step(input, dt: Self.stepSeconds)
            accumulator -= Self.stepSeconds
            recoveryStep += 1
            let tippedOver = abs(state.pitch) > 1.45 || abs(state.lean) > 1.24
            if !track.contains(state.position) || (physicsMode == .simulation && tippedOver) {
                reset()
                return true
            }
            if recoveryStep.isMultiple(of: Self.recoveryInterval) { recordRecoveryPoint() }
        }
        return false
    }

    private mutating func recordRecoveryPoint() {
        let edge = track.halfExtents
        let clearance = Self.recoveryEdgeClearance
        guard state.contacts == 2, abs(state.lean) < 0.35, abs(state.pitch) < 0.55,
              abs(state.rollRate) < 1.5, abs(state.pitchRate) < 1.5,
              abs(state.position.x) + clearance < edge.x,
              abs(state.position.z) + clearance < edge.y else { return }
        lastRecoveryPoint = RecoveryPoint(position: state.position, heading: state.heading)
    }

    var pose: BikeState {
        let t = accumulator / Self.stepSeconds
        var result = state
        result.position = previous.position + (state.position - previous.position) * t
        result.heading = previous.heading + (state.heading - previous.heading) * t
        result.pitch = previous.pitch + (state.pitch - previous.pitch) * t
        result.lean = previous.lean + (state.lean - previous.lean) * t
        result.wheelAngle = previous.wheelAngle + (state.wheelAngle - previous.wheelAngle) * t
        result.riderWeight = previous.riderWeight + (state.riderWeight - previous.riderWeight) * t
        result.riderLateralWeight = previous.riderLateralWeight + (state.riderLateralWeight - previous.riderLateralWeight) * t
        result.steering = previous.steering + (state.steering - previous.steering) * t
        result.compression = previous.compression + (state.compression - previous.compression) * t
        return result
    }

    private mutating func step(_ input: RideInput, dt: Float) {
        let c = configuration
        let heading = simd_quatf(angle: state.heading, axis: [0, 1, 0])
        let speed = simd_length(SIMD2(state.velocity.x, state.velocity.z))
        let steering = LeanSteering(input: input.steer, speed: speed, wheelbase: c.wheelbase,
                                    maximumLean: tuning.maximumLeanRadians)
        let gripScale = tuning.tireGripScale
        let previousRiderCenter = c.centerOfMass(weight: state.riderWeight, lateral: state.riderLateralWeight)
        let previousCenterOfMass = state.orientation.act(previousRiderCenter)
        let weightResponse = min(1, 7 * dt)
        state.riderWeight += (clamp(input.weight, -1, 1) - state.riderWeight) * weightResponse
        state.riderLateralWeight += (clamp(input.lateralWeight, -1, 1) - state.riderLateralWeight) * weightResponse
        let weight = state.riderWeight
        let riderCenter = c.centerOfMass(weight: weight, lateral: state.riderLateralWeight)
        let throttle = clamp(input.throttle, 0, 1)
        let brake = clamp(input.brake, 0, 1)

        let wheelRPM = abs(state.wheelSpeed.y) * 60 / (2 * .pi)
        let shiftRPM = speed * 60 / (c.rearRadius * 2 * .pi) * ratios[state.gear - 1]
        if shiftRPM > 11_750, state.gear < ratios.count { state.gear += 1 }
        if shiftRPM < 6_600, state.gear > 1 { state.gear -= 1 }
        let ratio = ratios[state.gear - 1]
        state.rpm = max(2200, wheelRPM * ratio)
        let torque = max(12, 30 - pow((state.rpm - 9800) / 2300, 2))
        revLimiter.update(rpm: state.rpm, throttle: throttle, dt: dt)
        state.ignitionCut = revLimiter.cutsIgnition
        let clutch = clamp(0.38 + speed * 0.18, 0.38, 1)
        let combustion = state.ignitionCut ? 0 : torque * throttle
        let closedThrottle = state.ignitionCut ? 1 : 1 - throttle
        let pumpingLoss = closedThrottle * min(3.3, wheelRPM * 0.025)
        let drive = (combustion * clutch - pumpingLoss) * ratio * 0.87

        let gravity = SIMD3<Float>(0, -9.81, 0)
        var force = gravity * c.sprungMass - state.velocity * (3 + 0.38 * speed)
        var wheelAccelerations = SIMD2<Float>.zero
        let originalVelocity = state.velocity
        let originalPitchRate = state.pitchRate
        let originalRollRate = state.rollRate
        let originalYawRate = state.yawRate
        var moment = SIMD3<Float>.zero
        var contacts = 0
        var frontSteeringReaction: Float = 0
        let orientation = state.orientation
        let pitchOrientation = simd_quatf(angle: state.pitch, axis: [1, 0, 0])
        let angularVelocity = heading.act([state.pitchRate, state.yawRate, 0]
                                           + pitchOrientation.act([0, 0, state.rollRate]))
        let steeringAxis = orientation.act(c.frontCompressionAxis)
        let steeringPivotArm = orientation.act(c.steeringPivot)
        let steeringRotation = simd_quatf(angle: state.steering, axis: c.frontCompressionAxis)
        let frontAxle = c.steeringPivot + steeringRotation.act(c.frontAxleRest - c.steeringPivot)
        let rearAxle = SIMD3<Float>(0, -c.axleDrop, -c.wheelbase / 2)
        let centerOfMass = orientation.act(riderCenter)
        // Rider movement shifts the chassis around the combined center of mass.
        state.position += previousCenterOfMass - centerOfMass
        for wheel in 0..<2 {
            let front = wheel == 0
            let radius = front ? c.frontRadius : c.rearRadius
            let localAxle = front ? frontAxle : rearAxle
            let suspension = front ? c.fork : c.shock
            let fork = orientation.act(front ? c.frontCompressionAxis : [0, 1, 0])
            let compression = state.compression[wheel]
            let compressionSpeed = state.suspensionSpeed[wheel]
            let arm = orientation.act(localAxle) + fork * compression
            let axle = state.position + arm
            let wheelOrientation = front ? orientation * steeringRotation : orientation
            let spinAxis = wheelOrientation.act([1, 0, 0])
            let crownRadius = front ? c.frontCrownRadius : c.rearCrownRadius
            let contact = roundedTireContact(on: track, axle: axle, spinAxis: spinAxis,
                                             radius: radius, crown: crownRadius)
            let patch = axle + contact.offset
            let normal = contact.normal
            let rollingRadius = contact.rollingRadius
            let penetration = (track.height(patch.x, patch.z) - patch.y) * normal.y
            let steeringVelocity = front ? steeringAxis * state.steeringRate : .zero
            let patchArm = arm + contact.offset
            let contactArm = patchArm - centerOfMass
            let steeringLever = patchArm - steeringPivotArm
            let patchVelocity = state.velocity + simd_cross(angularVelocity, contactArm)
                + simd_cross(steeringVelocity, steeringLever) + fork * compressionSpeed
            let load = penetration > 0
                ? max(0, Suspension.tireRate * penetration
                      - Suspension.tireDamping * simd_dot(patchVelocity, normal)) : 0
            suspensionLoad[wheel] = load
            let contactFrame = TireContactFrame(wheel: wheelOrientation, normal: normal)
            let tangent = contactFrame.forward
            let lateral = contactFrame.lateral
            var wheelTorque = front ? 0 : drive
            var brakeTorque = brake * (front ? 315 : 230)
            var longitudinalForce: Float = 0
            var trace = TireTrace()

            var reaction = normal * load
            if load > 0 {
                contacts += 1
                // Implicitly account for the wheel slowing under tire force over this step.
                var surface = track.tireSurface(patch.x, patch.z)
                surface.peakGrip *= gripScale
                let tractionLimit = DirtTire.tractionLimit(load: load, grip: surface.peakGrip)
                let wheelResponse = DirtTire.longitudinalSlope * tractionLimit
                    * rollingRadius * rollingRadius / c.wheelInertia * dt
                let longitudinalSpeed = simd_dot(patchVelocity, tangent)
                let slipSpeed = state.wheelSpeed[wheel] * rollingRadius - longitudinalSpeed
                let slip = slipSpeed / (max(1.5, abs(longitudinalSpeed)) + wheelResponse)
                let sideLever = heading.inverse.act(simd_cross(contactArm, lateral))
                let sideInverseMass = 1 / c.sprungMass + sideLever.x * sideLever.x / c.pitchInertia
                    + sideLever.y * sideLever.y / c.yawInertia + sideLever.z * sideLever.z / c.rollInertia
                // Account for the patch slowing sideways under this step's own tire force.
                let sideResponse = DirtTire.lateralSlope(on: surface) * tractionLimit * sideInverseMass * dt
                let slipAngle = atan2(simd_dot(patchVelocity, lateral), max(0.6, abs(longitudinalSpeed)) + sideResponse)
                let rollingBlend = min(1, abs(longitudinalSpeed) / 2)
                let camber = contactFrame.camber * rollingBlend
                if wheelTorque > 0 || brakeTorque > 0 {
                    let limit = DirtTire.assistedTorqueLimit(radius: rollingRadius, gripLimit: tractionLimit,
                                                             slipAngle: slipAngle, camber: camber, surface: surface)
                    // Torque is limited immediately by grip and released further
                    // if the tire crosses its slip target after a load change.
                    if wheelTorque > 0 {
                        let spin = clamp((slip - limit.slip) / 0.08, 0, 1)
                        wheelTorque = min(wheelTorque, limit.torque * (1 - spin))
                    }
                    if brakeTorque > 0 {
                        let direction: Float = longitudinalSpeed >= 0 ? 1 : -1
                        let skid = clamp((-direction * slip - limit.slip) / 0.08, 0, 1)
                        let available = limit.torque * (1 - skid)
                        // Fade ABS out at walking speed so the brakes can hold a stop.
                        let absAuthority = clamp((abs(longitudinalSpeed) - 1) / 2, 0, 1)
                        let engineBraking = max(0, -direction * wheelTorque)
                        wheelTorque += direction * max(0, engineBraking - available) * absAuthority
                        let assistedBrake = min(brakeTorque, max(0, available - engineBraking))
                        brakeTorque += (assistedBrake - brakeTorque) * absAuthority
                    }
                }
                let traction = DirtTire.force(slip: slip, slipAngle: slipAngle, camber: camber,
                                              load: load, surface: surface)
                longitudinalForce = traction.x
                if collectsTireTrace {
                    trace.contact = patch
                    trace.forward = tangent
                    trace.forwardSpeed = simd_dot(patchVelocity, tangent)
                    trace.sidewaysSpeed = simd_dot(patchVelocity, lateral)
                    trace.patchTravel = tangent * trace.forwardSpeed + lateral * trace.sidewaysSpeed
                    trace.traction = tangent * traction.x + lateral * traction.y
                    trace.load = load
                    trace.gripLimit = tractionLimit
                }
                let rollingDrag = surface.rollingResistance * load * clamp(longitudinalSpeed / 0.6, -1, 1)
                reaction += tangent * (traction.x - rollingDrag) + lateral * traction.y
                if front {
                    frontSteeringReaction = simd_dot(simd_cross(steeringLever, reaction), steeringAxis)
                }
            }

            let wheelGravity = gravity * suspension.unsprungMass
            let axialExternal = simd_dot(reaction + wheelGravity, fork)
            let spring = suspension.springForce(at: compression, tuning: tuning)
                + suspension.bumpForce(at: compression)
            let response = dt / suspension.unsprungMass
            let freeSpeed = compressionSpeed + (axialExternal - spring) * response
            let damper = suspension.implicitDamperForce(at: compression, freeSpeed: freeSpeed,
                                                       response: response, tuning: tuning)
            let axialWheelForce = axialExternal - spring - damper
            wheelAccelerations[wheel] = axialWheelForce / suspension.unsprungMass
            force += reaction + wheelGravity - fork * axialWheelForce
            moment += simd_cross(contactArm, reaction)
                + simd_cross(arm - centerOfMass, wheelGravity - fork * axialWheelForce)

            let omega = state.wheelSpeed[wheel]
            let unbraked = omega + (wheelTorque - longitudinalForce * rollingRadius - 0.12 * omega) / c.wheelInertia * dt
            let braking = brakeTorque / c.wheelInertia * dt
            let nextOmega = unbraked >= 0 ? max(0, unbraked - braking) : min(0, unbraked + braking)
            state.wheelSpeed[wheel] = nextOmega
            if collectsTireTrace {
                trace.treadSpeed = nextOmega * rollingRadius
                if front { frontTrace = trace } else { rearTrace = trace }
            }
            state.wheelAngle[wheel] += nextOmega * dt
            // Remove the wheel's change in angular momentum from the chassis moment.
            let spinMomentum = spinAxis * (omega * c.wheelInertia)
            moment -= spinAxis * ((nextOmega - omega) * c.wheelInertia / dt)
                + simd_cross(angularVelocity + steeringVelocity, spinMomentum)
        }

        if physicsMode == .simulation {
            updateSimulationSteering(steering, input: input.steer, speed: speed, heading: heading,
                                     reaction: frontSteeringReaction, dt: dt)
        }

        state.contacts = contacts
        // Transverse inertia follows the chassis. In local coordinates both
        // suspension axes lie in the YZ plane, so only those two axes are coupled.
        let frontAxis = orientation.act(c.frontCompressionAxis)
        let rearAxis = orientation.act([0, 1, 0])
        let localForce = orientation.inverse.act(force)
        let forkAxis = c.frontCompressionAxis
        let yy = c.mass - c.frontUnsprungMass * forkAxis.y * forkAxis.y - c.rearUnsprungMass
        let yz = -c.frontUnsprungMass * forkAxis.y * forkAxis.z
        let zz = c.mass - c.frontUnsprungMass * forkAxis.z * forkAxis.z
        let determinant = yy * zz - yz * yz
        let acceleration = SIMD3<Float>(localForce.x / c.mass,
            (zz * localForce.y - yz * localForce.z) / determinant,
            (yy * localForce.z - yz * localForce.y) / determinant)
        state.velocity += orientation.act(acceleration) * dt
        let localMoment = heading.inverse.act(moment)
        if physicsMode == .arcade {
            let normal = track.normal(state.position.x, state.position.z)
            let load = (suspensionLoad.x + suspensionLoad.y) / (configuration.mass * 9.81)
            let targetLean = ArcadeHandling.advance(&state, input: input, normal: normal,
                                                    loadInBikeWeights: load, maximumLean: tuning.maximumLeanRadians, dt: dt)
            if collectsTireTrace { debugTargetLean = targetLean }
        } else {
            updateSimulationAttitude(input, weight: weight, speed: speed, steering: steering,
                                     heading: heading, pitch: pitchOrientation, moment: localMoment, dt: dt)
        }
        let nextCenterOfMassPosition = state.position + centerOfMass + state.velocity * dt
        let linearAcceleration = (state.velocity - originalVelocity) / dt
        let angularAcceleration = heading.act([state.pitchRate - originalPitchRate, state.yawRate - originalYawRate, 0]
            + pitchOrientation.act([0, 0, state.rollRate - originalRollRate])) / dt
        for wheel in 0..<2 {
            let front = wheel == 0
            let suspension = front ? c.fork : c.shock
            let axis = front ? frontAxis : rearAxis
            let axle = front ? frontAxle : rearAxle
            let arm = orientation.act(axle) + axis * state.compression[wheel] - centerOfMass
            let baseAcceleration = linearAcceleration + simd_cross(angularAcceleration, arm)
                + simd_cross(angularVelocity, simd_cross(angularVelocity, arm))
            let nextSpeed = state.suspensionSpeed[wheel]
                + (wheelAccelerations[wheel] - simd_dot(baseAcceleration, axis)) * dt
            let nextTravel = state.compression[wheel] + nextSpeed * dt
            let atBottom = nextTravel >= suspension.travel
            if atBottom && !bottomed[wheel] { bottomOutCount[wheel] += 1 }
            bottomed[wheel] = atBottom
            state.compression[wheel] = clamp(nextTravel, 0, suspension.travel)
            state.suspensionSpeed[wheel] = (nextTravel < 0 || atBottom) ? 0 : nextSpeed
        }
        state.position = nextCenterOfMassPosition - state.orientation.act(riderCenter)
        if collectsTireTrace {
            suspensionTrace.record(step: recoveryStep + 1, state: state,
                                   load: suspensionLoad, bottomOuts: bottomOutCount,
                                   patchSidewaysSpeed: [frontTrace.sidewaysSpeed, rearTrace.sidewaysSpeed])
        }
    }

    private mutating func updateSimulationSteering(_ steering: LeanSteering, input: Float, speed: Float,
                                                   heading: simd_quatf, reaction: Float, dt: Float) {
        // Blend the rider controller as the tires take weight. Drop support
        // immediately on lift-off and rebuild it over several steps on landing.
        let weightForce = configuration.mass * 9.81
        let frontSupport = clamp(suspensionLoad.x / (0.35 * weightForce), 0, 1)
        let totalSupport = clamp((suspensionLoad.x + suspensionLoad.y) / (0.75 * weightForce), 0, 1)
        let supportResponse = 1 - exp(-dt / 0.09)
        forkSupport = min(frontSupport, forkSupport + (frontSupport - forkSupport) * supportResponse)
        balanceSupport = min(totalSupport, balanceSupport + (totalSupport - balanceSupport) * supportResponse)

        let groundBarTarget = steering.barTarget(actualLean: state.lean, rollRate: state.rollRate)
        let barTarget = steering.baseSteering + (groundBarTarget - steering.baseSteering) * forkSupport
        let stick = clamp(abs(input), 0, 1)
        let steeringStrength = 155 + 45 * stick * forkSupport
        let touchdownDamping = 16 * (frontSupport - forkSupport)
        let corneringTorque = (barTarget - state.steering) * steeringStrength - state.steeringRate * 20
        let straightAuthority = StraightLineSteering.authority(speed: speed, stick: stick) * forkSupport
        var commandTorque = corneringTorque
        if straightAuthority > 0 {
            let lateralSpeed = heading.inverse.act(state.velocity).x
            let straightTorque = StraightLineSteering.torque(state: state, speed: speed, lateralSpeed: lateralSpeed)
            commandTorque += (straightTorque - corneringTorque) * straightAuthority
        }
        let riderSteeringTorque = clamp(commandTorque - state.steeringRate * touchdownDamping, -100, 100)
        let steeringTorque = riderSteeringTorque + clamp(reaction, -95, 95)
        state.steeringRate = clamp(state.steeringRate + steeringTorque / configuration.steeringInertia * dt, -6, 6)
        let nextSteering = state.steering + state.steeringRate * dt
        state.steering = clamp(nextSteering, -LeanSteering.barLock, LeanSteering.barLock)
        if nextSteering != state.steering { state.steeringRate = 0 }
    }

    private mutating func updateSimulationAttitude(_ input: RideInput, weight: Float, speed: Float,
                                                   steering: LeanSteering, heading: simd_quatf, pitch: simd_quatf,
                                                   moment: SIMD3<Float>, dt: Float) {
        let contacts = state.contacts
        let stick = clamp(abs(input.steer), 0, 1)
        let pitchAssist = contacts > 0 ? -state.pitchRate * 28 : weight * 90 - state.pitchRate * 12
        state.pitchRate += (moment.x + pitchAssist) / configuration.pitchInertia * dt
        state.pitch += state.pitchRate * dt

        let yawDamping: Float = contacts > 0 ? 19 : 4
        airborneTime = contacts == 0 ? airborneTime + dt : 0
        let airAlignment = clamp((airborneTime - 0.25) / 0.15, 0, 1)
            * clamp((speed - 2) / 4, 0, 1) * clamp(1 - stick / 0.20, 0, 1)
        var airYawTorque: Float = 0
        if airAlignment > 0 {
            // Align the chassis with its existing flight path by applying yaw
            // torque. The assist does not steer the center of mass in the air.
            let localVelocity = heading.inverse.act(state.velocity)
            let headingError = atan2(localVelocity.x, localVelocity.z)
            airYawTorque = clamp(headingError * 260 - state.yawRate * 200, -85, 85) * airAlignment
        }
        state.yawRate += (moment.y + airYawTorque - state.yawRate * yawDamping) / configuration.yawInertia * dt
        state.heading += state.yawRate * dt

        // The rider balance assist acts through roll torque. Tire forces still determine the turn.
        let airLean = clamp(input.steer, -1, 1) * 0.32
        let targetLean = airLean + (steering.targetLean - airLean) * balanceSupport
        if collectsTireTrace { debugTargetLean = targetLean }
        let balanceStiffness = 145 + (1405 - steering.countersteerBlend * 850) * balanceSupport
        let balanceDamping = 115 + (245 - steering.countersteerBlend * 150) * balanceSupport
        let balanceTorque = (targetLean - state.lean) * balanceStiffness - state.rollRate * balanceDamping
        let rollMoment = pitch.inverse.act(moment).z
        state.rollRate += (rollMoment + balanceTorque) / configuration.rollInertia * dt
        state.lean += state.rollRate * dt
    }

    private func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(high, max(low, value))
    }
}
