import CoreGraphics
import Foundation

/// How hard the simulated press grades: `off` keeps the plain click pipeline
/// and never starts a recognizer; the other modes trade mis-tap safety for
/// reachability of the deep press.
enum PressureMode: String, CaseIterable, Equatable {
    case off
    case light
    case standard
    case strong
}

/// Per-mode recognizer tuning.
///
/// `actuationScore` is the spec's threshold — the weighted score a touch must
/// reach (while still, inside the decision window rules) before the button
/// goes down. `expectedGrowth` and `accumulatedReference` normalize the two
/// growth features into 0…1; the lighter the mode, the smaller the growth
/// they demand.
struct PressureConfig {
    var expectedGrowth: CGFloat
    var accumulatedReference: CGFloat
    var actuationScore: Double

    static func config(for mode: PressureMode) -> PressureConfig {
        switch mode {
        case .off:
            return PressureConfig(expectedGrowth: .infinity, accumulatedReference: .infinity, actuationScore: .infinity)
        case .light:
            // 轻手：门槛 0.35，微小累积增长即可触发。
            return PressureConfig(expectedGrowth: 0.16, accumulatedReference: 1.6, actuationScore: 0.35)
        case .standard:
            // 默认：门槛 0.5。
            return PressureConfig(expectedGrowth: 0.25, accumulatedReference: 2.4, actuationScore: 0.50)
        case .strong:
            // 类 Force Click：门槛 0.7，需要明显按压。
            return PressureConfig(expectedGrowth: 0.40, accumulatedReference: 3.6, actuationScore: 0.70)
        }
    }
}

/// Scores how much a touch reads as a deliberate Mac trackpad press.
///
/// Nothing here looks at an absolute radius — every touch is its own
/// adaptive baseline, so an index finger, a thumb and a pinky all score the
/// same way. The features come from `TouchHistory`, the weights are the
/// spec's, and the result feeds `PressureCurve`.
enum PressureIntentEngine {
    static let weights = (growth: 0.35, accumulated: 0.25, duration: 0.20, movement: 0.20)

    /// A touch younger than this never presses: the optimistic click owns it.
    static let decisionWindow: TimeInterval = 0.15

    /// Speed beyond this (points/second) saturates the movement penalty.
    static let velocitySaturation: CGFloat = 150

    static func score(history: TouchHistory, config: PressureConfig) -> PressureScore {
        // Relative change only — never "radius > N".
        let growth = min(max(history.relativeGrowth / config.expectedGrowth, 0), 1)
        let accumulated = min(max(history.accumulatedGrowth / config.accumulatedReference, 0), 1)
        // <100 ms = 0; 100–300 ms linear; >300 ms = 1.
        let seconds = history.duration
        let duration = min(max((seconds - 0.1) / 0.2, 0), 1)
        // Long still holds are *not* presses by themselves: hard-cancel once
        // the finger has travelled beyond the press distance.
        let movementPenalty = history.movementDistance >= TouchHistory.movementCancel
            ? 1
            : min(history.velocity / velocitySaturation, 1)

        let raw = growth * weights.growth
            + accumulated * weights.accumulated
            + duration * weights.duration
            - movementPenalty * weights.movement
        return PressureScore(
            growth: growth,
            accumulated: accumulated,
            duration: duration,
            movementPenalty: movementPenalty,
            value: min(max(raw, 0), 1)
        )
    }
}
