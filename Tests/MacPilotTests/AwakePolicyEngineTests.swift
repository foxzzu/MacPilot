import Foundation
import Testing
@testable import MacPilot

struct AwakePolicyEngineTests {
    @Test func endedSessionsCannotKeepEitherAssertionActive() {
        let sessions = [session(SessionPolicy(preventDisplaySleep: true, preventClosedLidSleep: true), state: .ended)]
        #expect(AwakePolicyEngine.desiredState(sessions: sessions, displayAsleep: false) == .inactive)
        #expect(AwakePolicyEngine.desiredState(sessions: [], displayAsleep: true) == .inactive)
    }

    @Test func displaySleepReleasesSystemOnlyWhenAllSystemSessionsPermitIt() {
        let permissive = session(SessionPolicy(allowSystemSleepWhenDisplayOff: true))
        let displayOnly = session(SessionPolicy(preventSystemSleep: false, preventDisplaySleep: true))
        let state = AwakePolicyEngine.desiredState(sessions: [permissive, displayOnly], displayAsleep: true)
        #expect(!state.preventSystemSleep)
        #expect(state.preventDisplaySleep)
        let strict = session(.standard)
        #expect(AwakePolicyEngine.desiredState(sessions: [permissive, strict], displayAsleep: true).preventSystemSleep)
        #expect(AwakePolicyEngine.desiredState(sessions: [permissive], displayAsleep: false).preventSystemSleep)
    }

    @Test func closedLidPolicyKeepsSystemAwakeEvenWhenDisplayOffNormallyReleasesIt() {
        var policy = SessionPolicy(preventClosedLidSleep: true, allowSystemSleepWhenDisplayOff: true)
        // Decoded historical policy data can bypass the initializer's normalization.
        policy.preventSystemSleep = false
        let state = AwakePolicyEngine.desiredState(sessions: [session(policy)], displayAsleep: true)
        #expect(state.preventSystemSleep)
        #expect(state.preventClosedLidSleep)
        #expect(!state.preventDisplaySleep)
    }

    private func session(_ policy: SessionPolicy, state: SessionState = .active) -> AwakeSession {
        AwakeSession(id: UUID(), source: .manual, startedAt: Date(), endCondition: .manual,
            policy: policy, state: state)
    }
}
