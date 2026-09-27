import CoreGraphics
import Foundation

/// How hard the simulated press grades: `off` keeps the plain click pipeline,
/// the other modes trade mis-tap safety for reachability of the deep press.
enum PressureMode: String, CaseIterable, Equatable {
    case off
    case light
    case standard
    case strong
}

/// Per-mode tuning for the press recognizer.
///
/// `growthReference` normalizes contact growth into 0…1 before scoring, and
/// `actuationScore` is the score at which the button goes down while the
/// finger is still on the glass — the lower it is, the easier a press trips.
struct PressureConfig {
    /// Contact growth needed for a full area-growth score.
    var growthReference: CGFloat
    /// Score the recognizer must reach to actuate a press.
    var actuationScore: Double
    /// The pressure a lazy, growth-free tap still carries.
    var pressureFloor: Double
    /// A touch younger than this is always a candidate click, never a press —
    /// the optimistic click's half of the latency contract.
    var minimumPressDuration: TimeInterval

    static func config(for mode: PressureMode) -> PressureConfig {
        switch mode {
        case .off:
            return PressureConfig(growthReference: .infinity, actuationScore: .infinity, pressureFloor: 1, minimumPressDuration: .infinity)
        case .light:
            // Easy to trip: small growth, low score bar, soft floor.
            return PressureConfig(growthReference: 0.22, actuationScore: 0.48, pressureFloor: 0.30, minimumPressDuration: 0.16)
        case .standard:
            return PressureConfig(growthReference: 0.38, actuationScore: 0.60, pressureFloor: 0.45, minimumPressDuration: 0.20)
        case .strong:
            // Deliberate presses only: big growth, high bar, firm floor.
            return PressureConfig(growthReference: 0.60, actuationScore: 0.74, pressureFloor: 0.70, minimumPressDuration: 0.24)
        }
    }
}

/// Maps a recognizer score onto the pressure value the Mac injects: the
/// deeper the recognized press, the closer to full pressure, never below the
/// mode's floor (a lazy tap still reads as a real, if light, click).
enum PressureCurve {
    static func pressure(score: Double, config: PressureConfig) -> Double {
        let shaped = pow(min(max(score, 0), 1), 1.15)
        return min(config.pressureFloor + (1 - config.pressureFloor) * shaped, 1)
    }
}

/// Scores how much a touch reads as a deliberate Mac trackpad press.
///
/// The plan's weighting, over features `TouchHistory` reduces from the raw
/// samples: contact growth dominates, duration matters, stillness helps,
/// travel subtracts. Travel beyond `TouchHistory.movementCancel` cancels the
/// press outright — a moving finger is a cursor, never a press.
enum PressureIntentEngine {
    static let weights = (areaGrowth: 0.45, duration: 0.25, stability: 0.2, movement: 0.1)

    /// Radius readings sit on a baseline that varies by finger; growth is
    /// measured against this floor so tiny contacts cannot score huge
    /// ratios off noise alone.
    static let radiusBaseline: CGFloat = 6

    static func score(history: TouchHistory, config: PressureConfig, now: TimeInterval) -> Double {
        guard history.heldDuration(now: now) >= config.minimumPressDuration else { return 0 }
        // Hard cancel: once the finger travels this far it is a cursor move,
        // full stop.
        guard history.movementDistance() < TouchHistory.movementCancel else { return 0 }
        let areaGrowth = min(history.growthRatio(baseline: Self.radiusBaseline) / config.growthReference, 1)
        let duration = min(history.heldDuration(now: now) / 0.30, 1)
        let stability = history.stability()
        let movement = min(history.movementDistance() / TouchHistory.movementCancel, 1)
        let raw = areaGrowth * weights.areaGrowth
            + duration * weights.duration
            + stability * weights.stability
            - movement * weights.movement
        return min(max(raw, 0), 1)
    }
}
