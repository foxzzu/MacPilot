import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEMonitoringRestorationTests {
    @Test func absentSecondaryDoesNotResetAFreshPrimaryInAnyDeviceMode() {
        let primary = UUID()
        let secondary = UUID()
        let model = BLEUnlockModel()
        defer { model.shutdown() }
        model.settings.isEnabled = true
        model.settings.deviceRelation = .any
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.secondaryMonitoredUUID = secondary
        model.startMonitor(primary)
        model.updateMonitoredPeripheral(-50, for: primary)
        let taskCount = model.diagnosticTaskCount

        model.handleMonitoredSignalTimeout(for: secondary)

        #expect(model.presence)
        #expect(model.lastRSSI == -50)
        #expect(model.diagnosticTaskCount == taskCount)
    }

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
