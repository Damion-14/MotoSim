import Foundation

struct RideTuning: Equatable {
    static let leanRange = 20.0...60.0
    static let gripRange = 0.60...1.40
    static let reboundRange = 0.50...2.00

    static let compressionRange = 0.50...2.00
    static let forkSpringRates = [8.0, 10.0, 12.0, 14.0, 16.0]
    static let defaultForkSpringRate = 12.0
    static let preloadRange = 2.0...16.0

    var maximumLeanDegrees = 48.0
    var tireGrip = 1.0
    var forkRebound = 1.0
    var shockRebound = 1.0
    var forkCompression = 1.0
    var shockLowSpeedCompression = 1.0
    var shockHighSpeedCompression = 1.0
    var forkSpringRate = Self.defaultForkSpringRate
    var shockPreload = 8.0

    var selectedForkSpringRate: Double {
        Self.forkSpringRates.contains(forkSpringRate) ? forkSpringRate : Self.defaultForkSpringRate
    }

    var preloadMeters: Float {
        Float(Self.limit(shockPreload, to: Self.preloadRange, fallback: 8)) / 1000
    }

    func compressionScale(_ setting: Double) -> Float {
        Float(Self.limit(setting, to: Self.compressionRange, fallback: 1))
    }

    var maximumLeanRadians: Float {
        Float(Self.limit(maximumLeanDegrees, to: Self.leanRange, fallback: 48)) * .pi / 180
    }

    var tireGripScale: Float {
        Float(Self.limit(tireGrip, to: Self.gripRange, fallback: 1))
    }

    func reboundScale(front: Bool) -> Float {
        Float(Self.limit(front ? forkRebound : shockRebound, to: Self.reboundRange, fallback: 1))
    }

    private static func limit(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
