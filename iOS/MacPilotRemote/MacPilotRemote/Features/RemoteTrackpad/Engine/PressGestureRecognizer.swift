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

/// The per-finger press state machine: touch → analyzing → pressed.
///
/// The optimistic click contract lives here. A touchdown sends nothing; a
/// quick release is graded into the plain click the gesture engine already
/// emits on lift, so ordinary tapping never waits. Only a touch whose score
/// crosses the mode's bar while still on the glass actuates early — the
/// button goes down exactly like a physical trackpad click, the pressure
/// grades as the contact deepens, and the release lands when the finger
/// lifts. Travel cancels: past `TouchHistory.movementCancel` a finger is a
/// cursor and the recognizer stands down for good.
struct PressGestureRecognizer {
    enum State: Equatable {
        case touching
        case pressed
        case cancelled
    }

    private(set) var state: State = .touching
    private(set) var history = TouchHistory()
    private var config: PressureConfig
    /// Last pressure the recognizer handed out, so a lift can re-report it.
    private(set) var lastPressure: Double = 0
    private var lastEmittedPressure: Double = 0

    init(config: PressureConfig) {
        self.config = config
    }

    /// True once the button is down on the Mac and the lift must release it.
    var isActive: Bool { state == .pressed }

    mutating func begin(_ sample: TouchSample) {
        history.append(sample)
    }

    /// Feeds one sample; may emit a graded pressure while pressed.
    mutating func update(_ sample: TouchSample) -> PressGestureEvent? {
        guard state != .cancelled else { return nil }
        history.append(sample)
        guard state == .pressed else { return nil }
        let score = PressureIntentEngine.score(history: history, config: config, now: sample.time)
        let pressure = PressureCurve.pressure(score: score, config: config)
        // Rate-limit the stream: only meaningful grade changes travel.
        if abs(pressure - lastEmittedPressure) >= 0.12 {
            lastEmittedPressure = pressure
            lastPressure = pressure
            return .graded(pressure: pressure)
        }
        return nil
    }

    /// Runs each flush cycle; actuates the press once the score crosses the
    /// bar. Returns `.began` on the transition frame.
    mutating func tick(now: TimeInterval) -> PressGestureEvent? {
        guard state == .touching else { return nil }
        let score = PressureIntentEngine.score(history: history, config: config, now: now)
        guard score >= config.actuationScore else { return nil }
        state = .pressed
        let pressure = PressureCurve.pressure(score: score, config: config)
        lastEmittedPressure = pressure
        lastPressure = pressure
        return .began(pressure: pressure)
    }

    /// The finger lifted. While pressed this releases the button; while
    /// merely touching it reports the final score so the plain click can
    /// carry a grade.
    mutating func end(now: TimeInterval) -> PressGestureEvent? {
        switch state {
        case .pressed:
            state = .cancelled
            return .ended
        case .touching:
            let score = PressureIntentEngine.score(history: history, config: config, now: now)
            lastPressure = PressureCurve.pressure(score: score, config: config)
            return nil
        case .cancelled:
            return nil
        }
    }

    /// Telemetry for the debug overlay.
    func snapshot(now: TimeInterval) -> (radius: CGFloat, radiusDelta: CGFloat, durationMs: Int, velocity: Double, score: Double, state: String)? {
        guard state != .cancelled, !history.isEmpty else { return nil }
        let growth = history.growthRatio(baseline: PressureIntentEngine.radiusBaseline)
        return (
            radius: history.currentRadius,
            radiusDelta: history.currentRadius - history.startRadius,
            durationMs: Int(history.heldDuration(now: now) * 1000),
            velocity: history.radiusVelocity(now: now, baseline: PressureIntentEngine.radiusBaseline),
            score: PressureIntentEngine.score(history: history, config: config, now: now),
            state: state == .pressed ? "pressed" : "analyzing"
        )
    }
}
