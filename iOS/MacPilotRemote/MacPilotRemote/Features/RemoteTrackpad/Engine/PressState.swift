import Foundation

/// The press recognizer's state machine. One state per finger — no flag
/// combinations anywhere else.
enum PressState: Equatable {
    /// No finger.
    case idle
    /// Finger just touched down; baseline recorded.
    case touching
    /// Past the optimistic-click decision window, still scoring.
    case analyzing
    /// Press confirmed: the button is down on the Mac.
    case pressed
    /// Confirmed press with the finger moving (a drag).
    case dragging
    /// Finished; the recognizer is spent until the next touch.
    case released
}
