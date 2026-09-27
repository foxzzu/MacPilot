import Foundation

/// The weighted result of scoring one touch's press intent, kept as named
/// components so the debug overlay can show exactly why a press did or did
/// not fire.
struct PressureScore {
    /// Contact growth relative to the touch's own baseline, normalized by
    /// the mode's expected growth.
    let growth: Double
    /// Cumulative |Δradius| normalized: tiny repeated increases add up, which
    /// is what makes light presses reachable.
    let accumulated: Double
    /// Hold duration: <100 ms = 0, 100–300 ms linear, >300 ms = 1.
    let duration: Double
    /// Instantaneous speed penalty (0…1), subtracted from the sum.
    let movementPenalty: Double
    /// The clamped weighted total, 0…1.
    let value: Double
}
