import CoreGraphics
import Foundation

/// Everything the pressure debug overlay shows, as one value so the 4 Hz
/// refresh is a single SwiftUI publish.
struct PressureDebugInfo: Equatable {
    let radius: CGFloat
    let startRadius: CGFloat
    /// `currentRadius - startRadius`.
    let growth: CGFloat
    /// Cumulative |Δradius| over the touch.
    let accumulatedGrowth: CGFloat
    let durationMs: Int
    /// Finger speed in points per second.
    let velocity: CGFloat
    let score: Double
    let state: PressState
}
