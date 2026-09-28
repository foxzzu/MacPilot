import Foundation
import Testing
@testable import MacPilotRemoteProtocol

struct RemoteVideoTests {
    private let secret = Data(repeating: 7, count: 32)

    @Test func videoRoundTripWorksWithFragmentedAndSlicedBuffers() throws {
        var encoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var decoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        let packet = RemoteVideoPacket(frameType: .deltaFrame, payload: Data([0, 0, 0, 1, 65]))
        let wire = try encoder.encode(packet)
        var buffer = Data([99]) + wire.prefix(3)
        buffer = buffer.dropFirst()
        #expect(try RemoteVideoCodec.extractFrames(from: &buffer).isEmpty)
        buffer.append(wire.dropFirst(3))
        let bodies = try RemoteVideoCodec.extractFrames(from: &buffer)
        #expect(bodies.count == 1)
        #expect(try decoder.decode(bodies[0]) == packet)
        #expect(buffer.isEmpty)
        #expect(throws: (any Error).self) { try decoder.decode(bodies[0]) }
    }

    @Test func wrongDirectionAndWrongTicketCannotDecryptVideo() throws {
        var encoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var reflected = RemoteVideoCodec(secret: secret, serverToClient: false)
        var wrongTicket = RemoteVideoCodec(secret: Data(repeating: 8, count: 32), serverToClient: true)
        var buffer = try encoder.encode(RemoteVideoPacket(frameType: .hello))
        let body = try #require(RemoteVideoCodec.extractFrames(from: &buffer).first)
        #expect(throws: (any Error).self) { try reflected.decode(body) }
        #expect(throws: (any Error).self) { try wrongTicket.decode(body) }
    }

    @Test func tamperedPacketsDoNotAdvanceTheReplayCounter() throws {
        var encoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var decoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var buffer = try encoder.encode(RemoteVideoPacket(frameType: .hello))
        let body = try #require(RemoteVideoCodec.extractFrames(from: &buffer).first)
        var tampered = body
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try decoder.decode(tampered) }
        #expect(try decoder.decode(body).frameType == .hello)
    }

    @Test func oversizeLengthIsRejectedBeforeAllocatingTheFrame() {
        var buffer = Data([0xff, 0xff, 0xff, 0xff])
        #expect(throws: RemoteProtocolError.self) { try RemoteVideoCodec.extractFrames(from: &buffer) }
    }

    @Test func keyframesCarryParameterSetsAndRejectTruncatedNALs() throws {
        let frame = RemoteH264Frame(sps: Data([103, 1]), pps: Data([104, 1]), avcc: Data([0, 0, 0, 2, 65, 1]))
        #expect(try RemoteH264Frame.decode(frame.encoded(), keyFrame: true) == frame)
        #expect(throws: RemoteProtocolError.self) { try RemoteH264Frame.decode(Data([0, 0, 0, 0, 0, 0, 0, 20, 65]), keyFrame: false) }
        let delta = RemoteH264Frame(avcc: frame.avcc)
        #expect(throws: RemoteProtocolError.self) { try RemoteH264Frame.decode(delta.encoded(), keyFrame: true) }
    }

    @Test func oldControlResponsesStillDecodeWithoutVideoPayload() throws {
        let id = UUID()
        let data = Data("{\"version\":1,\"requestID\":\"\(id)\",\"success\":true}".utf8)
        let response = try JSONDecoder().decode(RemoteResponse.self, from: data)
        #expect(response.payload == nil)
        #expect(response.success)
    }

    @Test func legacyPhonesNeverReceiveUnknownDesktopOrDockCapabilityCases() {
        let advertised: [RemoteCapability] = [.lock, .realtimeInput, .inputPressureStream, .dockGroups, .remoteDesktop]
        #expect(RemoteCapability.negotiated(advertised, features: nil) == [.lock, .realtimeInput, .inputPressureStream])
    }

    @Test func newPhonesReceiveOnlyTheFeaturesTheyDeclared() {
        let advertised: [RemoteCapability] = [.realtimeInput, .dockGroups, .remoteDesktop]
        #expect(RemoteCapability.negotiated(advertised, features: ["remoteDesktop"]) == [.realtimeInput, .remoteDesktop])
        #expect(RemoteCapability.negotiated(advertised, features: ["remoteDesktop", "dockGroups"]) == advertised)
    }

    @Test func videoCapabilitiesNeverChangeExistingInputEventNumbers() {
        #expect(RemoteCommand.beginRemoteVideo.requiresAuthentication)
        #expect(RemoteCommand.remotePointer.requiresAuthentication)
        #expect(RemoteCommand.remoteKey.requiresAuthentication)
        #expect(RemoteVideoQuality.balanced.width == 1280)
        #expect(RemoteVideoQuality.balanced.fps == 30)
        #expect(RemoteVideoQuality.balanced.bitrate == 2_000_000)
    }
}
