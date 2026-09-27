import CoreGraphics
import Foundation
import MacPilotRemoteProtocol

/// One action out of the gesture engine.
///
/// Cursor and scroll deltas are raw finger pixels in screen coordinates;
/// velocity smoothing, acceleration and inertia are applied downstream so this
/// value stays a faithful record of what the hand did. `time` rides along on
/// cursor events because the downstream velocity estimate needs the sample
/// cadence, not just the deltas.
enum GestureOutput: Equatable {
    case cursor(dx: Double, dy: Double, dragging: Bool, time: TimeInterval)
    /// `pressure` is 1 unless the pressure simulation is grading this click.
    case click(button: RemoteInputButton, action: RemoteInputAction, pressure: Double)
    /// The continuous press: button down while the finger is still on the
    /// glass, graded as the contact deepens, released on lift.
    case pressBegan(button: RemoteInputButton, pressure: Double)
    case pressGraded(pressure: Double)
    case pressEnded(button: RemoteInputButton)
    /// Two-finger scrolling in finger pixels, content direction.
    case scroll(dx: Double, dy: Double, time: TimeInterval)
    /// The fingers lifted mid-scroll; carries the finger velocity (points/s)
    /// so the pipeline can start the glide.
    case scrollEnd(velocityX: Double, velocityY: Double)
    /// A quiet tap asks the Mac whether the pointer landed on text.
    case requestKeyboard
}

/// Magic-Trackpad style gestures over raw touch callbacks:
///
/// - one finger: moves the cursor; a quick quiet tap clicks; two quick taps in
///   a row make a double click; a second tap held (or moved) starts a drag
///   until the finger lifts. Under pressure simulation a firm, still, widening
///   touch actuates the button early — the press — and grades while held.
/// - two fingers: centroid motion scrolls; a quiet short two-finger touch is a
///   right click.
///
/// The engine is a plain struct driven by the callbacks plus one `tick` per
/// flush cycle, so the whole gesture layer is value-semantic and testable.
struct GestureEngine {
    var tapToClick: Bool = true
    var keyboardEnabled: Bool = false
    var naturalScrolling: Bool = true
    /// When on, a per-finger `PressGestureRecognizer` watches the contact
    /// patch; off, no recognizer exists and every click leaves at full
    /// pressure exactly as before.
    var pressureMode: PressureMode = .off

    /// Tunables. Generous slop keeps resting fingers from drifting the cursor;
    /// the tap window matches the built-in trackpad's feel.
    static let movementSlop: CGFloat = 9
    static let tapMaximumDuration: TimeInterval = 0.28
    static let doubleTapWindow: TimeInterval = 0.32
    /// How long the second tap must rest before it becomes a drag.
    static let dragHoldDuration: TimeInterval = 0.22
    static let scrollGain: Double = 2.4

    private struct OneFinger {
        var start: CGPoint
        var position: CGPoint
        var startTime: TimeInterval
        var moved: Bool
        /// This finger is the second tap of a potential tap-drag pair.
        var armedForDrag: Bool
        var dragging: Bool
        /// Present only while pressure simulation is on: watches the contact
        /// patch and actuates the press when the score crosses the bar.
        var press: PressGestureRecognizer?
    }

    private struct TwoFinger {
        var centroid: CGPoint
        var startTime: TimeInterval
        var moved: Bool
        /// Both fingers landed without cursor movement — required for a right
        /// click, so a mid-drag second finger can never produce one.
        var beganQuietly: Bool
    }

    private enum Mode {
        case idle
        case oneFinger(OneFinger)
        case twoFinger(TwoFinger)
    }

    private var mode = Mode.idle
    /// When the last completed tap ended, for double-tap detection.
    private var lastTapEndedAt: TimeInterval?

    /// Velocity of the last scroll gesture, tracked here so `scrollEnd` can
    /// hand the pipeline a real fling.
    private var scrollVelocity = VelocityCalculator()
    private var scrollPosition = CGPoint.zero

    // MARK: - Callbacks

    mutating func handleBegan(
        samples: [TouchSample],
        touchCount: Int,
        centroid: CGPoint?,
        time: TimeInterval
    ) -> [GestureOutput] {
        guard let first = samples.first else { return [] }
        if touchCount >= 2, let centroid {
            // A drag owns the gesture; an extra finger never turns it into a
            // scroll mid-press.
            if case .oneFinger(let finger) = mode, finger.dragging || finger.armedForDrag {
                return []
            }
            scrollVelocity.reset()
            scrollPosition = .zero
            let quiet: Bool
            if case .oneFinger(let finger) = mode {
                quiet = !finger.moved
            } else {
                quiet = true
            }
            mode = .twoFinger(TwoFinger(centroid: centroid, startTime: time, moved: false, beganQuietly: quiet))
            return []
        }
        guard touchCount == 1 else { return [] }
        let armed: Bool
        if let lastTapEndedAt, time - lastTapEndedAt <= Self.doubleTapWindow {
            armed = true
        } else {
            armed = false
        }
        var press: PressGestureRecognizer?
        if pressureMode != .off {
            press = PressGestureRecognizer(config: PressureConfig.config(for: pressureMode))
            press?.begin(first)
        }
        mode = .oneFinger(
            OneFinger(
                start: first.position,
                position: first.position,
                startTime: time,
                moved: false,
                armedForDrag: armed,
                dragging: false,
                press: press
            )
        )
        return []
    }

    mutating func handleMoved(
        samples: [TouchSample],
        touchCount: Int,
        centroid: CGPoint?,
        time: TimeInterval
    ) -> [GestureOutput] {
        switch mode {
        case .oneFinger(var finger):
            guard touchCount >= 1 else { return [] }
            var outputs: [GestureOutput] = []
            for sample in samples where sample.time >= finger.startTime {
                let dx = sample.position.x - finger.position.x
                let dy = sample.position.y - finger.position.y
                finger.position = sample.position
                // The recognizer sees every sample, even inside the movement
                // slop: pressing in place still widens the contact patch.
                if let event = finger.press?.update(sample) {
                    outputs.append(Self.pressOutput(event))
                }
                if !finger.moved,
                   hypot(finger.position.x - finger.start.x, finger.position.y - finger.start.y) > Self.movementSlop {
                    finger.moved = true
                    // A second tap that moves becomes a drag right away —
                    // waiting out the hold timer here would feel broken.
                    if finger.armedForDrag, !finger.dragging {
                        finger.dragging = true
                        outputs.append(.click(button: .left, action: .down, pressure: 1))
                    }
                }
                if finger.dragging || finger.moved {
                    outputs.append(.cursor(dx: Double(dx), dy: Double(dy), dragging: finger.dragging, time: sample.time))
                }
            }
            mode = .oneFinger(finger)
            return outputs

        case .twoFinger(var gesture):
            guard let centroid else { return [] }
            let dx = centroid.x - gesture.centroid.x
            let dy = centroid.y - gesture.centroid.y
            gesture.centroid = centroid
            if hypot(dx, dy) > 0.5 {
                gesture.moved = true
            }
            mode = .twoFinger(gesture)
            guard gesture.moved else { return [] }
            scrollPosition.x += Double(dx)
            scrollPosition.y += Double(dy)
            scrollVelocity.record(position: scrollPosition, time: time)
            let gain = Self.scrollGain
            let (adx, ady) = naturalScrolling ? (Double(dx) * gain, Double(dy) * gain) : (-Double(dx) * gain, -Double(dy) * gain)
            return [.scroll(dx: adx, dy: ady, time: time)]

        case .idle:
            return []
        }
    }

    mutating func handleEnded(
        samples: [TouchSample],
        remaining: Int,
        time: TimeInterval
    ) -> [GestureOutput] {
        switch mode {
        case .oneFinger(var finger):
            guard remaining == 0 else { return [] }
            mode = .idle
            let duration = time - finger.startTime
            if finger.dragging {
                lastTapEndedAt = nil
                // A recognized press releases through the press stream; a
                // double-tap drag releases through the plain click.
                let result = finger.press?.end(now: time)
                if result?.released == true {
                    return [.pressEnded(button: .left)]
                }
                return [.click(button: .left, action: .up, pressure: 1)]
            }
            if let sample = samples.first, finger.press != nil {
                _ = finger.press?.update(sample)
            }
            let quiet = !finger.moved && duration <= Self.tapMaximumDuration
            guard quiet, tapToClick else {
                lastTapEndedAt = nil
                return []
            }
            lastTapEndedAt = time
            // The click pair is the click; a second tap inside the window
            // arrives as another pair, which the Mac reads as a double click.
            // An armed tap that holds or moves becomes a drag instead. Every
            // tap also asks whether the pointer landed on text — the same
            // deal as clicking a field with a real mouse. Under pressure
            // simulation the recognizer's final score grades the pair.
            var pressure = 1.0
            if finger.press != nil {
                pressure = finger.press?.end(now: time).pressure ?? 1
            }
            var outputs: [GestureOutput] = [
                .click(button: .left, action: .down, pressure: pressure),
                .click(button: .left, action: .up, pressure: pressure),
            ]
            if keyboardEnabled {
                outputs.append(.requestKeyboard)
            }
            return outputs

        case .twoFinger(let gesture):
            mode = .idle
            if remaining == 0, gesture.beganQuietly, !gesture.moved,
               time - gesture.startTime <= Self.tapMaximumDuration {
                lastTapEndedAt = nil
                return [.click(button: .right, action: .down, pressure: 1), .click(button: .right, action: .up, pressure: 1)]
            }
            if gesture.moved {
                let velocity = scrollVelocity.velocity
                let sign: Double = naturalScrolling ? 1 : -1
                scrollVelocity.reset()
                return [.scrollEnd(velocityX: velocity.x * sign * Self.scrollGain, velocityY: velocity.y * sign * Self.scrollGain)]
            }
            scrollVelocity.reset()
            return []

        case .idle:
            return []
        }
    }

    mutating func handleCancelled(remaining: Int) -> [GestureOutput] {
        switch mode {
        case .oneFinger(var finger):
            if finger.dragging, remaining == 0 {
                mode = .idle
                lastTapEndedAt = nil
                let result = finger.press?.end(now: ProcessInfo.processInfo.systemUptime)
                if result?.released == true {
                    return [.pressEnded(button: .left)]
                }
                return [.click(button: .left, action: .up, pressure: 1)]
            }
            if remaining == 0 { mode = .idle }
            return []
        case .twoFinger:
            mode = .idle
            scrollVelocity.reset()
            return []
        case .idle:
            return []
        }
    }

    /// Runs once per flush cycle so gestures can complete without a touch
    /// callback: the tap-drag hold arming, and under pressure simulation the
    /// press actuation while the finger is still on the glass.
    mutating func tick(time: TimeInterval) -> [GestureOutput] {
        if case .oneFinger(var finger) = mode,
           finger.armedForDrag, !finger.dragging,
           time - finger.startTime >= Self.dragHoldDuration {
            finger.dragging = true
            mode = .oneFinger(finger)
            return [.click(button: .left, action: .down, pressure: 1)]
        }
        if case .oneFinger(var finger) = mode,
           pressureMode != .off, !finger.armedForDrag, !finger.dragging, !finger.moved,
           finger.press != nil {
            // The press may actuate while the finger never left the glass:
            // the button is down from this frame, and motion from here on
            // drags.
            guard let event = finger.press?.tick(now: time) else {
                mode = .oneFinger(finger)
                return []
            }
            finger.dragging = true
            mode = .oneFinger(finger)
            return [Self.pressOutput(event)]
        }
        return []
    }

    mutating func reset() {
        mode = .idle
        lastTapEndedAt = nil
        scrollVelocity.reset()
        scrollPosition = .zero
    }

    /// Pressure simulation telemetry for the debug overlay: nil while no
    /// finger is down or the simulation is off.
    func pressureDebugSnapshot(time: TimeInterval) -> PressureDebugInfo? {
        guard case .oneFinger(let finger) = mode, let press = finger.press else { return nil }
        return press.snapshot(now: time)
    }

    private static func pressOutput(_ event: PressGestureEvent) -> GestureOutput {
        switch event {
        case let .began(pressure): return .pressBegan(button: .left, pressure: pressure)
        case let .graded(pressure): return .pressGraded(pressure: pressure)
        case .ended: return .pressEnded(button: .left)
        }
    }
}
