import Combine
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol
import OSLog
import SwiftUI

/// Orchestrates the trackpad page: touch callbacks in, binary input batches
/// out.
///
/// The pipeline is the plan's stack, one stage per type:
/// `TouchProcessor` → `GestureEngine` → `VelocityCalculator` →
/// `AccelerationCurve` → `InputEvent` → `InputEncoder` → connection.
///
/// This type knows nothing about which transport carries the session — it
/// hands batches to the app model and reacts to connection state changes,
/// which is what lets the trackpad survive a Wi-Fi↔Bluetooth handoff without
/// caring that one happened.
@MainActor
final class RemoteTrackpadModel: ObservableObject {
    @Published private(set) var phase: TrackpadPhase = .idle
    /// Text key of the failure that stopped the session from arming
    /// (accessibility missing, Mac too old, …). `nil` once armed.
    @Published private(set) var beginErrorKey: String?
    @Published private(set) var keyboardActive = false
    @Published private(set) var orientation: TrackpadOrientation {
        didSet { store.orientation = orientation }
    }
    @Published var settings: TrackpadSettings {
        didSet {
            store.settings = settings
            engine.tapToClick = settings.tapToClick
            engine.naturalScrolling = settings.naturalScrolling
            acceleration.trackingSpeed = settings.trackingSpeed
        }
    }

    private weak var appModel: RemoteAppModel?
    private var store = TrackpadSettingsStore()
    /// True when the Mac injects through its own virtual HID device: macOS
    /// applies its pointer curve, so raw finger deltas leave this side and the
    /// local acceleration is bypassed. Refreshed on every (re)begin.
    private var usesSystemAcceleration = false

    /// Switches the finger→cursor mapping. Only the mapping changes: the page
    /// never rotates itself with the device.
    func setOrientation(_ orientation: TrackpadOrientation) {
        self.orientation = orientation
    }

    private var engine = GestureEngine()
    private var velocity = VelocityCalculator()
    private var acceleration = AccelerationCurve()
    private var inertia = InertiaProcessor()
    private var scrollVelocity = VelocityCalculator()

    /// Accumulated raw finger travel, feeding the velocity estimate.
    private var cursorTravel = CGPoint.zero
    private var scrollTravel = CGPoint.zero
    /// Sub-pixel remainders so quantizing to integer deltas never drifts.
    private var cursorRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero

    /// Events waiting for the next flush. Moves merge; clicks wait in order.
    private var pending: [InputEvent] = []
    private var pendingTouchAt: TimeInterval?
    private var hapticAfterSend = false
    private var flushTask: Task<Void, Never>?
    private var beginTask: Task<Void, Never>?
    private var keyboardRequestTask: Task<Void, Never>?
    private var keyboardRecheckTask: Task<Void, Never>?
    private var keyboardRecheckPending = false
    private var textInputTask: Task<Void, Never>?
    private var textInputEpoch = 0

    /// The flush cadence: 120 Hz, matching the touch sample rate.
    static let flushInterval: TimeInterval = 1.0 / 120.0
    /// When the queue runs long, pointer motion is the one stream where
    /// freshness beats completeness: keep the newest move, keep every click.
    private static let maximumPendingEvents = 24

    /// Local input-stage diagnostics, sampled every couple of seconds — never
    /// per event, the flush loop is too hot for that.
    private let logger = Logger(subsystem: "com.misswell.macpilot.remote", category: "Trackpad")
    private var batchesSent = 0
    private var eventsSent = 0
    private var lastSendLogAt = Date()
    private var didLogFirstBatch = false
    private var touchToSendSamples = 0
    private var touchToSendTotalMs = 0.0
    private var touchToSendMaxMs = 0.0

    init() {
        let stored = store
        orientation = stored.orientation
        settings = stored.settings
        engine.tapToClick = settings.tapToClick
        engine.naturalScrolling = settings.naturalScrolling
        acceleration.trackingSpeed = settings.trackingSpeed
    }

    // MARK: - Lifecycle

    func open(appModel: RemoteAppModel) {
        guard phase == .idle else { return }
        self.appModel = appModel
        // Defense in depth for a Mac that does not advertise the realtime
        // channel: sending `beginRealtimeInput` anyway would make an older
        // Mac fail to decode the command and drop the whole session. Say so
        // and stop instead.
        guard appModel.supportsRealtimeInput else {
            beginErrorKey = "trackpadNeedsMacUpdate"
            phase = .disconnected
            return
        }
        phase = .entering
        beginErrorKey = nil
        engine.reset()
        startFlushLoop()
        beginTask = Task { await beginSession() }
    }

    func close() {
        guard phase != .idle, phase != .exiting else { return }
        phase = .exiting
        beginTask?.cancel()
        beginTask = nil
        pending.removeAll()
        pendingTouchAt = nil
        inertia.stop()
        keyboardActive = false
        keyboardRequestTask?.cancel()
        keyboardRequestTask = nil
        keyboardRecheckTask?.cancel()
        keyboardRecheckTask = nil
        keyboardRecheckPending = false
        let appModel = self.appModel
        let pendingText = textInputTask
        Task {
            await pendingText?.value
            await appModel?.endTextInput()
            await appModel?.endRealtimeInput()
            self.phase = .idle
        }
    }

    private func beginSession() async {
        defer { beginTask = nil }
        guard let appModel else { return }
        guard appModel.connectionState.isConnected else {
            // The page opened while the supervisor was still dialling; the
            // state observer re-begins the moment the link is up.
            phase = .reconnecting
            return
        }
        switch await appModel.beginRealtimeInput() {
        case .failure(let error):
            beginErrorKey = error.messageKey
            phase = .disconnected
        case .success(let session):
            beginErrorKey = nil
            usesSystemAcceleration = session.usesSystemAcceleration
            engine.keyboardEnabled = session.supportsTextInput
            phase = .active
            batchesSent = 0
            eventsSent = 0
            lastSendLogAt = Date()
            didLogFirstBatch = false
            logger.info("realtime session armed systemAcceleration=\(session.usesSystemAcceleration)")
            // The flush loop stops whenever the page leaves the active states,
            // so every re-entry after a reconnect restarts it here.
            startFlushLoop()
        }
    }

    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase.isActiveLike {
                self.tickGestures()
                self.flushIfNeeded()
                self.recheckKeyboardAfterClickIfNeeded()
                self.emitHapticIfNeeded()
                try? await Task.sleep(for: .seconds(Self.flushInterval))
            }
        }
    }

    /// Called from the view whenever the app model's connection state moves.
    func connectionStateChanged(_ state: RemoteConnectionState) {
        switch state {
        case .connected:
            guard phase == .reconnecting, beginTask == nil else { return }
            beginTask = Task { await beginSession() }
        case .reconnecting:
            guard phase.isActiveLike else { return }
            phase = .reconnecting
            dropMotion()
        case .failed, .idle, .discovering:
            guard phase.isActiveLike else { return }
            phase = .disconnected
            dropMotion()
        case .connecting, .pairing, .authenticating:
            break
        }
    }

    private func dropMotion() {
        keyboardActive = false
        textInputEpoch += 1
        keyboardRequestTask?.cancel()
        keyboardRequestTask = nil
        keyboardRecheckTask?.cancel()
        keyboardRecheckTask = nil
        keyboardRecheckPending = false
        pending.removeAll()
        pendingTouchAt = nil
        inertia.stop()
        engine.reset()
        velocity.reset()
        scrollVelocity.reset()
        cursorTravel = .zero
        scrollTravel = .zero
    }

    // MARK: - Touch ingestion

    func handleTouchEvent(
        phase touchPhase: TouchPhase,
        samples: [TouchSample],
        centroid: CGPoint?,
        touchCount: Int
    ) {
        guard self.phase.isActiveLike else { return }
        let time = touchTime(of: samples)
        let outputs: [GestureOutput]
        switch touchPhase {
        case .began:
            outputs = engine.handleBegan(samples: samples, touchCount: touchCount, centroid: centroid, time: time)
        case .moved:
            outputs = engine.handleMoved(samples: samples, touchCount: touchCount, centroid: centroid, time: time)
        case .ended:
            outputs = engine.handleEnded(samples: samples, remaining: touchCount, time: time)
        case .cancelled:
            outputs = engine.handleCancelled(remaining: touchCount)
        }
        if !outputs.isEmpty, !samples.isEmpty {
            pendingTouchAt = min(pendingTouchAt ?? time, time)
        }
        apply(outputs)
        // Touch callbacks already contain the coalesced samples for this display
        // frame. Send them now instead of waiting for the next gesture/inertia tick.
        flushIfNeeded()
        pendingTouchAt = nil
        recheckKeyboardAfterClickIfNeeded()
        emitHapticIfNeeded()
    }

    private func emitHapticIfNeeded() {
        if hapticAfterSend {
            hapticAfterSend = false
            Haptics.impact()
        }
    }

    private func touchTime(of samples: [TouchSample]) -> TimeInterval {
        if let last = samples.last { return last.time }
        return ProcessInfo.processInfo.systemUptime
    }

    private func apply(_ outputs: [GestureOutput]) {
        for output in outputs {
            switch output {
            case let .cursor(dx, dy, dragging, time):
                let (mdx, mdy) = mapped(dx: dx, dy: dy)
                if usesSystemAcceleration {
                    // The Mac's virtual HID device rides macOS's own pointer
                    // curve; adding ours would double it.
                    append(.move(
                        dx: quantized(mdx, into: &cursorRemainder.x),
                        dy: quantized(mdy, into: &cursorRemainder.y),
                        dragging: dragging
                    ))
                } else {
                    cursorTravel.x += mdx
                    cursorTravel.y += mdy
                    let velocity = velocity.record(position: cursorTravel, time: time)
                    let speed = hypot(velocity.x, velocity.y)
                    let scaled = acceleration.apply(dx: mdx, dy: mdy, fingerSpeed: speed)
                    append(.move(
                        dx: quantized(scaled.x, into: &cursorRemainder.x),
                        dy: quantized(scaled.y, into: &cursorRemainder.y),
                        dragging: dragging
                    ))
                }

            case let .scroll(dx, dy, time):
                scrollTravel.x += dx
                scrollTravel.y += dy
                scrollVelocity.record(position: scrollTravel, time: time)
                let gain = GestureEngine.scrollGain
                append(.scroll(
                    dx: quantized(dx * gain, into: &scrollRemainder.x),
                    dy: quantized(dy * gain, into: &scrollRemainder.y)
                ))

            case let .scrollEnd(velocityX, velocityY):
                guard settings.scrollInertia else { continue }
                let (vx, vy) = mapped(dx: velocityX, dy: velocityY)
                inertia.start(velocity: CGPoint(x: vx, y: vy))

            case let .click(button, action):
                append(.click(button: button, action: action))
                if action == .down { hapticAfterSend = true }
                if action == .up, keyboardActive {
                    keyboardRecheckPending = true
                }
            case .requestKeyboard:
                requestKeyboard()
            }
        }
    }

    private func requestKeyboard() {
        guard !keyboardActive, keyboardRequestTask == nil, let appModel else { return }
        keyboardRequestTask = Task { [weak self] in
            // A quick dismissal followed by another double tap must finish
            // the previous end command before starting the new session.
            await self?.textInputTask?.value
            guard !Task.isCancelled else { return }
            let accepted = await appModel.beginTextInput()
            guard let self else { return }
            self.keyboardRequestTask = nil
            guard self.phase == .active, !Task.isCancelled else { return }
            if accepted {
                self.textInputEpoch += 1
                self.keyboardActive = true
            } else {
                // Preserve the second click when the pointer is not on text.
                self.append(.click(button: .left, action: .down))
                self.append(.click(button: .left, action: .up))
                self.flushIfNeeded()
            }
        }
    }

    private func recheckKeyboardAfterClickIfNeeded() {
        guard keyboardRecheckPending, keyboardRecheckTask == nil,
              keyboardActive, let appModel else { return }
        keyboardRecheckPending = false
        keyboardRecheckTask = Task { [weak self] in
            // The click batch was already sent. Finish any committed text
            // before replacing the Mac's pinned editable target.
            await self?.textInputTask?.value
            guard let self else { return }
            guard !Task.isCancelled, self.keyboardActive else {
                self.keyboardRecheckTask = nil
                return
            }
            let stillEditable = await appModel.beginTextInput()
            self.keyboardRecheckTask = nil
            guard !Task.isCancelled, self.keyboardActive else { return }
            if !stillEditable { self.dismissKeyboard() }
            if self.keyboardRecheckPending { self.recheckKeyboardAfterClickIfNeeded() }
        }
    }

    func sendTextInput(_ operation: RemoteTextInputOperation) {
        guard keyboardActive, let appModel else { return }
        if case let .insert(text) = operation {
            for chunk in Self.textChunks(text) {
                enqueueTextInput(.insert(chunk), appModel: appModel)
            }
        } else {
            enqueueTextInput(operation, appModel: appModel)
        }
    }

    private static func textChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var units = 0
        for scalar in text.unicodeScalars {
            let scalarUnits = scalar.value > 0xFFFF ? 2 : 1
            if units + scalarUnits > 256 {
                chunks.append(chunk)
                chunk = ""
                units = 0
            }
            chunk.unicodeScalars.append(scalar)
            units += scalarUnits
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func enqueueTextInput(_ operation: RemoteTextInputOperation, appModel: RemoteAppModel) {
        let previous = textInputTask
        let epoch = textInputEpoch
        textInputTask = Task { [weak self] in
            await previous?.value
            // Committed keys still drain if the user immediately dismisses
            // the keyboard or leaves the page.
            guard let self, self.textInputEpoch == epoch else { return }
            if !(await appModel.sendTextInput(operation)) {
                self.keyboardActive = false
                self.textInputEpoch += 1
                await appModel.endTextInput()
            }
        }
    }

    func dismissKeyboard() {
        guard keyboardActive else { return }
        keyboardActive = false
        keyboardRecheckPending = false
        keyboardRecheckTask?.cancel()
        keyboardRecheckTask = nil
        guard let appModel else { return }
        let previous = textInputTask
        textInputTask = Task {
            await previous?.value
            await appModel.endTextInput()
        }
    }

    /// Runs each flush cycle so gestures can complete without waiting for a
    /// touch callback (drag arming) and so the glide keeps scrolling.
    private func tickGestures() {
        let now = ProcessInfo.processInfo.systemUptime
        apply(engine.tick(time: now))
        if let delta = inertia.tick(dt: Self.flushInterval) {
            let gain = GestureEngine.scrollGain
            append(.scroll(
                dx: quantized(delta.x * gain, into: &scrollRemainder.x),
                dy: quantized(delta.y * gain, into: &scrollRemainder.y)
            ))
        }
    }

    // MARK: - Motion helpers

    /// Rotates finger deltas for the orientation the user is holding. Landscape
    /// assumes the phone's top points to the user's left.
    private func mapped(dx: Double, dy: Double) -> (Double, Double) {
        switch orientation {
        case .portrait:
            return (dx, dy)
        case .landscape:
            return (-dy, dx)
        }
    }

    private func quantized(_ value: Double, into remainder: inout CGFloat) -> Double {
        let total = value + Double(remainder)
        let rounded = total.rounded()
        remainder = CGFloat(total - rounded)
        return rounded
    }

    private func append(_ event: InputEvent) {
        // Consecutive moves with the same button state merge into one: same
        // total travel, fewer packets. A button state change always stays its
        // own event — the Mac must see the press as an ordered step.
        if case .move(let dx, let dy, let dragging) = event,
           let last = pending.last,
           case .move(let lastDx, let lastDy, let lastDragging) = last,
           lastDragging == dragging {
            pending[pending.count - 1] = .move(dx: lastDx + dx, dy: lastDy + dy, dragging: dragging)
            return
        }
        if case .scroll(let dx, let dy) = event,
           let last = pending.last,
           case .scroll(let lastDx, let lastDy) = last {
            pending[pending.count - 1] = .scroll(dx: lastDx + dx, dy: lastDy + dy)
            return
        }
        pending.append(event)
    }

    // MARK: - Flush

    private func flushIfNeeded() {
        guard !pending.isEmpty else { return }
        guard let appModel, appModel.connectionState.isConnected, phase == .active else {
            // No link, no queue: the state observer already flipped the page
            // into reconnecting, and stale deltas would only jerk the cursor.
            pending.removeAll()
            pendingTouchAt = nil
            return
        }
        coalescePending()
        let batch = InputEncoder.encode(pending)
        pending.removeAll()
        let oldestTouchAt = pendingTouchAt
        pendingTouchAt = nil
        // Send before diagnostics: even a sampled log can stall the main
        // actor, and the touch-to-send measure should include encoding.
        appModel.sendRealtimeInput(batch)
        if let oldestTouchAt {
            let milliseconds = max(0, (ProcessInfo.processInfo.systemUptime - oldestTouchAt) * 1_000)
            touchToSendSamples += 1
            touchToSendTotalMs += milliseconds
            touchToSendMaxMs = max(touchToSendMaxMs, milliseconds)
        }
        batchesSent += 1
        eventsSent += batch.events.count
        if !didLogFirstBatch {
            didLogFirstBatch = true
            logger.info("first batch sent events=\(batch.events.count)")
        }
        let sinceLog = Date().timeIntervalSince(lastSendLogAt)
        if sinceLog >= 2 {
            let average = touchToSendSamples == 0 ? 0 : touchToSendTotalMs / Double(touchToSendSamples)
            logger.info("input sent batches=\(self.batchesSent) events/s=\(Int(Double(self.eventsSent) / sinceLog)) touchToSendAvgMs=\(average) touchToSendMaxMs=\(self.touchToSendMaxMs)")
            batchesSent = 0
            eventsSent = 0
            touchToSendSamples = 0
            touchToSendTotalMs = 0
            touchToSendMaxMs = 0
            lastSendLogAt = Date()
        }
    }

    private func coalescePending() {
        guard pending.count > Self.maximumPendingEvents else { return }
        var kept: [InputEvent] = []
        var lastMoveIndex: Int?
        for (index, event) in pending.enumerated() {
            if case .move = event {
                lastMoveIndex = index
            }
        }
        for (index, event) in pending.enumerated() {
            switch event {
            case .move:
                if index == lastMoveIndex {
                    kept.append(event)
                }
            default:
                kept.append(event)
            }
        }
        pending = kept
    }
}
