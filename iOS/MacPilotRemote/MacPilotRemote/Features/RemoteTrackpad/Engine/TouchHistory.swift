import CoreGraphics
import Foundation

/// The sample history of one touch, reduced to the features the press
/// recognizer scores: how long the finger has been down, how much the
/// contact patch grew, how fast it grew, how far the finger travelled and
/// how still it kept.
///
/// Deliberately small: a touch lives for a second at most and the ring only
/// needs the first sample (the baseline) and the recent ones.
struct TouchHistory {
    struct Entry {
        var time: TimeInterval
        var radius: CGFloat
        var position: CGPoint
    }

    private(set) var entries: [Entry] = []

    /// Samples jittering less than this around the start count as still.
    static let stabilityJitter: CGFloat = 4
    /// Travel beyond this distance cancels the press outright.
    static let movementCancel: CGFloat = 12

    var isEmpty: Bool { entries.isEmpty }

    var startTime: TimeInterval? {
        entries.first?.time
    }

    var startRadius: CGFloat {
        entries.first?.radius ?? 0
    }

    var currentRadius: CGFloat {
        entries.last?.radius ?? 0
    }

    var startPosition: CGPoint {
        entries.first?.position ?? .zero
    }

    mutating func append(_ sample: TouchSample) {
        entries.append(Entry(time: sample.time, radius: sample.majorRadius, position: sample.position))
    }

    func heldDuration(now: TimeInterval) -> TimeInterval {
        guard let start = entries.first?.time else { return 0 }
        return max(0, now - start)
    }

    /// Contact growth relative to the touch's own baseline, floored so tiny
    /// contacts cannot score huge ratios off radius noise alone.
    func growthRatio(baseline: CGFloat) -> CGFloat {
        max(currentRadius - startRadius, 0) / max(startRadius, baseline)
    }

    /// Contact growth speed in baseline-relative units per second.
    func radiusVelocity(now: TimeInterval, baseline: CGFloat) -> Double {
        let held = heldDuration(now: now)
        guard held > 0.05 else { return 0 }
        return Double(growthRatio(baseline: baseline)) / held
    }

    func movementDistance() -> CGFloat {
        guard let first = entries.first else { return 0 }
        var furthest: CGFloat = 0
        for entry in entries where entry.position != first.position {
            let dx = entry.position.x - first.position.x
            let dy = entry.position.y - first.position.y
            furthest = max(furthest, hypot(dx, dy))
        }
        return furthest
    }

    /// Fraction of samples that stayed within the jitter radius of the
    /// touchdown point: 1 for a perfectly still press, dropping as the
    /// finger wanders.
    func stability() -> Double {
        guard let first = entries.first, entries.count > 1 else { return 1 }
        var still = 0
        for entry in entries {
            let dx = entry.position.x - first.position.x
            let dy = entry.position.y - first.position.y
            if hypot(dx, dy) <= Self.stabilityJitter { still += 1 }
        }
        return Double(still) / Double(entries.count)
    }
}
