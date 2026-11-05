import Testing
@testable import LaunchNew

struct PinchTests {
    @Test func spreadIsMeanDistanceFromCentre() {
        let square: [(Float, Float)] = [(0, 0), (0.2, 0), (0, 0.2), (0.2, 0.2)]
        #expect(abs(TrackpadPinch.spread(square) - 0.1414) < 0.001)
        let closer = square.map { ($0.0 * 0.5, $0.1 * 0.5) }
        #expect(TrackpadPinch.spread(closer) < TrackpadPinch.spread(square) * TrackpadPinch.inThreshold)
    }
}
