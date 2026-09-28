import Foundation
import Testing
@testable import PilotNest

@MainActor
@Suite("Remote connection retry")
struct RemoteConnectionRetryTests {
    @Test func readyButUnfinishedHandshakeIsRetriedAfterItsBoundedLifetime() {
        let started = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 116)

        #expect(RemoteAppModel.shouldRetryHandshake(isTransportReady: true, startedAt: started, now: now))
        #expect(!RemoteAppModel.shouldRetryHandshake(isTransportReady: true, startedAt: started, now: Date(timeIntervalSinceReferenceDate: 114.9)))
    }

    @Test func transportThatNeverBecameReadyStillUsesTheShortDialTimeout() {
        let started = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 104.1)

        #expect(RemoteAppModel.shouldRetryDial(isTransportReady: false, startedAt: started, now: now))
        #expect(!RemoteAppModel.shouldRetryDial(isTransportReady: false, startedAt: started, now: Date(timeIntervalSinceReferenceDate: 103.9)))
    }

    @Test func foregroundDisconnectRestartsEvenWhenAnOldSupervisorIsStillFinishing() {
        #expect(RemoteAppModel.shouldRestartSupervisorAfterDisconnect(
            isForeground: true,
            hasPairingTarget: false
        ))
        #expect(!RemoteAppModel.shouldRestartSupervisorAfterDisconnect(
            isForeground: false,
            hasPairingTarget: false
        ))
        #expect(!RemoteAppModel.shouldRestartSupervisorAfterDisconnect(
            isForeground: true,
            hasPairingTarget: true
        ))
    }
}
