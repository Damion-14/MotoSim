struct TireSurface {
    var peakGrip: Float
    var lateralStiffness: Float
    var lockedGripFraction: Float
    var lateralGripFraction: Float
    var rollingResistance: Float

    static let trackDirt = TireSurface(peakGrip: 1.08, lateralStiffness: 6.4,
                                       lockedGripFraction: 0.74, lateralGripFraction: 0.88,
                                       rollingResistance: 0)

    // Short, dry grass over firm ground. These are tuning values for this circuit.
    static let dryGrass = TireSurface(peakGrip: 0.87, lateralStiffness: 8.4,
                                      lockedGripFraction: 0.62, lateralGripFraction: 0.91,
                                      rollingResistance: 0.035)

    static func infieldTransition(grass: Float) -> TireSurface {
        let dirt = trackDirt
        let turf = dryGrass
        return TireSurface(
            peakGrip: dirt.peakGrip + (turf.peakGrip - dirt.peakGrip) * grass,
            lateralStiffness: dirt.lateralStiffness + (turf.lateralStiffness - dirt.lateralStiffness) * grass,
            lockedGripFraction: dirt.lockedGripFraction + (turf.lockedGripFraction - dirt.lockedGripFraction) * grass,
            lateralGripFraction: dirt.lateralGripFraction + (turf.lateralGripFraction - dirt.lateralGripFraction) * grass,
            rollingResistance: turf.rollingResistance * grass
        )
    }
}
