import Foundation
import Testing
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
@testable import PilotNest

@MainActor
@Suite("Background connection authentication")
struct RemoteConnectionHandshakeTests {
    @Test func upgradeCannotSendPairRequestWhenMacForgetsPairing() throws {
        let transport = HandshakeTransport()
        let manager = RemoteConnectionManager()
        let deviceID = UUID()
        var failure: RemoteConnectionError?
        manager.onFailure = { failure = $0 }
        manager.connect(using: transport, deviceID: deviceID, name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone", allowsPairing: false)
        try transport.receiveUnpairedHello(deviceID: deviceID)
        #expect(failure == .notPaired)
        #expect(try transport.sentMessages().map(\.kind) == [.clientHello])
        #expect(!manager.isReady)
    }

    @Test func firstConnectionCanStillRequestPairing() throws {
        let transport = HandshakeTransport()
        let manager = RemoteConnectionManager()
        let deviceID = UUID()
        var failure: RemoteConnectionError?
        manager.onFailure = { failure = $0 }
        manager.connect(using: transport, deviceID: deviceID, name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone", allowsPairing: true)
        try transport.receiveUnpairedHello(deviceID: deviceID)
        #expect(failure == nil)
        #expect(try transport.sentMessages().map(\.kind) == [.clientHello, .pairRequest])
        manager.disconnect(report: false)
    }
}

@MainActor
private final class HandshakeTransport: RemoteTransport {
    let kind: RemoteTransportKind = .network
    let linkDescription = "en0"
    var onStateChange: (@MainActor (RemoteTransportState) -> Void)?
    var onReceive: (@MainActor (Data) -> Void)?
    var remoteHost: String? { nil }
    var remotePort: UInt16? { nil }
    var remoteServiceName: String? { nil }
    private var sent = Data()

    func start() { onStateChange?(.ready) }
    func cancel() {}
    func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        sent.append(data)
        completion(nil)
    }
    func sentMessages() throws -> [RemoteHandshakeMessage] {
        var buffer = sent
        return try RemoteFrameCodec.extractFrames(from: &buffer).map {
            try RemoteFrameCodec.decodePlain(RemoteHandshakeMessage.self, from: $0)
        }
    }
    func receiveUnpairedHello(deviceID: UUID) throws {
        let nonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        let exchange = RemotePairingExchange(clientNonce: nonce, serverNonce: nonce)
        onReceive?(try RemoteFrameCodec.encodePlain(RemoteHandshakeMessage(
            kind: .serverHello, deviceID: deviceID, paired: false,
            serverNonce: nonce, publicKey: exchange.publicKeyData
        )))
    }
}
