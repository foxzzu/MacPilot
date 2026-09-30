import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEMonitoringRestorationTests {
    @Test func activeRecoveryReconnectsKnownDevicesWithoutAnAdvertisement() {
        let known = UUID()
        let unknown = UUID()
        var retrieved: [UUID] = []
        var connected: [UUID] = []
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [known, unknown],
            passiveMode: false,
            retrieve: { identifier -> String? in
                retrieved.append(identifier)
                return identifier == known ? "cached peripheral" : nil
            },
            connect: { identifier, device in
                #expect(device == "cached peripheral")
                connected.append(identifier)
            },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(retrieved == [known, unknown])
        #expect(connected == [known])
        // Unknown or absent devices must still get another recovery opportunity.
        #expect(timeouts == [known, unknown])
    }

    @Test func passiveRecoveryArmsTimeoutsWithoutConnecting() {
        let identifier = UUID()
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [identifier],
            passiveMode: true,
            retrieve: { _ -> String? in
                Issue.record("Passive monitoring must not retrieve devices for connection")
                return "device"
            },
            connect: { _, _ in Issue.record("Passive monitoring must not connect") },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(timeouts == [identifier])
    }
}
