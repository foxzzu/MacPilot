import CryptoKit
import Foundation

public struct RemoteDisplayInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id; self.name = name; self.width = width; self.height = height
    }
}

/// Delivered ONLY inside the authenticated control response. Never log this.
public struct RemoteVideoOffer: Codable, Sendable {
    public let port: UInt16
    public let secret: Data
    public let displays: [RemoteDisplayInfo]
    public let displayID: UInt32
    public init(port: UInt16, secret: Data, displays: [RemoteDisplayInfo], displayID: UInt32) {
        self.port = port; self.secret = secret; self.displays = displays; self.displayID = displayID
    }
}

public struct RemoteDesktopRequest: Codable, Sendable {
    public var displayID: UInt32?
    public init(displayID: UInt32? = nil) { self.displayID = displayID }
}

public struct RemotePointerRequest: Codable, Sendable {
    public let displayID: UInt32
    public let x: Double
    public let y: Double
    public init(displayID: UInt32, x: Double, y: Double) {
        self.displayID = displayID; self.x = x; self.y = y
    }
}

public struct RemoteKeyRequest: Codable, Sendable {
    public enum Key: String, Codable, Sendable { case escape, tab, delete, enter, character }
    public let key: Key
    /// 1 control, 2 option, 4 command. No raw key codes accepted from peers.
    public let modifiers: UInt8
    public let character: String?
    public init(key: Key, modifiers: UInt8 = 0, character: String? = nil) {
        self.key = key; self.modifiers = modifiers; self.character = character
    }
}

public enum RemoteVideoQuality: Int, Codable, Sendable, CaseIterable {
    case low, balanced, high
    public var width: Int { switch self { case .low: 960; case .balanced: 1280; case .high: 1920 } }
    public var height: Int { switch self { case .low: 540; case .balanced: 720; case .high: 1080 } }
    public var fps: Int { self == .low ? 20 : 30 }
    public var bitrate: Int { switch self { case .low: 1_000_000; case .balanced: 2_000_000; case .high: 4_000_000 } }
}

public struct RemoteVideoDiagnostics: Codable, Sendable {
    public let encodeMs: Double
    public let droppedFrames: Int
    public init(encodeMs: Double, droppedFrames: Int = 0) { self.encodeMs = encodeMs; self.droppedFrames = droppedFrames }
}

public struct RemoteVideoFeedback: Codable, Sendable {
    public let needsKeyFrame: Bool
    public let congested: Bool
    public init(needsKeyFrame: Bool, congested: Bool) {
        self.needsKeyFrame = needsKeyFrame; self.congested = congested
    }
}

public struct RemoteVideoPacket: Sendable, Equatable {
    public enum FrameType: UInt8, Sendable { case hello = 1, config, keyFrame, deltaFrame, feedback, diagnostics, focus }
    public let timestamp: Int64
    public let frameType: FrameType
    public let payload: Data
    public init(frameType: FrameType, payload: Data = Data(), timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.timestamp = timestamp; self.frameType = frameType; self.payload = payload
    }
}

/// Independent sequence space and directional HKDF keys: control nonces and
/// opposite-direction video nonces can never reuse a key/nonce pair.
public struct RemoteVideoCodec: Sendable {
    public static let maximumFrameSize = 2 << 20
    private let key: SymmetricKey
    private var sequence: UInt64 = 0
    public init(secret: Data, serverToClient: Bool) {
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            info: Data((serverToClient ? "MacPilot-video-s2c-v1" : "MacPilot-video-c2s-v1").utf8), outputByteCount: 32)
    }

    public mutating func encode(_ packet: RemoteVideoPacket) throws -> Data {
        guard sequence < UInt64.max else { throw RemoteProtocolError.invalidMessage }
        sequence += 1
        var plain = Data([packet.frameType.rawValue])
        plain.append(RemoteCrypto.bigEndianBytes(UInt64(bitPattern: packet.timestamp)))
        plain.append(packet.payload)
        let aad = RemoteCrypto.bigEndianBytes(sequence)
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + aad)
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: aad)
        let body = aad + box.combined
        guard body.count <= Self.maximumFrameSize else { throw RemoteProtocolError.invalidMessage }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    public mutating func decode(_ body: Data) throws -> RemoteVideoPacket {
        guard body.count >= 45, body.count <= Self.maximumFrameSize else { throw RemoteProtocolError.malformedFrame }
        let next = RemoteCrypto.sequence(fromBigEndian: Data(body.prefix(8)))
        guard next > sequence else { throw RemoteProtocolError.replayDetected }
        let aad = Data(body.prefix(8))
        let box = try ChaChaPoly.SealedBox(combined: body.dropFirst(8))
        let plain = try ChaChaPoly.open(box, using: key, authenticating: aad)
        guard plain.count >= 9, let type = RemoteVideoPacket.FrameType(rawValue: plain[plain.startIndex]) else {
            throw RemoteProtocolError.invalidMessage
        }
        let timestamp = Int64(bitPattern: RemoteCrypto.sequence(fromBigEndian: Data(plain.dropFirst().prefix(8))))
        guard abs(Double(timestamp) - Date().timeIntervalSince1970 * 1000) < 300_000 else {
            throw RemoteProtocolError.replayDetected
        }
        sequence = next
        return RemoteVideoPacket(frameType: type, payload: Data(plain.dropFirst(9)), timestamp: timestamp)
    }

    public static func extractFrames(from buffer: inout Data) throws -> [Data] {
        var result: [Data] = []
        while buffer.count >= 4 {
            let length = Int(RemoteCrypto.sequence(fromBigEndian: Data(buffer.prefix(4))))
            guard length >= 45, length <= maximumFrameSize else { throw RemoteProtocolError.malformedFrame }
            guard buffer.count >= length + 4 else { break }
            result.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return result
    }
}
