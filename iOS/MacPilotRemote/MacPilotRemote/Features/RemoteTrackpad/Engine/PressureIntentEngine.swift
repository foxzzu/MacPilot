import CoreGraphics
import Foundation

/// How hard the simulated press grades: `off` keeps the plain click pipeline,
/// the other modes trade mis-tap safety for reachability of the deep press.
enum PressureMode: String, CaseIterable, Equatable {
    case off
    case light
    case standard
    case strong

    /// Radius growth (relative to the touch's starting contact) at which a
    /// still, held finger counts as a deliberate press. The lighter the mode,
    /// the smaller the growth it takes — and the more accidental presses.
    var pressGrowthThreshold: CGFloat {
        switch self {
        case .off: return .infinity
        case .light: return 0.30
        case .standard: return 0.50
        case .strong: return 0.80
        }
    }

    /// The pressure an ordinary (non-deep) tap carries: pressing harder
    /// scales up to full pressure, resting taps stay above this floor.
    var tapPressureFloor: Double {
        switch self {
        case .off: return 1
        case .light: return 0.40
        case .standard: return 0.55
        case .strong: return 0.70
        }
    }
}

/// Scores how much a touch reads as a deliberate Mac trackpad press.
///
/// The signal is the contact patch: `UITouch.majorRadius` widens as the
/// finger presses harder and stays flat when a finger merely rests. Growth
/// relative to the touch's own start — not an absolute radius, which varies
/// by finger size — is what separates "pressing" from "resting", and the
/// hold duration filters out the fast glances that are just taps.
///
/// The engine is pure math with no state, so `GestureEngine` can consult it
/// per finger without bookkeeping here, and when the mode is `off` nothing
/// anywhere pays for it.
struct PressureIntentEngine {
    /// A still touch held at least this long with enough contact growth is a
    /// press: the button goes down and stays down (drag included) until the
    /// finger lifts.
    static let pressHoldDuration: TimeInterval = 0.40

    /// Radius readings sit on a baseline that varies by finger; growth is
    /// measured against this floor so tiny contacts cannot score huge
    /// ratios off noise alone.
    private static let radiusBaseline: CGFloat = 8

    /// 0…1 press depth for a tap that grew from `startRadius` to `endRadius`.
    /// A light landing barely widens the contact and stays at the mode's
    /// floor; pressing into the glass widens it and climbs toward full
    /// pressure, which is exactly what the real trackpad's click feels like.
    static func tapPressure(
        startRadius: CGFloat,
        endRadius: CGFloat,
        mode: PressureMode
    ) -> Double {
        guard mode != .off else { return 1 }
        let growth = growthRatio(startRadius: startRadius, endRadius: endRadius)
        let pressure = mode.tapPressureFloor + Double(growth * pressureGain(mode))
        return min(max(pressure, mode.tapPressureFloor), 1)
    }

    /// Whether a still touch held for `heldDuration` has widened enough to be
    /// a press rather than a resting finger.
    static func isPress(
        startRadius: CGFloat,
        currentRadius: CGFloat,
        heldDuration: TimeInterval,
        mode: PressureMode
    ) -> Bool {
        guard mode != .off, heldDuration >= pressHoldDuration else { return false }
        let growth = growthRatio(startRadius: startRadius, endRadius: currentRadius)
        return growth >= mode.pressGrowthThreshold
    }

    /// How fast growth converts into pressure: the lighter the mode, the
    /// sooner a touch grades up toward full pressure.
    private static func pressureGain(_ mode: PressureMode) -> CGFloat {
        switch mode {
        case .off: return 0
        case .light: return 0.9
        case .standard: return 0.9
        case .strong: return 0.6
        }
    }

    static func growthRatio(startRadius: CGFloat, endRadius: CGFloat) -> CGFloat {
        max(endRadius - startRadius, 0) / max(startRadius, radiusBaseline)
    }
}
