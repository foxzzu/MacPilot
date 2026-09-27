import CoreGraphics
import Foundation

/// Events the recognizer emits while a finger is down.
enum PressGestureEvent: Equatable {
    /// The press actuated: the button goes down on the Mac now, not on lift.
    case began(pressure: Double)
    /// The contact deepened (or eased) while the button is down.
    case graded(pressure: Double)
    /// The finger lifted: button up.
    case ended
}

/// The per-finger press state machine, driven by `PressState`.
///
/// The optimistic click contract lives here. A touchdown sends nothing; a
/// release inside the decision window grades the plain click the gesture
/// engine already emits on lift, so ordinary tapping never waits. Only a
/// touch whose score crosses the mode's threshold while still on the glass
/// actuates early — the button goes down exactly like a physical trackpad
/// click, the pressure grades as the contact deepens, and the release lands
/// when the finger lifts. Travel past `TouchHistory.movementCancel` cancels
/// the press outright: a moving finger is a cursor, never a press.
struct PressGestureRecognizer {
    private(set) var state: PressState = .touching
    private(set) var history: TouchHistory = .empty()
    private var config: PressureConfig
    /// Last pressure handed out, so a lift can re-report it.
    private(set) var lastPressure: Double = 0
    private var lastEmittedPressure: Double = 0
    /// The raw sample before the newest one: velocity needs a pair.
    private var lastRaw: TouchSample?

    init(config: PressureConfig) {
        self.config = config
    }

    /// True once the button is down on the Mac and the lift must release it.
    var isActive: Bool { state == .pressed || state == .dragging }

    mutating func begin(_ sample: TouchSample) {
        history = TouchHistory(sample: convert(sample, previous: nil))
        lastRaw = sample
    }

    /// Feeds one raw sample; may emit a graded pressure while pressed.
    mutating func update(_ sample: TouchSample) -> PressGestureEvent? {
        guard state != .released, state != .idle else { return nil }
        let pressureSample = convert(sample, previous: lastRaw)
        lastRaw = sample
        history.append(pressureSample)

        // A confirmed press that starts moving becomes a drag — same button,
        // same stream, purely a semantic step for state and debug.
        if state == .pressed,
           pressureSample.isMoving,
           history.movementDistance > GestureEngine.movementSlop {
            state = .dragging
        }
        guard state == .pressed || state == .dragging else { return nil }
        let pressure = PressureCurve.pressure(score: PressureIntentEngine.score(history: history, config: config).value)
        // Rate-limit the stream: only grade changes of 0.03+ travel.
        if abs(pressure - lastEmittedPressure) >= 0.03 {
            lastEmittedPressure = pressure
            lastPressure = pressure
            return .graded(pressure: pressure)
        }
        return nil
    }

    /// Runs each flush cycle. Inside the decision window the touch just
    /// turns analyzing; past it, a score at or above the threshold
    /// actuates the press and returns `.began` on that transition frame.
    mutating func tick(now: TimeInterval) -> PressGestureEvent? {
        switch state {
        case .touching:
            if now - history.startTimestamp >= PressureIntentEngine.decisionWindow {
                state = .analyzing
            }
            return nil
        case .analyzing:
            // Hard cancel: travelled far enough to be a cursor, full stop.
            if history.movementDistance >= TouchHistory.movementCancel {
                state = .released
                return nil
            }
            let score = PressureIntentEngine.score(history: history, config: config)
            guard score.value >= config.actuationScore else { return nil }
            state = .pressed
            lastEmittedPressure = score.value
            lastPressure = PressureCurve.pressure(score: score.value)
            return .began(pressure: lastPressure)
        default:
            return nil
        }
    }

    /// The finger lifted. A pressed touch releases the button; a touching or
    /// analyzing one reports its final score so the plain click can carry a
    /// grade. Either way the recognizer is spent.
    mutating func end(now: TimeInterval) -> (released: Bool, pressure: Double) {
        let score = PressureIntentEngine.score(history: history, config: config)
        let pressure = lastPressure > 0 ? lastPressure : PressureCurve.pressure(score: score.value)
        let wasActive = isActive
        state = .released
        return (wasActive, pressure)
    }

    /// Telemetry for the debug overlay.
    func snapshot(now: TimeInterval) -> PressureDebugInfo? {
        guard state != .idle, state != .released, !history.isEmpty else { return nil }
        let score = PressureIntentEngine.score(history: history, config: config)
        return PressureDebugInfo(
            radius: history.currentRadius,
            startRadius: history.startRadius,
            growth: history.currentRadius - history.startRadius,
            accumulatedGrowth: history.accumulatedGrowth,
            durationMs: Int(history.duration * 1000),
            velocity: history.velocity,
            score: score.value,
            state: state
        )
    }

    /// Builds the recognizer's sample view of a raw touch: speed against the
    /// previous sample, thresholded into the moving verdict.
    private func convert(_ sample: TouchSample, previous: TouchSample?) -> PressureSample {
        guard let previous, sample.time > previous.time else {
            return PressureSample(timestamp: sample.time, location: sample.position, majorRadius: sample.majorRadius, velocity: .zero, isMoving: false)
        }
        let elapsed = sample.time - previous.time
        let dx = sample.position.x - previous.position.x
        let dy = sample.position.y - previous.position.y
        let velocity = CGPoint(x: dx / elapsed, y: dy / elapsed)
        let speed = hypot(velocity.x, velocity.y)
        return PressureSample(
            timestamp: sample.time,
            location: sample.position,
            majorRadius: sample.majorRadius,
            velocity: velocity,
            isMoving: speed > 25
        )
    }
}
