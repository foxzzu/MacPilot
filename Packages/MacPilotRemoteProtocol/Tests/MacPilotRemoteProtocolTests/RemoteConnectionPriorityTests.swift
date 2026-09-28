import Testing
import Network
@testable import MacPilotRemoteTransport

@Suite("Connection priority")
struct RemoteConnectionPriorityTests {
    @Test func bluetoothCanUpgradeThroughAWDLToLAN() {
        let order = RemoteConnectionPriority.defaultOrder
        #expect(RemoteConnectionPriority.shouldReplace(nil, with: .bluetooth, order: order))
        #expect(RemoteConnectionPriority.shouldReplace(.bluetooth, with: .awdl, order: order))
        #expect(RemoteConnectionPriority.shouldReplace(.awdl, with: .localNetwork, order: order))
        #expect(!RemoteConnectionPriority.shouldReplace(.localNetwork, with: .bluetooth, order: order))
    }

    @Test func everyUserOrderOnlyAllowsUpgrades() {
        for first in RemoteConnectionMethod.allCases {
            for second in RemoteConnectionMethod.allCases where second != first {
                let third = RemoteConnectionMethod.allCases.first { $0 != first && $0 != second }!
                let order = [first, second, third]
                for current in order {
                    for candidate in order {
                        let allowed = RemoteConnectionPriority.shouldReplace(current, with: candidate, order: order)
                        #expect(allowed == (order.firstIndex(of: candidate)! < order.firstIndex(of: current)!))
                    }
                }
            }
        }
    }

    @Test func bluetoothFirstNeverAllowsNetworkToPreemptIt() {
        let order: [RemoteConnectionMethod] = [.bluetooth, .awdl, .localNetwork]
        #expect(!RemoteConnectionPriority.shouldReplace(.bluetooth, with: .awdl, order: order))
        #expect(!RemoteConnectionPriority.shouldReplace(.bluetooth, with: .localNetwork, order: order))
    }

    @MainActor @Test func networkCandidatesUseDistinctPeerToPeerPolicies() {
        let service = NWEndpoint.service(name: "Mac", type: "_macpilot._tcp", domain: "local.", interface: nil)
        let remembered = NWEndpoint.hostPort(host: "fe80::1%awdl0", port: 43847)
        #expect(!NetworkRemoteTransport.parameters(to: service, method: .localNetwork).includePeerToPeer)
        #expect(NetworkRemoteTransport.parameters(to: service, method: .awdl).includePeerToPeer)
        #expect(NetworkRemoteTransport.parameters(to: remembered, method: .awdl).includePeerToPeer)
        #expect(NetworkRemoteTransport.parameters(to: service, method: nil).includePeerToPeer)
        #expect(!NetworkRemoteTransport.parameters(to: remembered, method: nil).includePeerToPeer)
    }

    @Test func corruptPreferencesPreserveValidOrderAndRestoreMissingPaths() {
        #expect(RemoteConnectionPriority.normalized(["bluetooth", "invalid", "bluetooth", "awdl"])
                == [.bluetooth, .awdl, .localNetwork])
        #expect(RemoteConnectionPriority.normalized([]) == RemoteConnectionPriority.defaultOrder)
    }
}
