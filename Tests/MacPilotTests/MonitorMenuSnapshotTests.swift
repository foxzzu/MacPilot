import Testing
@testable import MacPilot

@MainActor
struct MonitorMenuSnapshotTests {
    @Test func memoryMenuHasProcessRowsBeforeAnyAppearanceCallback() {
        let monitor = MemoryMonitorModel()
        let menu = MemoryMonitorMenuSection(openMonitor: {})
        #expect(monitor.store.lastUpdated == nil)
        let snapshot = menu.snapshot
        #expect(snapshot.system != nil)
        #expect(!snapshot.apps.isEmpty)
        #expect(!monitor.isRunning)
    }

    @Test func cpuMenuHasProcessRowsBeforeAnyAppearanceCallback() {
        let monitor = CPUMonitorModel()
        let menu = CPUMonitorMenuSection(openMonitor: {})
        #expect(monitor.store.lastUpdated == nil)
        let snapshot = menu.snapshot
        #expect(snapshot.system != nil)
        #expect(!snapshot.apps.isEmpty)
        #expect(!monitor.isRunning)
    }
}
