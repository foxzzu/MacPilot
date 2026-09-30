import Foundation

/// Pure aggregation of live session policies; owns no assertions or observers.
enum AwakePolicyEngine {
    static func desiredState(sessions: [AwakeSession], displayAsleep: Bool) -> DesiredAwakeState {
        let active = sessions.filter { $0.state == .active }
        let closedLidSleepPrevented = active.contains { $0.policy.preventClosedLidSleep }
        let allAllowSleepWithDisplayOff = active
            .filter { $0.policy.preventSystemSleep }
            .allSatisfy { $0.policy.allowSystemSleepWhenDisplayOff }
        let displayOffReleasesSystemSleep = displayAsleep
            && allAllowSleepWithDisplayOff
            && !closedLidSleepPrevented
        return DesiredAwakeState(
            preventSystemSleep: (active.contains { $0.policy.preventSystemSleep } || closedLidSleepPrevented)
                && !displayOffReleasesSystemSleep,
            preventDisplaySleep: active.contains { $0.policy.preventDisplaySleep },
            preventClosedLidSleep: closedLidSleepPrevented
        )
    }
}
