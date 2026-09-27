import CoreGraphics
import Foundation

/// One pressure-recognition observation, derived from a raw `TouchSample`
/// plus the sample before it: the recognizer scores these, never raw touches.
///
/// `velocity` is the instantaneous finger speed in points per second and
/// `isMoving` is its thresholded verdict — a still finger and a wandering
/// finger must score differently even at the same radius.
struct PressureSample {
    let timestamp: TimeInterval
    let location: CGPoint
    let majorRadius: CGFloat
    let velocity: CGPoint
    let isMoving: Bool
}
