import Foundation

/// Physical paths, independent of how their endpoint was discovered.
public enum RemoteConnectionMethod: String, CaseIterable, Sendable {
    case localNetwork
    case awdl
    case bluetooth

    public var textKey: String { "connectionMethod" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public enum RemoteConnectionPriority {
    public static let defaultOrder: [RemoteConnectionMethod] = [.localNetwork, .awdl, .bluetooth]

    /// Repairs older or malformed preferences without dropping a path.
    public static func normalized(_ values: [String]) -> [RemoteConnectionMethod] {
        var result: [RemoteConnectionMethod] = []
        for value in values {
            if let method = RemoteConnectionMethod(rawValue: value), !result.contains(method) {
                result.append(method)
            }
        }
        return result + defaultOrder.filter { !result.contains($0) }
    }

    public static func shouldReplace(_ current: RemoteConnectionMethod?, with candidate: RemoteConnectionMethod,
                                     order: [RemoteConnectionMethod]) -> Bool {
        guard let current else { return true }
        let complete = normalized(order.map(\.rawValue))
        return complete.firstIndex(of: candidate)! < complete.firstIndex(of: current)!
    }
}

/// Retry lifetimes belong to individual candidates, never to the whole race.
public enum RemoteConnectionRetryPolicy {
    public static func shouldRetry(
        method: RemoteConnectionMethod,
        startedAt: Date,
        transportReadyAt: Date?,
        now: Date
    ) -> Bool {
        if let transportReadyAt {
            return now.timeIntervalSince(transportReadyAt) >= 15
        }
        // Peer discovery and radio setup must survive the fast LAN retry cycle.
        let dialTimeout: TimeInterval = method == .awdl ? 30 : 4
        return now.timeIntervalSince(startedAt) >= dialTimeout
    }
}
