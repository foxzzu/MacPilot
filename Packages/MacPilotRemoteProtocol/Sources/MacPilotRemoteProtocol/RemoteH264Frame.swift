import Foundation

/// AVCC (four-byte NAL lengths), with SPS/PPS repeated on every IDR so a
/// dropped frame or quality change can recover without a separate config race.
public struct RemoteH264Frame: Sendable, Equatable {
    public let sps: Data
    public let pps: Data
    public let avcc: Data
    public init(sps: Data = Data(), pps: Data = Data(), avcc: Data) {
        self.sps = sps; self.pps = pps; self.avcc = avcc
    }
    public func encoded() throws -> Data {
        guard sps.count <= 65535, pps.count <= 65535 else { throw RemoteProtocolError.invalidMessage }
        var data = Data()
        for set in [sps, pps] {
            var length = UInt16(set.count).bigEndian
            data.append(withUnsafeBytes(of: &length) { Data($0) })
            data.append(set)
        }
        data.append(avcc)
        return data
    }
    public static func decode(_ data: Data, keyFrame: Bool) throws -> Self {
        var remainder = data
        var sets: [Data] = []
        for _ in 0..<2 {
            guard remainder.count >= 2 else { throw RemoteProtocolError.invalidMessage }
            let count = Int(RemoteCrypto.sequence(fromBigEndian: Data(remainder.prefix(2))))
            remainder = Data(remainder.dropFirst(2))
            guard count <= remainder.count else { throw RemoteProtocolError.invalidMessage }
            sets.append(Data(remainder.prefix(count)))
            remainder = Data(remainder.dropFirst(count))
        }
        if keyFrame, (sets[0].isEmpty || sets[1].isEmpty) { throw RemoteProtocolError.invalidMessage }
        var nals = remainder
        guard !nals.isEmpty else { throw RemoteProtocolError.invalidMessage }
        while !nals.isEmpty {
            guard nals.count >= 4 else { throw RemoteProtocolError.invalidMessage }
            let count = Int(RemoteCrypto.sequence(fromBigEndian: Data(nals.prefix(4))))
            guard count > 0, count <= nals.count - 4 else { throw RemoteProtocolError.invalidMessage }
            nals = Data(nals.dropFirst(count + 4))
        }
        return Self(sps: sets[0], pps: sets[1], avcc: remainder)
    }
}
