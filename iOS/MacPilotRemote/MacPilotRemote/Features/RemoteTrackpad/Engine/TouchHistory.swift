import CoreGraphics
import Foundation

/// The complete history of one touch, reduced to the features the press
/// recognizer scores. Every field the acceptance spec names lives here:
/// baseline (adaptive — each touch is its own reference, never a fixed
/// radius), current and maximum contact, cumulative growth, growth speed,
/// duration, travel and finger speed.
struct TouchHistory {
    let startTimestamp: TimeInterval
    let startRadius: CGFloat
    let startLocation: CGPoint

    private(set) var currentRadius: CGFloat
    private(set) var maxRadius: CGFloat
    /// Σ|Δradius| across the touch: small repeated increases accumulate, so
    /// a slowly firming light press still reaches the bar.
    private(set) var accumulatedGrowth: CGFloat = 0
    /// Cumulative growth divided by elapsed time, in baseline-relative
    /// units per second.
    private(set) var growthVelocity: CGFloat = 0
    private(set) var duration: TimeInterval = 0
    private(set) var movementDistance: CGFloat = 0
    /// Smoothed finger speed in points per second.
    private(set) var velocity: CGFloat = 0

    private var lastRadius: CGFloat
    private var lastTimestamp: TimeInterval
    private var lastLocation: CGPoint

    /// Travel beyond this distance cancels the press outright: a moving
    /// finger is a cursor, never a press.
    static let movementCancel: CGFloat = 12

    private(set) var sampleCount = 0

    var isEmpty: Bool { sampleCount == 0 }

    /// A placeholder for recognizers between touches; overwritten on begin.
    static func empty() -> TouchHistory {
        TouchHistory(sample: PressureSample(timestamp: 0, location: .zero, majorRadius: 0, velocity: .zero, isMoving: false))
    }

    init(sample: PressureSample) {
        startTimestamp = sample.timestamp
        startRadius = sample.majorRadius
        startLocation = sample.location
        currentRadius = sample.majorRadius
        maxRadius = sample.majorRadius
        lastRadius = sample.majorRadius
        lastTimestamp = sample.timestamp
        lastLocation = sample.location
    }

    mutating func append(_ sample: PressureSample) {
        sampleCount += 1
        currentRadius = sample.majorRadius
        maxRadius = max(maxRadius, sample.majorRadius)
        accumulatedGrowth += abs(sample.majorRadius - lastRadius)

        let elapsed = max(sample.timestamp - lastTimestamp, 0.001)
        duration = sample.timestamp - startTimestamp
        growthVelocity = duration > 0.05 ? accumulatedGrowth / CGFloat(duration) : growthVelocity

        let dx = sample.location.x - lastLocation.x
        let dy = sample.location.y - lastLocation.y
        let step = hypot(dx, dy) / elapsed
        // Exponential smoothing so one jittery frame cannot spike the speed.
        velocity += (CGFloat(step) - velocity) * 0.4
        let fromStart = hypot(sample.location.x - startLocation.x, sample.location.y - startLocation.y)
        movementDistance = max(movementDistance, fromStart)

        lastRadius = sample.majorRadius
        lastTimestamp = sample.timestamp
        lastLocation = sample.location
    }

    /// Contact growth relative to the touch's own baseline, floored so tiny
    /// contacts cannot score huge ratios off radius noise alone.
    var relativeGrowth: CGFloat {
        max(currentRadius - startRadius, 0) / max(startRadius, 6)
    }
}
