import Foundation
import Testing
@testable import MacPilot

private final class WindowFocusThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false

    func record() {
        lock.lock()
        observedMainThread = Thread.isMainThread
        lock.unlock()
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMainThread
    }
}

private final class WindowFocusAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct WindowFocusServiceTests {
    @Test @MainActor func externalWindowFocusRunsOffMainActor() async {
        let probe = WindowFocusThreadProbe()
        let ownProcessID = ProcessInfo.processInfo.processIdentifier

        _ = await WindowFocusService.focus(
            WindowFocusTarget(
                processID: ownProcessID + 1,
                axWindow: nil,
                windowNumber: nil,
                isMinimized: false,
                ownProcessID: ownProcessID
            ),
            performer: { _ in
                probe.record()
                return WindowFocusAttemptOutcome()
            },
            environment: { _ in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(!probe.ranOnMainThread)
    }

    @Test @MainActor func ownWindowFocusRunsOnMainActor() async {
        let probe = WindowFocusThreadProbe()
        let ownProcessID = ProcessInfo.processInfo.processIdentifier

        _ = await WindowFocusService.focus(
            WindowFocusTarget(
                processID: ownProcessID,
                axWindow: nil,
                windowNumber: nil,
                isMinimized: false,
                ownProcessID: ownProcessID
            ),
            performer: { _ in
                probe.record()
                return WindowFocusAttemptOutcome()
            },
            environment: { _ in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(probe.ranOnMainThread)
    }

    @Test @MainActor func focusPipelineRetriesUntilTheTargetVerifies() async {
        let probe = WindowFocusAttemptProbe()
        let target = WindowFocusTarget(
            processID: 4242,
            axWindow: nil,
            windowNumber: nil,
            isMinimized: false,
            ownProcessID: 4243
        )

        let verified = await WindowFocusService.focus(
            target,
            performer: { _ in
                probe.record()
                var outcome = WindowFocusAttemptOutcome()
                outcome.activatedApplication = true
                return outcome
            },
            environment: { target in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: probe.attemptCount >= 2 ? target.processID : nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(verified)
        #expect(probe.attemptCount == 2)
    }

    @Test @MainActor func focusPipelineGivesUpAfterTheFinalRetryWithoutVerification() async {
        let probe = WindowFocusAttemptProbe()
        let target = WindowFocusTarget(
            processID: 4242,
            axWindow: nil,
            windowNumber: nil,
            isMinimized: false,
            ownProcessID: 4243
        )

        let verified = await WindowFocusService.focus(
            target,
            performer: { _ in
                probe.record()
                return WindowFocusAttemptOutcome()
            },
            environment: { _ in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(!verified)
        #expect(probe.attemptCount == WindowFocusRetryPolicy.maximumAttempts)
    }

    @Test func retryDelaysGrowAndClampAtTheFinalDelay() {
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(0) == .zero)
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(1) == .milliseconds(150))
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(2) == .milliseconds(400))
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(99) == .milliseconds(400))
        #expect(WindowFocusRetryPolicy.maximumAttempts == 3)
    }

    @Test func verificationRequiresTheTargetApplicationToFrontmost() {
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: nil,
            ownApplicationIsActive: true,
            focusedWindowMatchesTarget: nil
        ))
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 20,
            ownApplicationIsActive: true,
            focusedWindowMatchesTarget: nil
        ))
        #expect(WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 10,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: nil
        ))
        // A positive AX probe naming a different window blocks acceptance…
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 10,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: false
        ))
        // …while an inconclusive probe must not.
        #expect(WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 10,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: true
        ))
        // MacPilot's own windows additionally require NSApp.isActive.
        #expect(WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 20,
            ownProcessID: 20,
            frontmostProcessID: 20,
            ownApplicationIsActive: true,
            focusedWindowMatchesTarget: nil
        ))
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 20,
            ownProcessID: 20,
            frontmostProcessID: 20,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: nil
        ))
    }

    @Test func focusExecutorReportsAMissingApplicationWithoutSideEffects() {
        let outcome = WindowFocusExecutor.perform(
            WindowFocusTarget(
                processID: -1,
                axWindow: nil,
                windowNumber: nil,
                isMinimized: false,
                ownProcessID: -1
            )
        )

        #expect(!outcome.foundApplication)
        #expect(!outcome.activatedApplication)
        #expect(!outcome.raisedWindow)
    }
}
