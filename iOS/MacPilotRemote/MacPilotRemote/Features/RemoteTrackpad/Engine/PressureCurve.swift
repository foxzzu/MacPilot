import Foundation

/// Maps a press score onto injected pressure.
///
/// Deliberately not linear: `pow(score, 0.7)` lifts the low end, so a
/// half-recognized light press still reads as a substantial click — the
/// difference between "the trackpad heard me" and silence.
enum PressureCurve {
    static func pressure(score: Double) -> Double {
        pow(min(max(score, 0), 1), 0.7)
    }
}
