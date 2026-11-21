import Foundation

enum RoutePlaybackTiming {
    static let defaultSpeedKilometersPerHour = 50.0
    static let tickInterval: TimeInterval = 0.5
    static let maximumSamples = 250_000

    struct Segment {
        let stepCount: Int
        let stepDelay: TimeInterval
    }

    enum PreparationError: LocalizedError, Equatable {
        case invalidDistance
        case tooManySamples

        var errorDescription: String? {
            switch self {
            case .invalidDistance: return "The route contains an invalid distance."
            case .tooManySamples: return "This route is too long at the selected speed. Increase the speed or choose a shorter route."
            }
        }
    }

    static func validSpeed(_ kilometersPerHour: Double) -> Double {
        guard kilometersPerHour.isFinite, kilometersPerHour > 0 else { return defaultSpeedKilometersPerHour }
        return min(200, max(1, kilometersPerHour))
    }

    static func segment(distanceMeters: Double, speedKilometersPerHour: Double, remainingSamples: Int) throws -> Segment? {
        guard distanceMeters.isFinite, distanceMeters >= 0 else { throw PreparationError.invalidDistance }
        guard distanceMeters > 0 else { return nil }
        let seconds = distanceMeters / (validSpeed(speedKilometersPerHour) / 3.6)
        let steps = max(1, ceil(seconds / tickInterval))
        guard steps.isFinite, steps <= Double(min(maximumSamples, remainingSamples)) else {
            throw PreparationError.tooManySamples
        }
        let count = Int(steps)
        return Segment(stepCount: count, stepDelay: seconds / Double(count))
    }
}
