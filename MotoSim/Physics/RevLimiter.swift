struct RevLimiter {
    private(set) var cutsIgnition = false
    private var remainingCut: Float = 0

    mutating func update(rpm: Float, throttle: Float, dt: Float) {
        if cutsIgnition {
            remainingCut = max(0, remainingCut - dt)
            if remainingCut == 0 && (rpm <= 13_100 || throttle < 0.04) {
                cutsIgnition = false
            }
        } else if rpm >= 13_500 && throttle >= 0.04 {
            cutsIgnition = true
            remainingCut = 0.030
        }
    }
}
