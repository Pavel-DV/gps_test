import Foundation

@main
struct RoutePlaybackTimingTests {
    static func main() throws {
        for distance in [0.01, 5.0, 10, 25, 1_000, 10_000] {
            for speed in [1.0, 5, 50, 200] {
                guard let timing = try RoutePlaybackTiming.segment(distanceMeters: distance, speedKilometersPerHour: speed,
                                                                   remainingSamples: RoutePlaybackTiming.maximumSamples - 1) else {
                    fatalError("A nonzero segment must have playback timing")
                }
                let expectedDuration = distance / (speed / 3.6)
                expect(abs(Double(timing.stepCount) * timing.stepDelay - expectedDuration) < 0.000001,
                       "Travel time must match distance / selected speed")
                expect(timing.stepCount > 0 && timing.stepDelay > 0 && timing.stepDelay <= RoutePlaybackTiming.tickInterval,
                       "Coordinate updates must be positive and at most one tick apart")
            }
        }
        let duplicate = try RoutePlaybackTiming.segment(distanceMeters: 0, speedKilometersPerHour: 50, remainingSamples: 0)
        expect(duplicate?.stepCount == nil, "Duplicate coordinates must not consume the sample budget")
        for invalid in [Double.nan, Double.infinity, -1] {
            do {
                _ = try RoutePlaybackTiming.segment(distanceMeters: invalid, speedKilometersPerHour: 50, remainingSamples: 10)
                fatalError("Invalid route distances must fail")
            } catch let error as RoutePlaybackTiming.PreparationError {
                expect(error == .invalidDistance, "Report an invalid route distance")
            }
        }
        for distance in [Double.greatestFiniteMagnitude, 1_000_000] {
            do {
                _ = try RoutePlaybackTiming.segment(distanceMeters: distance, speedKilometersPerHour: 1, remainingSamples: 100)
                fatalError("Reject oversized routes before allocating samples or converting an overflowing step count")
            } catch let error as RoutePlaybackTiming.PreparationError {
                expect(error == .tooManySamples, "Oversized routes need an actionable preparation error")
            }
        }
        expect(RoutePlaybackTiming.validSpeed(.nan) == 50 && RoutePlaybackTiming.validSpeed(0) == 50,
               "Invalid stored preferences must use the default speed")
        expect(RoutePlaybackTiming.validSpeed(0.5) == 1 && RoutePlaybackTiming.validSpeed(250) == 200,
               "Clamp preferences to the slider range")
        let fifty = try RoutePlaybackTiming.segment(distanceMeters: 1_000, speedKilometersPerHour: 50, remainingSamples: 1_000)!
        let hundred = try RoutePlaybackTiming.segment(distanceMeters: 1_000, speedKilometersPerHour: 100, remainingSamples: 1_000)!
        expect(abs(Double(fifty.stepCount) * fifty.stepDelay - 2 * Double(hundred.stepCount) * hundred.stepDelay) < 0.000001,
               "Doubling the selected speed must halve simulation duration")
        print("Route playback timing checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
